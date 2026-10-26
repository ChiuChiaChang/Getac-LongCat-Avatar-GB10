#!/usr/bin/env bash
# Getac LongCat Queue v1.1.0.0, Gateway-only deployment; leaves LocalAI/Qwen running.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$HOME/Getac-LongCat-Avatar-H200}"
if [[ ! -f "$PROJECT_DIR/docker-compose.h200.yml" || ! -f "$PROJECT_DIR/gateway/app.py" ]]; then
  echo "[ERROR] H200 project folder not found: $PROJECT_DIR" >&2; exit 1
fi
if [[ ! -f "$SCRIPT_DIR/gateway/app.py" ]]; then
  echo "[ERROR] New gateway/app.py missing from patch directory" >&2; exit 1
fi
cd "$PROJECT_DIR"
# Refuse to deploy if a GPU job appears to be in-flight, unless user deliberately overrides.
if [[ "${FORCE_DEPLOY:-0}" != "1" ]]; then
  if python3 - "$PROJECT_DIR/data/jobs" <<'PY'
import pathlib,sys,json
root=pathlib.Path(sys.argv[1]); running=[]
for p in root.glob('*/status.json'):
 try:
  if json.loads(p.read_text()).get('status') == 'running': running.append(p.parent.name)
 except (OSError,ValueError): pass
if running:
 print('[ERROR] Running LongCat job(s) detected. Do NOT redeploy while GPU is busy:')
 for j in running[:10]: print('   ',j)
 sys.exit(2)
sys.exit(0)
PY
  then :; else
    echo '[INFO] For known STALE statuses only, inspect job files first. FORCE_DEPLOY=1 is an override.' >&2
    exit 2
  fi
fi
stamp="$(date +%Y%m%d_%H%M%S)"
backup="gateway/app.py.before_queue_${stamp}"
cp gateway/app.py "$backup"
cp "$SCRIPT_DIR/gateway/app.py" gateway/app.py
printf '[Getac Queue] Backup: %s\n' "$PROJECT_DIR/$backup"
printf '[Getac Queue] Checking existing H200 Compose...\n'
sudo docker compose -f docker-compose.h200.yml config --quiet
printf '[Getac Queue] Rebuilding ONLY gateway (not LongCat Core / not Qwen)...\n'
sudo docker compose -f docker-compose.h200.yml up -d --no-deps --build gateway
printf '[Getac Queue] Current Gateway containers:\n'
sudo docker compose -f docker-compose.h200.yml ps gateway
printf '\n[Getac Queue] Checking version...\n'
if command -v curl >/dev/null; then
  curl -fsS --max-time 15 http://127.0.0.1:8500/health || true
fi
printf '\n[Getac Queue] Finished. Expected version=1.1.0.0, queue_enabled=true.\n'
printf '[Getac Queue] If rollback needed:\n'
printf '  cd %q && cp %q gateway/app.py && sudo docker compose -f docker-compose.h200.yml up -d --no-deps --build gateway\n' "$PROJECT_DIR" "$backup"
