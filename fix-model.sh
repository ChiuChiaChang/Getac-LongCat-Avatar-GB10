#!/usr/bin/env bash
# Install/verify LongCat-Video-Avatar 1.5 using the running LocalAI gallery API.
# Getac GB10 v1.0.2.0 - does not touch containers outside this Compose project.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

log() { printf '\n[Getac LongCat Model] %s\n' "$*"; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
MODEL="longcat-video-avatar-1.5"
URL="http://127.0.0.1:8080"

command -v docker >/dev/null || fail "Docker is not installed."
docker info >/dev/null 2>&1 || fail "Cannot contact Docker. Check docker group membership."
docker compose version >/dev/null || fail "Docker Compose v2 is required."
command -v python3 >/dev/null || fail "Python3 is needed for robust JSON verification: sudo apt install python3"
mkdir -p data/models

localai_get() {
  docker compose exec -T longcat-core curl -fsS --connect-timeout 10 --max-time 35 "$URL/$1"
}
model_is_registered() {
  local json="$1"
  printf '%s' "$json" | python3 -c '
import json,sys
try:
 data=json.load(sys.stdin)
 ids=[str(x.get("id", "")) for x in data.get("data", []) if isinstance(x,dict)]
 sys.exit(0 if "longcat-video-avatar-1.5" in ids else 1)
except (ValueError,AttributeError,TypeError): sys.exit(2)
'
}

log "Checking LocalAI and installed model registry..."
model_list="$(localai_get 'v1/models')" || fail "Cannot retrieve LocalAI /v1/models. Check: docker compose logs --tail=100 longcat-core"
if model_is_registered "$model_list"; then
  log "$MODEL already appears in /v1/models (no reinstall required)."
  curl -fsS --max-time 25 "http://127.0.0.1:${PORT:-8500}/health" || true
  printf '\n'
  exit 0
fi

log "Model is not registered. Submitting installation to LocalAI /models/apply..."
log "Note: the backend/checkpoint may download substantial additional data during the first GPU inference."
response="$(docker compose exec -T longcat-core curl -fsS --connect-timeout 10 --max-time 120 \
  -X POST "$URL/models/apply" -H 'Content-Type: application/json' \
  --data-binary '{"id":"localai@longcat-video-avatar-1.5"}')" ||
  fail "LocalAI model gallery install request failed. Check LocalAI logs."
log "Installer response: $response"

job_id="$(printf '%s' "$response" | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin)
 print(d.get("uuid", "") or d.get("job_id", ""))
except (ValueError,AttributeError): print("")
')"
if [[ -z "$job_id" ]]; then
  fail "LocalAI did not return an install job ID. Review the response above."
fi
log "LocalAI install job: $job_id"

completed=0
for i in $(seq 1 360); do
  status="$(localai_get "models/jobs/$job_id")" ||
    fail "Cannot query LocalAI install job. Check docker compose logs --tail=100 longcat-core."
  report="$(printf '%s' "$status" | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin)
 error=d.get("error")
 print("done" if d.get("processed") is True else "running")
 print("" if error in (None,"") else str(error))
 print(str(d.get("message","")))
except (ValueError,AttributeError) as e: print("invalid\n"+str(e)+"\n")
')"
  state="$(printf '%s\n' "$report" | sed -n '1p')"
  error="$(printf '%s\n' "$report" | sed -n '2p')"
  message="$(printf '%s\n' "$report" | sed -n '3p')"
  if [[ -n "$error" ]]; then
    log "Installer error: $error"
    fail "LongCat model installation failed; inspect: docker compose logs --tail=150 longcat-core."
  fi
  if [[ "$state" == "done" ]]; then
    log "Installation job processed: $message"
    completed=1
    break
  fi
  if (( i == 1 || i % 12 == 0 )); then
    log "Install still running: $message (check $i/360)."
  fi
  sleep 15
done
(( completed == 1 )) || fail "Model installation job did not finish within 90 minutes. Query /models/jobs/$job_id for progress."

log "Confirming installed model name in /v1/models..."
for i in $(seq 1 24); do
  model_list="$(localai_get 'v1/models')" || model_list='{}'
  if model_is_registered "$model_list"; then
    log "$MODEL is registered successfully in LocalAI."
    curl -fsS --max-time 25 "http://127.0.0.1:${PORT:-8500}/health" || true
    printf '\n'
    log "Next: ./test.sh presenter.png speech.wav output.mp4"
    exit 0
  fi
  sleep 5
done

log "The install job finished, but /v1/models does not show $MODEL."
log "Listing downloaded configuration files:"
docker compose exec -T longcat-core sh -c 'find /models -maxdepth 2 -type f \( -name "*.yaml" -o -name "*.yml" \) | head -40' || true
printf '%s\n' "$model_list"
fail "Model registration not confirmed. Preserve the installation logs; do not retry blindly."
