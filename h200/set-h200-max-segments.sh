#!/usr/bin/env bash
# Getac LongCat H200 max_segments updater v1.0.0.0 (2026-10-28)
# Default 32 segments. Does NOT change 8-step distilled inference.
# Usage: bash set-h200-max-segments.sh [8..64] [--no-restart]
# Scope: getac-longcat-h200-core and (if its source exists) H200 Gateway 8500.
# Qwen vLLM 30001, Prometheus, Grafana, other containers are untouched.
set -Eeuo pipefail
SEGMENTS=32
NO_RESTART=0
CORE=getac-longcat-h200-core
API=getac-longcat-h200-api
MODEL=longcat-video-avatar-1.5
warn(){ printf '[WARN] %s\n' "$*" >&2; }
info(){ printf '\n[Getac H200] %s\n' "$*"; }
fail(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --no-restart) NO_RESTART=1;;
    --help|-h) echo 'Usage: bash set-h200-max-segments.sh [8..64] [--no-restart]'; exit 0;;
    ''|*[!0-9]*) fail "Unknown argument: $arg";;
    *) SEGMENTS="$arg";;
  esac
done
[[ "$SEGMENTS" =~ ^[0-9]+$ ]] && (( SEGMENTS>=8 && SEGMENTS<=64 )) || fail 'segments must be 8..64'
command -v docker >/dev/null || fail 'Docker CLI missing'
command -v python3 >/dev/null || fail 'python3 missing'
command -v curl >/dev/null || fail 'curl missing'
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null && sudo -v && sudo docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  fail 'No Docker access (try sudo)'
fi
[[ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$CORE" 2>/dev/null || true)" == true ]] ||
  fail "$CORE is not running; nothing changed"
[[ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$API" 2>/dev/null || true)" == true ]] ||
  fail "$API is not running; cannot safely check the job queue"
MODELS="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/models"}}{{.Source}}{{end}}{{end}}' "$CORE")"
MODELS_RW="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/models"}}{{.RW}}{{end}}{{end}}' "$CORE")"
JOBS="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/data/jobs"}}{{.Source}}{{end}}{{end}}' "$API")"
[[ -d "$MODELS" && "$MODELS_RW" == true ]] || fail 'Core /models read-write mount not accessible; nothing changed'
[[ -d "$JOBS" ]] || fail 'Gateway /data/jobs mount not accessible; refusing to modify while job state is unknown'
if [[ -w "$MODELS" && -w "$JOBS" ]]; then
  PY=(python3)
else
  command -v sudo >/dev/null || fail 'Host mounts need root, but sudo is missing'
  sudo -v
  PY=(sudo python3)
fi
info "$CORE models mount: $MODELS"
info "$API jobs mount: $JOBS"
info "Target: max_segments=$SEGMENTS (8-step inference is NOT changed)"
info 'Confirming GPU queue is idle (do not submit new Studio jobs during deployment)...'

check_idle(){
  local report
  report="$("${PY[@]}" - "$JOBS" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1])
blocking=[]
for path in root.glob('*/status.json'):
    try:
        status=json.loads(path.read_text(encoding='utf-8')).get('status')
        if status in ('queued','running'):
            blocking.append(path.parent.name+':'+status)
    except (OSError,ValueError) as e:
        blocking.append(path.parent.name+':unreadable')
print('\n'.join(blocking[:20]))
PY
)" || fail 'Cannot read job statuses'
  [[ -z "$report" ]] || fail "Gateway still has pending/running jobs; no change made:
$report
Clear legitimate work first; do not restart Core during inference."
  local health
  health="$(curl --noproxy '*' -fsS --max-time 12 http://127.0.0.1:8500/health)" ||
    fail 'Cannot query gateway /health; stop to avoid interrupting a job'
  printf '%s' "$health" | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin)
 assert d.get("queue_enabled") is True, "Unexpected/non-FIFO Gateway"
 assert not d.get("worker_busy",True), "LongCat inference is running"
 assert d.get("queue_length",999)==0, "Gateway has waiting jobs"
except (Exception,AssertionError) as e:
 print("[ERROR] Gateway is busy or its state cannot be verified:",e,file=sys.stderr)
 sys.exit(1)
' || fail 'Gateway is not idle'
}
check_idle

# Discover the H200 Compose folder from Docker labels; fallback only if needed.
COMPOSE_DIR="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$API" 2>/dev/null || true)"
if [[ -z "$COMPOSE_DIR" || "$COMPOSE_DIR" == '<no value>' || ! -f "$COMPOSE_DIR/docker-compose.h200.yml" ]]; then
  COMPOSE_DIR="$HOME/Getac-LongCat-Avatar-H200"
fi
GATEWAY_PY="$COMPOSE_DIR/gateway/app.py"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.h200.yml"
HAS_GATEWAY_SOURCE=0
if [[ -f "$GATEWAY_PY" && -f "$COMPOSE_FILE" ]]; then
  HAS_GATEWAY_SOURCE=1
  info "Gateway source found: $GATEWAY_PY"
else
  warn "Gateway project source missing. Will change Core YAML only; API explicitly submitted max_segments=32 may be rejected by its previous <=20 validation."
fi

# Make all checks before the first filesystem change.
CHECK="$("${PY[@]}" - "$MODELS" "$MODEL" <<'PY'
from pathlib import Path
import sys,re
root=Path(sys.argv[1]).resolve()
model=sys.argv[2]
paths=[]
for directory in (root,root/'config',root/'configs'):
 if directory.is_dir():
  for ext in ('*.yaml','*.yml'): paths+=list(directory.glob(ext))
matches=[]
for p in paths:
 if not p.is_file() or p.is_symlink(): continue
 text=p.read_text(encoding='utf-8-sig')
 expected=re.search(r'^name\s*:\s*["\x27]?'+re.escape(model)+r'["\x27]?\s*(?:#.*)?$',text,re.M)
 named=p.stem==model and re.search(r'^backend\s*:\s*longcat-video\s*(?:#.*)?$',text,re.M)
 if expected or named: matches.append(p)
if len(matches)!=1:
 print('Matching model YAML:',*[str(x) for x in matches],sep='\n',file=sys.stderr)
 print('Available YAML:',*[str(x) for x in paths[:25]],sep='\n',file=sys.stderr)
 raise SystemExit('Expected precisely one LongCat Avatar YAML; leaving models unchanged')
print(str(matches[0]))
PY
)" || fail 'Model YAML preflight failed'
info "Found LocalAI model config: $CHECK"
if (( HAS_GATEWAY_SOURCE )); then
  python3 - "$GATEWAY_PY" <<'PY' || fail 'Gateway validation is unexpected; no changes made'
import pathlib,sys,re
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
assert re.search(r'max_segments\s*:\s*int\s*=\s*Form\(default=\d+\)',s), 'Gateway max_segments form not found'
assert re.search(r'1\s*<=\s*max_segments\s*<=\s*\d+',s), 'Gateway range check not found'
PY
  (cd "$COMPOSE_DIR" && "${DOCKER[@]}" compose -f docker-compose.h200.yml config --quiet) ||
    fail 'H200 Docker Compose configuration invalid; no changes made'
fi
check_idle

# Edit the real host-mounted LocalAI YAML atomically, with timestamped backup.
info "Updating LocalAI YAML to max_segments=$SEGMENTS"
PATCH_RESULT="$("${PY[@]}" - "$CHECK" "$SEGMENTS" <<'PY'
from pathlib import Path
from datetime import datetime
import os,re,shutil,sys,tempfile
p=Path(sys.argv[1]); limit=int(sys.argv[2])
old=p.read_text(encoding='utf-8-sig')
if re.search(r'^options\s*:\s*\S+',old,re.M):
 raise SystemExit('Inline/scalar options syntax is not supported; no change made')
lines=old.splitlines(keepends=True)
nl='\r\n' if '\r\n' in old else '\n'
top=[i for i,line in enumerate(lines) if re.match(r'^options\s*:\s*(?:#.*)?$',line.strip('\r\n'))]
if len(top)>1: raise SystemExit('Multiple options blocks; no modification made')
if top:
 i=top[0]; end=i+1
 while end<len(lines):
  line=lines[end]
  if line.strip() and not line[0].isspace() and not line.lstrip().startswith('#'):break
  end+=1
 options=lines[i+1:end]
 if not options and re.search(r'^options\s*:\s*\[\s*\]\s*$',lines[i].strip()):
  raise SystemExit('Inline list syntax not supported; no change made')
 hits=[]
 for j in range(i+1,end):
  s=lines[j].rstrip('\r\n')
  if 'max_segments' in s and not s.lstrip().startswith('#'):
   m=re.match(r'^(?P<prefix>\s*-\s*[\'"]?max_segments\s*:\s*)(?P<val>\d+)(?P<suffix>[\'"]?\s*(?:#.*)?)$',s)
   if not m: raise SystemExit('Unexpected max_segments option syntax; no change made')
   hits.append((j,m))
 if len(hits)>1:raise SystemExit('Duplicate max_segments option; no change made')
 if hits:
  j,m=hits[0]
  lines[j]=m['prefix']+str(limit)+m['suffix']+nl
 else:
  indent='  '
  for item in options:
   m=re.match(r'^(\s*)-\s',item)
   if m: indent=m[1];break
  lines.insert(end,f'{indent}- max_segments:{limit}{nl}')
else:
 backend=next((i for i,line in enumerate(lines) if re.match(r'^backend\s*:',line)),None)
 if backend is None:raise SystemExit('No options/backend key; no change made')
 lines.insert(backend+1,f'options:{nl}  - max_segments:{limit}{nl}')
new=''.join(lines)
if new==old:
 print('CHANGED=0\nFILE='+str(p)+'\nCURRENT='+str(limit))
 sys.exit(0)
if not re.search(r'^\s*-\s*[\'"]?max_segments\s*:\s*'+str(limit)+r'[\'"]?\s*(?:#.*)?$',new,re.M):
 raise SystemExit('Post-edit validation failed')
backup=p.with_name(p.name+'.bak.'+datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
shutil.copy2(p,backup)
fd,temp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
try:
 with os.fdopen(fd,'w',encoding='utf-8',newline='') as out:
  out.write(new);out.flush();os.fsync(out.fileno())
 shutil.copystat(p,temp)
 os.replace(temp,p)
except BaseException:
 if os.path.exists(temp):os.unlink(temp)
 raise
print('CHANGED=1\nFILE='+str(p)+'\nBACKUP='+str(backup)+'\nCURRENT='+str(limit))
PY
)" || fail 'Unable to update H200 model YAML (backup exists if edit started)'
printf '%s\n' "$PATCH_RESULT"

GW_CHANGED=0
if (( HAS_GATEWAY_SOURCE )); then
  info 'Updating Gateway API accepted range/default to 32 (without changing GPU inference steps)'
  if [[ -w "$GATEWAY_PY" ]]; then GW_PY=(python3); else GW_PY=(sudo python3); fi
  GATEWAY_RESULT="$("${GW_PY[@]}" - "$GATEWAY_PY" "$SEGMENTS" <<'PY'
import pathlib,sys,re,shutil,os,tempfile
from datetime import datetime
p=pathlib.Path(sys.argv[1]); limit=int(sys.argv[2])
s=p.read_text(encoding='utf-8')
a,n1=re.subn(r'(max_segments\s*:\s*int\s*=\s*Form\(default=)\d+(\))',lambda m:m[1]+str(limit)+m[2],s,count=1)
b,n2=re.subn(r'(1\s*<=\s*max_segments\s*<=\s*)\d+',r'\g<1>64',a,count=1)
b=b.replace('max_segments=1..20','max_segments=1..64')
if n1!=1 or n2!=1:raise SystemExit('Gateway patterns changed; original source remains unchanged')
if b==s:print('CHANGED=0');sys.exit(0)
backup=p.with_name(p.name+'.bak.'+datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
shutil.copy2(p,backup)
fd,temp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
try:
 with os.fdopen(fd,'w',encoding='utf-8') as out:out.write(b)
 shutil.copystat(p,temp)
 os.replace(temp,p)
except BaseException:
 if os.path.exists(temp):os.unlink(temp)
 raise
print('CHANGED=1\nBACKUP='+str(backup))
PY
)" || fail 'Could not safely patch Gateway; YAML already updated. See backup and fix before restart.'
  printf '%s\n' "$GATEWAY_RESULT"
  if grep -q '^CHANGED=1' <<< "$GATEWAY_RESULT"; then GW_CHANGED=1; fi
fi

if (( NO_RESTART )); then
  info 'Configuration updated, but no containers restarted (--no-restart).'
  printf 'After GPU jobs finish, restart Core:\n  sudo docker restart %s\n' "$CORE"
  if (( GW_CHANGED )); then
    printf 'Restart Gateway using Compose:\n  cd %q && sudo docker compose -f docker-compose.h200.yml up -d --no-deps --build gateway\n' "$COMPOSE_DIR"
  fi
  exit 0
fi

check_idle
info "Restarting ONLY $CORE; Qwen 30001 is untouched"
"${DOCKER[@]}" restart "$CORE" >/dev/null ||
  fail 'Failed to restart H200 Core. YAML still modified; see docker logs.'
READY=0
for i in $(seq 1 90); do
 if "${DOCKER[@]}" exec "$CORE" curl -fsS --max-time 3 http://127.0.0.1:8080/readyz >/dev/null 2>&1; then READY=1;break;fi
 sleep 2
done
(( READY )) || fail 'Core did not become ready in 180s; check sudo docker logs --tail 150 getac-longcat-h200-core'

if (( GW_CHANGED )); then
 info "Rebuilding ONLY H200 Gateway $API (no Core/Qwen rebuild)"
 (cd "$COMPOSE_DIR" && "${DOCKER[@]}" compose -f docker-compose.h200.yml up -d --no-deps --build gateway) ||
  fail 'Gateway rebuild failed; its source is backed up'
fi
info 'Done. LocalAI YAML max_segments updated. This does NOT prove 90-100 sec GPU inference can complete.'
info 'Check: curl -fsS http://127.0.0.1:8500/health | python3 -m json.tool'
info "Logs: sudo docker logs -f --tail 100 $CORE"
