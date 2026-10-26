#!/usr/bin/env bash
# Getac LongCat GB10 /video 404 repair v1.0.1.0
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
log(){ printf '\n[Getac LongCat Repair] %s\n' "$*"; }
fail(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail 'Docker not found.'
docker info >/dev/null 2>&1 || fail 'Cannot access Docker. Check docker group membership.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 required.'

PINNED='localai/localai:v4.12.1-nvidia-l4t-arm64-cuda-13'
if [[ ! -f .env ]]; then
  cp .env.example .env
  log 'Created .env using the v1.0.1.0 default image.'
fi
BEFORE="$(sed -n 's/^LOCALAI_IMAGE=//p' .env | tail -n 1)"
if [[ -z "$BEFORE" || "$BEFORE" == 'localai/localai:latest-nvidia-l4t-arm64-cuda-13' ]]; then
  cp -p .env ".env.backup.$(date +%Y%m%d_%H%M%S)"
  if grep -q '^LOCALAI_IMAGE=' .env; then
    sed -i "s|^LOCALAI_IMAGE=.*|LOCALAI_IMAGE=$PINNED|" .env
  else
    printf '\nLOCALAI_IMAGE=%s\n' "$PINNED" >> .env
  fi
  log "Pinned LocalAI to $PINNED; previous value: ${BEFORE:-unset}."
else
  log "Preserving custom LOCALAI_IMAGE=$BEFORE"
fi

log 'Pulling only the LongCat CUDA13 ARM64 image; no shutdown on pull failure.'
docker compose pull longcat-core || fail 'Image pull failed; existing services were left untouched.'
log 'Recreating only getac-longcat-core; model weights and jobs remain under ./data.'
docker compose up -d --no-deps --force-recreate longcat-core
log 'Rebuilding/restarting only getac-longcat-api (8500).'
docker compose up -d --no-deps --build gateway

log 'Waiting for LocalAI /readyz.'
READY=0
for i in $(seq 1 60); do
  if docker compose exec -T longcat-core sh -c 'curl -fsS --max-time 8 http://127.0.0.1:8080/readyz >/dev/null' 2>/dev/null; then
    READY=1; break
  fi
  sleep 5
done
if (( READY == 0 )); then
  docker compose logs --tail=80 longcat-core >&2 || true
  fail 'LocalAI did not become ready.'
fi

HTTP_CODE="$(docker compose exec -T longcat-core sh -c 'curl -sS --max-time 10 -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/video' 2>/dev/null || true)"
log "GET /video => HTTP $HTTP_CODE"
if [[ "$HTTP_CODE" != '405' ]]; then
  log 'Official LocalAI API uses POST /video; GET should return HTTP 405, not HTTP 404.'
  docker compose exec -T longcat-core sh -c 'local-ai --version || true' || true
  fail 'LocalAI video route is still missing. Provide docker compose logs --tail=100 longcat-core.'
fi

MODEL_LIST="$(docker compose exec -T longcat-core sh -c 'curl -fsS --max-time 12 http://127.0.0.1:8080/v1/models' 2>/dev/null || true)"
if ! grep -Fq 'longcat-video-avatar-1.5' <<< "$MODEL_LIST"; then
  log 'Avatar 1.5 not listed by /v1/models; installing the gallery entry without removing cached weights.'
  docker compose exec -T longcat-core local-ai models install longcat-video-avatar-1.5 || fail 'Model install failed; see logs.'
fi

PORT="$(sed -n 's/^PORT=//p' .env | tail -1)"; PORT="${PORT:-8500}"
log 'Checking Getac Gateway health with route/model diagnostics.'
curl -fsS --max-time 25 "http://127.0.0.1:$PORT/health" || fail 'The 8500 gateway did not answer.'
printf '\n'
log "Repair complete. Check http://<GB10-IP>:$PORT/docs and run ./test.sh presenter.png speech.wav output.mp4"
log 'Success of the API route does not guarantee successful GPU model inference.'
