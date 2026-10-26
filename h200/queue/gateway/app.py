"""Getac LongCat Video Avatar Gateway v1.1.0.0 -- durable single-GPU FIFO queue.

Drop-in replacement for existing GB10/H200 gateway/app.py.
IMPORTANT: run exactly ONE uvicorn worker/replica per JOB_ROOT.  The queue is
persisted to mounted storage, but coordination is intentionally process-local.
Do not restart the gateway while GPU inference is running: in-flight jobs are
marked interrupted on restart rather than duplicated, for GPU safety.
"""
from __future__ import annotations

import base64
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import secrets
import shutil
import statistics
import threading
import time
from typing import Any
from urllib.parse import urljoin, urlparse
import uuid

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse

APP_VERSION = "1.1.0.0"
BASE_URL = os.getenv("LOCALAI_URL", "http://longcat-core:8080").rstrip("/")
MODEL_NAME = os.getenv("MODEL_NAME", "longcat-video-avatar-1.5")
JOB_ROOT = Path(os.getenv("JOB_ROOT", "/data/jobs"))
API_KEY = os.getenv("GETAC_API_KEY", "")
MAX_IMAGE_BYTES = 25 * 1024 * 1024
MAX_AUDIO_BYTES = 128 * 1024 * 1024
MAX_PENDING = max(1, int(os.getenv("GETAC_QUEUE_MAX_PENDING", "50")))
DEFAULT_PROMPT = (
    "A professional presenter faces the camera in a bright neutral studio, "
    "speaking calmly and naturally with accurate lip movements, subtle blinking, "
    "stable facial features, minimal head turns and restrained gestures. "
    "The camera is fixed, the shoulders stay level, and the person's identity stays consistent."
)
JOB_ROOT.mkdir(parents=True, exist_ok=True)
_log = logging.getLogger("getac.longcat.queue")
_condition = threading.Condition(threading.RLock())
_pending: deque[str] = deque()
_active_job: str | None = None
_stop = threading.Event()
_worker_thread: threading.Thread | None = None
_metrics_path = JOB_ROOT / "queue_metrics.json"


def _utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def _timestamp(text: str | None) -> float | None:
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def _write_json(path: Path, value: dict) -> None:
    """Atomic writes; request/status data survive container recreation."""
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


def _read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _authorize(x_api_key: str | None) -> None:
    if API_KEY and (not x_api_key or not secrets.compare_digest(x_api_key, API_KEY)):
        raise HTTPException(status_code=401, detail="Invalid X-API-Key")


def _job_folder(job_id: str) -> Path:
    try:
        job_id = str(uuid.UUID(job_id))
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(status_code=400, detail="Invalid job_id")
    return JOB_ROOT / job_id


def _read_status(job_id: str) -> dict:
    file = _job_folder(job_id) / "status.json"
    if not file.is_file():
        raise HTTPException(status_code=404, detail="Job not found")
    return _read_json(file)


def _put_status(folder: Path, state: str, message: str = "", progress: int = 0) -> dict:
    file = folder / "status.json"
    previous = _read_json(file) if file.is_file() else {}
    now = _utc()
    data = {
        "job_id": folder.name,
        "status": state,
        "message": message,
        "progress": progress,
        "created_at": previous.get("created_at") or now,
        "updated_at": now,
    }
    if previous.get("started_at"):
        data["started_at"] = previous["started_at"]
    if state == "running" and not data.get("started_at"):
        data["started_at"] = now
    if state in ("completed", "failed", "cancelled"):
        data["finished_at"] = now
    _write_json(file, data)
    return data


def _durations() -> list[float]:
    try:
        values = _read_json(_metrics_path).get("successful_seconds", [])
        return [float(x) for x in values if 0 < float(x) < 7 * 86400][-20:]
    except (ValueError, TypeError, OSError, json.JSONDecodeError):
        return []


def _record_success(seconds: float) -> None:
    with _condition:
        numbers = (_durations() + [round(seconds, 1)])[-20:]
        _write_json(_metrics_path, {"successful_seconds": numbers, "updated_at": _utc()})


def _queue_snapshot() -> dict:
    with _condition:
        return {"running_job_id": _active_job,
                "pending_job_ids": list(_pending),
                "max_pending": MAX_PENDING}


def _decorate_status(data: dict) -> dict:
    """Return dynamic queue positions; never use the stage marker as GPU progress."""
    view = dict(data)
    snap = _queue_snapshot()
    pending = snap["pending_job_ids"]
    active = snap["running_job_id"]
    job_id = data["job_id"]
    state = data["status"]
    position = pending.index(job_id) + 1 if job_id in pending else None
    ahead = (position - 1 + int(active is not None)) if position else 0
    view.update({
        "queue_position": position,        # 1 = next queued, null = active/finished
        "jobs_ahead": ahead,              # includes current running job
        "queue_length": len(pending),
        "is_running": state == "running",
        "elapsed_seconds": max(0, int(time.time() - (_timestamp(data.get("created_at")) or time.time()))),
        "estimated_wait_seconds": None,  # only estimate after >=3 measured successful jobs
    })
    history = _durations()
    if state == "queued" and position and len(history) >= 3:
        average = statistics.median(history)
        running_remaining = 0.0
        if active:
            try:
                active_started = _timestamp(_read_status(active).get("started_at"))
                running_remaining = max(0.0, average - (time.time() - active_started)) if active_started else average
            except HTTPException:
                running_remaining = average
        view["estimated_wait_seconds"] = int(round(running_remaining + (position - 1) * average))
    return view


async def _save_upload(src: UploadFile, path: Path, size_limit: int) -> None:
    size = 0
    with path.open("wb") as output:
        while chunk := await src.read(1024 * 1024):
            size += len(chunk)
            if size > size_limit:
                path.unlink(missing_ok=True)
                raise HTTPException(status_code=413, detail="File too large")
            output.write(chunk)
    if size == 0:
        raise HTTPException(status_code=400, detail="Empty file")


def _extract_video_url(body: dict) -> str:
    entries = body.get("data") or []
    if not entries:
        raise RuntimeError("LocalAI returned no video item: " + str(body)[:600])
    item = entries[0]
    if item.get("b64_json"):
        return "b64:" + item["b64_json"]
    url = item.get("url")
    if not url:
        raise RuntimeError("LocalAI response has no video url")
    return url


def _probe_localai() -> dict:
    result: dict[str, Any] = {
        "backend_ready": False, "video_api_ready": False,
        "video_probe_http_status": None, "model_installed": None,
        "model_list_http_status": None,
    }
    try:
        with httpx.Client(timeout=5.0, trust_env=False) as client:
            ready = client.get(BASE_URL + "/readyz")
            result["backend_ready"] = ready.status_code == 200
            probe = client.post(BASE_URL + "/video", content=b"{",
                                headers={"Content-Type": "application/json"})
            result["video_probe_http_status"] = probe.status_code
            result["video_api_ready"] = probe.status_code in (400, 415, 422)
            models = client.get(BASE_URL + "/v1/models")
            result["model_list_http_status"] = models.status_code
            if models.status_code == 200:
                ids = [str(x.get("id", "")) for x in models.json().get("data", []) if isinstance(x, dict)]
                result["model_installed"] = MODEL_NAME in ids
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        result["error"] = str(exc)[:300]
    return result


def _run_job(job_id: str) -> None:
    folder = JOB_ROOT / job_id
    req = _read_json(folder / "request.json")
    image_path = folder / req["image_filename"]
    audio_path = folder / "speech.wav"
    started = time.monotonic()
    try:
        _put_status(folder, "running", "Preparing audio/image for LocalAI", 10)
        body = {
            "model": MODEL_NAME,
            "prompt": req["prompt"],
            "start_image": base64.b64encode(image_path.read_bytes()).decode("ascii"),
            "audio": base64.b64encode(audio_path.read_bytes()).decode("ascii"),
            "width": 832 if req["resolution"] == "480p" else 1280,
            "height": 480 if req["resolution"] == "480p" else 720,
            "response_format": "url",
            "params": {"resolution": req["resolution"], "offload_kv_cache": "true"},
        }
        _put_status(folder, "running", "Running LongCat GPU inference (stage marker; not real percent)", 25)
        with httpx.Client(timeout=httpx.Timeout(connect=30, read=None, write=300, pool=60), trust_env=False) as client:
            response = client.post(BASE_URL + "/video", json=body)
            if response.status_code == 404:
                raise RuntimeError("LocalAI POST /video returned 404; check LocalAI video backend version")
            if response.is_error:
                raise RuntimeError(f"LocalAI POST /video returned HTTP {response.status_code}: " + response.text[:700])
            payload = response.json()
            _write_json(folder / "localai_response.json", payload)
            video_url = _extract_video_url(payload)
            if video_url.startswith("b64:"):
                video = base64.b64decode(video_url[4:])
            else:
                parsed = urlparse(video_url)
                allowed = urlparse(BASE_URL)
                if parsed.scheme or parsed.netloc:
                    if (parsed.scheme, parsed.netloc) != (allowed.scheme, allowed.netloc):
                        raise RuntimeError("LocalAI returned an unexpected video host")
                    target = video_url
                else:
                    target = urljoin(BASE_URL + "/", video_url.lstrip("/"))
                _put_status(folder, "running", "Downloading generated MP4", 90)
                result = client.get(target)
                result.raise_for_status()
                video = result.content
        if len(video) < 4096:
            raise RuntimeError("Generated video too small or empty")
        (folder / "result.mp4").write_bytes(video)
        _put_status(folder, "completed", "MP4 generated; background is not transparent", 100)
        _record_success(time.monotonic() - started)
    except Exception as exc:
        _log.exception("LongCat job %s failed", job_id)
        (folder / "error.log").write_text(repr(exc) + "\n", encoding="utf-8")
        _put_status(folder, "failed", str(exc)[:1000], 0)


def _worker_loop() -> None:
    global _active_job
    while not _stop.is_set():
        with _condition:
            _condition.wait_for(lambda: bool(_pending) or _stop.is_set())
            if _stop.is_set():
                break
            job_id = _pending.popleft()
            _active_job = job_id
        _log.info("Starting FIFO job %s; pending=%d", job_id, len(_pending))
        try:
            _run_job(job_id)
        except BaseException:  # don't leave one broken job blocking entire queue
            _log.exception("Unexpected worker failure for %s", job_id)
            folder = JOB_ROOT / job_id
            try:
                _put_status(folder, "failed", "Gateway worker error; check server logs", 0)
            except Exception:
                _log.exception("Cannot save failure status")
        finally:
            with _condition:
                _active_job = None
                _condition.notify_all()


def _recover_jobs() -> None:
    """Recover queued jobs; deliberately do NOT replay running inference after restart."""
    global _active_job
    with _condition:
        _pending.clear()
        _active_job = None
        queue_candidates: list[tuple[str, str]] = []
        for folder in JOB_ROOT.iterdir():
            if not folder.is_dir() or not (folder / "status.json").is_file():
                continue
            try:
                status = _read_json(folder / "status.json")
                state = status.get("status")
                if state == "running":
                    _put_status(folder, "failed", "Gateway restarted during inference; retry manually to avoid duplicate GPU jobs", 0)
                    _log.warning("In-flight job %s interrupted by restart", folder.name)
                elif state == "queued":
                    if ((folder / "request.json").is_file()
                            and (folder / "speech.wav").is_file()):
                        req = _read_json(folder / "request.json")
                        if (folder / req["image_filename"]).is_file():
                            queue_candidates.append((status.get("created_at", ""), folder.name))
                            continue
                    _put_status(folder, "failed", "Incomplete queued job after restart; retry submission", 0)
            except (OSError, KeyError, ValueError, TypeError) as exc:
                _log.error("Unable to recover job %s: %s", folder.name, exc)
        for _, job_id in sorted(queue_candidates):
            _pending.append(job_id)
        _log.info("Recovered %d queued LongCat jobs", len(_pending))


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global _worker_thread
    _stop.clear()
    _recover_jobs()
    _worker_thread = threading.Thread(target=_worker_loop, name="longcat-fifo-worker", daemon=True)
    _worker_thread.start()
    try:
        yield
    finally:
        _stop.set()
        with _condition:
            _condition.notify_all()
        if _worker_thread:
            _worker_thread.join(timeout=2)
        _log.info("Gateway shutdown. Do not restart during active GPU inference.")


app = FastAPI(
    title="Getac LongCat Video Avatar Job Queue API",
    version=APP_VERSION,
    lifespan=lifespan,
    description="PNG/JPG + WAV -> FIFO jobs -> LocalAI LongCat video. One concurrent GPU inference.",
)


@app.get("/health")
def health() -> dict:
    probe = _probe_localai()
    snap = _queue_snapshot()
    return {
        "status": "ok" if probe["backend_ready"] and probe["video_api_ready"] and probe["model_installed"] is True else "degraded",
        "version": APP_VERSION,
        "model": MODEL_NAME,
        "backend_ready": probe["backend_ready"],
        "video_api_ready": probe["video_api_ready"],
        "video_probe_http_status": probe["video_probe_http_status"],
        "model_installed": probe["model_installed"],
        "model_list_http_status": probe["model_list_http_status"],
        "api_port": 8500,
        "queue_enabled": True,
        "queue_length": len(snap["pending_job_ids"]),
        "worker_busy": snap["running_job_id"] is not None,
        "note": "Stage progress=25 is not true GPU generation percent; query /api/presenter/status/{job_id}.",
        **({"probe_error": probe["error"]} if probe.get("error") else {}),
    }


@app.get("/api/presenter/queue")
def queue_info(x_api_key: str | None = Header(default=None)) -> dict:
    _authorize(x_api_key)
    snap = _queue_snapshot()
    history = _durations()
    return {
        "running": snap["running_job_id"] is not None,
        "running_job_id": snap["running_job_id"],
        "queued_count": len(snap["pending_job_ids"]),
        "max_pending": MAX_PENDING,
        "average_job_seconds": round(statistics.median(history), 1) if len(history) >= 3 else None,
        "eta_is_estimate": True,
    }


@app.post("/api/presenter/create", status_code=202)
async def create(image: UploadFile | None = File(default=None),
                 avatar: UploadFile | None = File(default=None),
                 audio: UploadFile = File(...),
                 prompt: str = Form(default=DEFAULT_PROMPT),
                 resolution: str = Form(default="480p"),
                 max_segments: int = Form(default=8),
                 x_api_key: str | None = Header(default=None)) -> dict:
    _authorize(x_api_key)
    face = image or avatar
    if face is None:
        raise HTTPException(status_code=422, detail="Upload image or avatar file")
    if resolution not in ("480p", "720p") or not 1 <= max_segments <= 20:
        raise HTTPException(status_code=422, detail="resolution=480p/720p; max_segments=1..20")
    if not (face.filename or "").lower().endswith((".png", ".jpg", ".jpeg")):
        raise HTTPException(status_code=415, detail="Image must be PNG or JPG")
    if not (audio.filename or "").lower().endswith(".wav"):
        raise HTTPException(status_code=415, detail="Audio must be WAV")

    # A busy LocalAI can take >5s to respond to health probes. Accept queueing
    # while another job is running instead of spuriously returning HTTP 503.
    snap = _queue_snapshot()
    if not snap["running_job_id"] and not snap["pending_job_ids"]:
        probe = _probe_localai()
        if not probe["backend_ready"] or not probe["video_api_ready"]:
            raise HTTPException(status_code=503, detail="LocalAI backend/video API not ready")
        if probe["model_installed"] is False:
            raise HTTPException(status_code=503, detail=f"Model '{MODEL_NAME}' is not installed")
    with _condition:
        if len(_pending) >= MAX_PENDING:
            raise HTTPException(status_code=429, detail="Job queue is full; try again later")

    job_id = str(uuid.uuid4())
    folder = JOB_ROOT / job_id
    folder.mkdir(parents=True)
    filename = "portrait.png" if face.filename.lower().endswith(".png") else "portrait.jpg"
    try:
        await _save_upload(face, folder / filename, MAX_IMAGE_BYTES)
        await _save_upload(audio, folder / "speech.wav", MAX_AUDIO_BYTES)
        _write_json(folder / "request.json", {
            "image_filename": filename, "prompt": prompt[:2000],
            "resolution": resolution, "max_segments": max_segments,
        })
        with _condition:
            if len(_pending) >= MAX_PENDING:
                raise HTTPException(status_code=429, detail="Job queue is full; try again later")
            _put_status(folder, "queued", "Waiting in FIFO queue", 0)
            _pending.append(job_id)
            position = len(_pending)
            ahead = position - 1 + int(_active_job is not None)
            _condition.notify()
        return {
            "job_id": job_id, "status": "queued", "queue_position": position,
            "jobs_ahead": ahead,
            "status_url": f"/api/presenter/status/{job_id}",
            "result_url": f"/api/presenter/result/{job_id}",
        }
    except Exception:
        # May have been enqueued already if something failed after append: only
        # remove uncommitted folders.  All ordinary post-append work is in-memory.
        with _condition:
            is_enqueued = job_id in _pending or _active_job == job_id
        if not is_enqueued:
            shutil.rmtree(folder, ignore_errors=True)
        raise


@app.get("/api/presenter/status/{job_id}")
def status(job_id: str, x_api_key: str | None = Header(default=None)) -> dict:
    _authorize(x_api_key)
    return _decorate_status(_read_status(job_id))


@app.post("/api/presenter/cancel/{job_id}")
def cancel(job_id: str, x_api_key: str | None = Header(default=None)) -> dict:
    _authorize(x_api_key)
    _read_status(job_id)   # proper 404 if unknown
    with _condition:
        if job_id == _active_job:
            raise HTTPException(status_code=409, detail="Running inference cannot be cancelled safely")
        if job_id not in _pending:
            raise HTTPException(status_code=409, detail="Job is not queued")
        _pending.remove(job_id)
        state = _put_status(_job_folder(job_id), "cancelled", "Cancelled while waiting", 0)
    return _decorate_status(state)


@app.get("/api/presenter/result/{job_id}")
def result(job_id: str, x_api_key: str | None = Header(default=None)):
    _authorize(x_api_key)
    _read_status(job_id)
    file = _job_folder(job_id) / "result.mp4"
    if not file.is_file():
        raise HTTPException(status_code=409, detail="Video is not ready")
    return FileResponse(file, media_type="video/mp4", filename=f"{job_id}.mp4")


@app.get("/api/presenter/log/{job_id}")
def job_log(job_id: str, x_api_key: str | None = Header(default=None)):
    _authorize(x_api_key)
    state = _read_status(job_id)
    file = _job_folder(job_id) / "error.log"
    msg = file.read_text(encoding="utf-8") if file.is_file() else json.dumps(state, ensure_ascii=False, indent=2)
    return {"job_id": job_id, "log": msg}
