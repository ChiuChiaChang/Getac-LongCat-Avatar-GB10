#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ $# -ge 2 ]] || { echo "Usage: ./test.sh portrait.png speech.wav [output.mp4]" >&2; exit 2; }
IMG="$1"; WAV="$2"; OUT="${3:-longcat-test.mp4}"
[[ -f "$IMG" && -f "$WAV" ]] || { echo 'Missing photo or WAV.' >&2; exit 2; }
PORT="$(sed -n 's/^PORT=//p' .env 2>/dev/null | tail -1)"; PORT="${PORT:-8500}"
API_KEY="$(sed -n 's/^GETAC_API_KEY=//p' .env 2>/dev/null | tail -1)"; BASE="http://127.0.0.1:$PORT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HEADER=(); [[ -n "$API_KEY" ]] && HEADER=(-H "X-API-Key: $API_KEY")
echo "Creating inference request to $BASE ..."
curl -fsS "${HEADER[@]}" -F "avatar=@${IMG}" -F "audio=@${WAV}" -F 'resolution=480p' -F 'max_segments=8' "$BASE/api/presenter/create" > "$TMP/created.json"
JOB=$(python3 - "$TMP/created.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); print(j['job_id'])
PY
)
echo "Job ID: $JOB"
for i in $(seq 1 180); do
  if ! curl -fsS "${HEADER[@]}" "$BASE/api/presenter/status/$JOB" > "$TMP/status.json"; then
    echo 'Status failed.' >&2; exit 1
  fi
  STATE=$(python3 - "$TMP/status.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); print(j['status'])
PY
)
  echo "  $STATE"
  if [[ "$STATE" == 'completed' ]]; then
    curl -fsS "${HEADER[@]}" "$BASE/api/presenter/result/$JOB" -o "$OUT"
    echo "Video saved: $OUT"
    exit 0
  fi
  if [[ "$STATE" == 'failed' ]]; then
    cat "$TMP/status.json" >&2
    echo >&2
    exit 1
  fi
  sleep 20
done
echo "Inference still not completed. Job ID: $JOB ; query /api/presenter/status/$JOB" >&2
exit 1
