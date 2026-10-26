#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
info(){ printf '\n[Getac LongCat] %s\n' "$*"; }
fail(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'echo "[ERROR] Installation stopped on line $LINENO. Check: docker compose logs --tail=100" >&2' ERR

info "Preflight for NVIDIA GB10 (ARM64) / LongCat-Video-Avatar 1.5"
[[ "$(uname -m)" == 'aarch64' ]] || fail 'Expected aarch64 Linux (GB10). Do not use an x86_64 CUDA image on this device.'
command -v docker >/dev/null || fail 'Docker is not installed. Install Docker Engine first.'
docker info >/dev/null 2>&1 || fail 'Cannot contact Docker daemon. Add this user to docker group or run with sudo.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 plugin is required.'
command -v curl >/dev/null || fail 'curl is required.'
command -v nvidia-smi >/dev/null || fail 'NVIDIA driver/nvidia-smi is not available.'
nvidia-smi >/dev/null || fail 'NVIDIA GPU driver is not working.'
mkdir -p data/models data/jobs
if [[ ! -f .env ]]; then cp .env.example .env; info 'Created .env (modify GETAC_API_KEY to protect LAN API).'; fi
PORT="$(sed -n 's/^PORT=//p' .env | tail -1)"; PORT="${PORT:-8500}"
if [[ "$PORT" != '8500' ]]; then info "Configured API host port: $PORT"; fi
if command -v ss >/dev/null && ss -H -lnt "sport = :$PORT" | grep -q LISTEN && ! docker ps --format '{{.Names}}' | grep -qx 'getac-longcat-api'; then
  fail "Port $PORT is occupied. Change PORT in .env."
fi
FREE_GB=$(df -Pk data | awk 'NR==2 {printf "%d", $4/1048576}')
if (( FREE_GB < 200 )); then
  info "WARNING: only ${FREE_GB} GiB free in data filesystem. Avatar + base checkpoint + caches may require substantial space; >=200 GiB free is recommended."
fi
info 'Pulling DGX Spark CUDA13 ARM64 container; existing 8300/8400 services will be left alone.'
docker compose pull longcat-core
info 'Starting the model server and Getac API (8500).'
docker compose up -d --build
info 'Waiting for LocalAI /readyz (this does not imply the model is already loaded).'
READY=0
for i in $(seq 1 90); do
  if docker compose exec -T longcat-core sh -c 'curl -fsS http://127.0.0.1:8080/readyz >/dev/null' 2>/dev/null; then
    READY=1; break
  fi
  sleep 4
done
if (( READY != 1 )); then
  docker compose logs --tail=70 longcat-core >&2 || true
  fail 'LocalAI API did not become ready. The gateway might still answer /health (degraded).'
fi

if [[ "${INSTALL_MODEL:-1}" == '1' ]]; then
  info 'Installing meituan-longcat/LongCat-Video-Avatar-1.5 from the LocalAI model gallery.'
  info 'This may download very large weights and base model components; do not interrupt unless needed.'
  if ! docker compose exec -T -e LOCALAI_MODELS_PATH=/models longcat-core local-ai models install longcat-video-avatar-1.5; then
    info 'CLI install failed. You can use the model gallery UI on port 8500 only if forwarded, or retry:'
    echo 'docker compose exec -T longcat-core local-ai models install longcat-video-avatar-1.5'
    fail 'Model weights were not confirmed installed.'
  fi
else
  info 'INSTALL_MODEL=0 selected: only API containers were installed; weights were not downloaded.'
fi

info 'Checking the LocalAI POST /video API route...'
VIDEO_PROBE_STATUS="$(docker compose exec -T longcat-core sh -c 'curl -sS --max-time 10 -X POST -H "Content-Type: application/json" --data-binary "{" -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/video' 2>/dev/null || true)"
if [[ ! "$VIDEO_PROBE_STATUS" =~ ^(400|415|422)$ ]]; then
  info "Malformed-JSON POST /video returned HTTP $VIDEO_PROBE_STATUS (expected 400/415/422)."
  fail 'LocalAI video route unavailable. Run ./fix-video-api.sh before testing Windows Studio.'
fi
info "LocalAI POST /video exists (malformed JSON rejected HTTP $VIDEO_PROBE_STATUS)."
info 'Checking Getac API status'
curl -fsS "http://127.0.0.1:$PORT/health" || true
printf '\n\nSUCCESS: deployment containers are running.\n'
printf '  Getac API: http://<GB10-IP>:%s/docs\n' "$PORT"
printf '  Check:     curl http://127.0.0.1:%s/health\n' "$PORT"
printf '  Verify model with: ./test.sh portrait.png speech.wav\n'
printf 'NOTE: only a real GPU inference test proves successful model compatibility.\n'
