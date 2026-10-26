"""Getac LongCat Video Avatar GB10 API v1.0.1.0.

Small single-job bridge to the LocalAI CUDA13 ARM64 longcat-video backend.
This does not claim LocalAI model load/inference has been validated on the user's GB10.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse

APP_VERSION = "1.0.1.0"
BASE_URL = os.getenv("LOCALAI_URL", "http://longcat-core:8080").rstrip("/")
MODEL_NAME = os.getenv("MODEL_NAME", "longcat-video-avatar-1.5")
JOB_ROOT = Path(os.getenv("JOB_ROOT", "/data/jobs"))
API_KEY = os.getenv("GETAC_API_KEY", "")
MAX_IMAGE_BYTES = 25 * 1024 * 1024
MAX_AUDIO_BYTES = 128 * 1024 * 1024
DEFAULT_PROMPT = (
    "A professional presenter faces the camera in a bright neutral studio, "
    "speaking calmly and naturally with accurate lip movements, subtle blinking, "
    "stable facial features, minimal head turns and restrained gestures. "
    "The camera is fixed, the shoulders stay level, and the person's identity stays consistent."
)
app = FastAPI(title="Getac LongCat Avatar GB10 API", version=APP_VERSION,
              description="PNG/JPG + WAV -> LongCat-Video-Avatar-1.5 video (LocalAI GPU backend). "
                          "A generated MP4 is opaque; use a separate video matting step for PPT transparency.")
JOB_ROOT.mkdir(parents=True, exist_ok=True)
_job_lock = threading.Lock()


def _authorize(x_api_key: str | None) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid X-API-Key")


def _job_path(job_id: str) -> Path:
    try:
        u = uuid.UUID(job_id)
    except (ValueError, AttributeError):
        raise HTTPException(status_code=400, detail="Invalid job_id")
    return JOB_ROOT / str(u)


def _put_status(folder: Path, state: str, message: str = "", progress: int = 0) -> None:
    data = {"job_id": folder.name, "status": state, "message": message,
            "progress": progress, "updated_at": datetime.now(timezone.utc).isoformat()}
    tmp = folder / "status.partial"
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(folder / "status.json")


def _read_status(job_id: str) -> dict:
    file = _job_path(job_id) / "status.json"
    if not file.exists():
        raise HTTPException(status_code=404, detail="Job not found")
    return json.loads(file.read_text(encoding="utf-8"))


async def _save_upload(src: UploadFile, path: Path, limit: int) -> None:
    size = 0
    with path.open("wb") as f:
        while chunk := await src.read(1024 * 1024):
            size += len(chunk)
            if size > limit:
                path.unlink(missing_ok=True)
                raise HTTPException(status_code=413, detail="File too large")
            f.write(chunk)
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
    """Separate general LocalAI readiness from support for POST /video.

    GET /video is expected to return HTTP 405 on builds with the POST route.
    404 indicates that the installed LocalAI binary does not expose it.
    """
    result = {"backend_ready": False, "video_api_ready": False,
              "video_get_http_status": None, "model_installed": None,
              "model_list_http_status": None}
    try:
        with httpx.Client(timeout=5.0) as client:
            ready = client.get(BASE_URL + "/readyz")
            result["backend_ready"] = ready.status_code == 200
            route = client.get(BASE_URL + "/video")
            result["video_get_http_status"] = route.status_code
            result["video_api_ready"] = route.status_code == 405
            models = client.get(BASE_URL + "/v1/models")
            result["model_list_http_status"] = models.status_code
            if models.status_code == 200:
                data = models.json().get("data", [])
                ids = [str(x.get("id", "")) for x in data if isinstance(x, dict)]
                result["model_installed"] = MODEL_NAME in ids
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        result["error"] = str(exc)[:300]
    return result


def _run_job(folder: Path, image_path: Path, audio_path: Path, prompt: str,
             resolution: str, max_segments: int) -> None:
    try:
        _put_status(folder, "running", "Preparing audio/image for LocalAI", 10)
        body = {
            "model": MODEL_NAME,
            "prompt": prompt,
            "start_image": base64.b64encode(image_path.read_bytes()).decode("ascii"),
            "audio": base64.b64encode(audio_path.read_bytes()).decode("ascii"),
            "width": 832 if resolution == "480p" else 1280,
            "height": 480 if resolution == "480p" else 720,
            "response_format": "url",
            "params": {"resolution": resolution, "offload_kv_cache": "true"},
        }
        _put_status(folder, "running", "Running LongCat GPU inference (may take considerable time)", 25)
        with httpx.Client(timeout=httpx.Timeout(connect=30, read=None, write=300, pool=60)) as client:
            response = client.post(BASE_URL + "/video", json=body)
            if response.status_code == 404:
                raise RuntimeError("LocalAI POST /video returned HTTP 404. The installed "
                                   "LocalAI binary does not expose this API. On GB10 run "
                                   "./fix-video-api.sh. Details: " + response.text[:350])
            if response.is_error:
                raise RuntimeError(f"LocalAI POST /video returned HTTP {response.status_code}: "
                                   + response.text[:700])
            payload = response.json()
            (folder / "localai_response.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
            result = _extract_video_url(payload)
            if result.startswith("b64:"):
                video = base64.b64decode(result[4:])
            else:
                parsed = urlparse(result)
                allowed = urlparse(BASE_URL)
                if parsed.scheme or parsed.netloc:
                    if parsed.scheme != allowed.scheme or parsed.netloc != allowed.netloc:
                        raise RuntimeError("LocalAI returned an unexpected video host")
                    target_url = result
                else:
                    target_url = urljoin(BASE_URL + "/", result.lstrip("/"))
                _put_status(folder, "running", "Downloading the generated MP4", 90)
                video_reply = client.get(target_url)
                video_reply.raise_for_status()
                video = video_reply.content
        if len(video) < 4096:
            raise RuntimeError("Generated video too small or empty")
        (folder / "result.mp4").write_bytes(video)
        _put_status(folder, "completed", "MP4 generated; background is not transparent", 100)
    except Exception as exc:
        logging.exception("LongCat job failed: %s", folder.name)
        (folder / "error.log").write_text(repr(exc) + "\n", encoding="utf-8")
        _put_status(folder, "failed", str(exc)[:1000], 0)
    finally:
        _job_lock.release()


@app.get("/health")
def health() -> dict:
    probe = _probe_localai()
    backend_ready = probe["backend_ready"]
    video_api_ready = probe["video_api_ready"]
    model_installed = probe["model_installed"]
    return {
        "status": "ok" if backend_ready and video_api_ready and model_installed is True else "degraded",
        "version": APP_VERSION,
        "model": MODEL_NAME,
        "backend_ready": backend_ready,
        "video_api_ready": video_api_ready,
        "video_get_http_status": probe["video_get_http_status"],
        "model_installed": model_installed,
        "model_list_http_status": probe["model_list_http_status"],
        "api_port": 8500,
        "note": ("API/model checks are not proof of successful GPU inference. "
                 "If video_api_ready=false, run ./fix-video-api.sh on GB10."),
        **({"probe_error": probe["error"]} if probe.get("error") else {})
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
    probe = _probe_localai()
    if not probe["backend_ready"] or not probe["video_api_ready"]:
        raise HTTPException(status_code=503,
                            detail="LocalAI POST /video is unavailable or the server is unready "
                                   f"(GET /video HTTP {probe['video_get_http_status']}). "
                                   "On GB10 run ./fix-video-api.sh, then check /health.")
    if probe["model_installed"] is False:
        raise HTTPException(status_code=503,
                            detail=f"LocalAI model '{MODEL_NAME}' is not installed. "
                                   "Run ./fix-video-api.sh on GB10, then check /health.")
    if not _job_lock.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Only one inference at a time is supported on GB10")
    folder = JOB_ROOT / str(uuid.uuid4())
    folder.mkdir(parents=True)
    face_file = folder / ("portrait.png" if face.filename.lower().endswith(".png") else "portrait.jpg")
    audio_file = folder / "speech.wav"
    try:
        await _save_upload(face, face_file, MAX_IMAGE_BYTES)
        await _save_upload(audio, audio_file, MAX_AUDIO_BYTES)
        _put_status(folder, "queued", "Accepted by Getac API", 0)
        worker = threading.Thread(target=_run_job,
                                  args=(folder, face_file, audio_file, prompt[:2000], resolution, max_segments),
                                  daemon=True, name="longcat-" + folder.name[:8])
        worker.start()
        return {"job_id": folder.name, "status": "queued",
                "status_url": f"/api/presenter/status/{folder.name}",
                "result_url": f"/api/presenter/result/{folder.name}"}
    except Exception:
        _job_lock.release()
        raise


@app.get("/api/presenter/status/{job_id}")
def status(job_id: str, x_api_key: str | None = Header(default=None)) -> dict:
    _authorize(x_api_key)
    return _read_status(job_id)


@app.get("/api/presenter/result/{job_id}")
def result(job_id: str, x_api_key: str | None = Header(default=None)):
    _authorize(x_api_key)
    _read_status(job_id)
    file = _job_path(job_id) / "result.mp4"
    if not file.is_file():
        raise HTTPException(status_code=409, detail="Video is not ready")
    return FileResponse(file, media_type="video/mp4", filename=f"{job_id}.mp4")


@app.get("/api/presenter/log/{job_id}")
def job_log(job_id: str, x_api_key: str | None = Header(default=None)):
    _authorize(x_api_key)
    state = _read_status(job_id)
    file = _job_path(job_id) / "error.log"
    msg = file.read_text(encoding="utf-8") if file.exists() else json.dumps(state, ensure_ascii=False, indent=2)
    return {"job_id": job_id, "log": msg}
