#!/usr/bin/env bash
# Getac LongCat Avatar GB10 - safe LocalAI max_segments update v1.0.0.0
# Usage: bash set-longcat-max-segments.sh [8..64] [--no-restart]
# Preserves the 57GB /models checkpoint; edits only Avatar's YAML model options.
set -Eeuo pipefail

MODEL_NAME='longcat-video-avatar-1.5'
CORE='getac-longcat-core'
GATEWAY='getac-longcat-api'
SEGMENTS=32
RESTART=1

log() { printf '\n[Getac LongCat] %s\n' "$*"; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage: bash %s [segments: 8..64] [--no-restart]\n' "$0"
  printf 'Default: 32 segments. Stops if an active Gateway job is found.\n'
}
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --no-restart) RESTART=0 ;;
    *[!0-9]*|'') fail "Unknown argument: $arg" ;;
    *) SEGMENTS="$arg" ;;
  esac
done
[[ "$SEGMENTS" =~ ^[0-9]+$ ]] && (( SEGMENTS >= 8 && SEGMENTS <= 64 )) || fail 'segments must be an integer from 8 to 64.'
command -v python3 >/dev/null || fail 'python3 is required on the GB10 host.'
command -v docker >/dev/null || fail 'docker is not installed.'

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null && sudo -v && sudo docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  fail 'Cannot access Docker; check Docker daemon and sudo rights.'
fi

[[ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$CORE" 2>/dev/null || true)" == 'true' ]] ||
  fail "Container $CORE is not running. This script does not create/reinstall containers."

# Read the actual host mount, not the terminal's current directory.
MOUNT_SOURCE="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/models"}}{{.Source}}{{end}}{{end}}' "$CORE")"
MOUNT_RW="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/models"}}{{.RW}}{{end}}{{end}}' "$CORE")"
[[ -n "$MOUNT_SOURCE" && -d "$MOUNT_SOURCE" ]] || fail "Cannot access $CORE's /models host mount. Stop without changing data."
[[ "$MOUNT_RW" == 'true' ]] || fail '/models is read-only; not changing configuration.'
log "Detected $CORE /models -> $MOUNT_SOURCE"
log "Target: $MODEL_NAME, max_segments=$SEGMENTS"

if [[ -w "$MOUNT_SOURCE" ]]; then
  PYTHON=(python3)
elif command -v sudo >/dev/null; then
  sudo -v
  PYTHON=(sudo python3)
else
  fail "No write access to $MOUNT_SOURCE and sudo unavailable."
fi

# Fail closed if the local gateway still shows an active or queued job.
# A last update <24h ago is considered possibly active; stale records beyond
# this threshold are ignored, and manual --no-restart is always available.
if (( RESTART )) && [[ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$GATEWAY" 2>/dev/null || true)" == 'true' ]]; then
  JOB_ROOT="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/data/jobs"}}{{.Source}}{{end}}{{end}}' "$GATEWAY" 2>/dev/null || true)"
  if [[ -n "$JOB_ROOT" && -d "$JOB_ROOT" ]]; then
    ACTIVE="$("${PYTHON[@]}" - "$JOB_ROOT" <<'PY'
import sys, pathlib, json, time
root = pathlib.Path(sys.argv[1])
active=[]
for p in root.glob('*/status.json'):
    try:
        if time.time()-p.stat().st_mtime > 86400: continue
        v=json.loads(p.read_text(encoding='utf-8'))
        if v.get('status') in ('queued','running'):
            active.append(p.parent.name)
    except (OSError, ValueError): pass
print(','.join(active[:5]))
PY
)"
    [[ -z "$ACTIVE" ]] || fail "Active/queued LongCat job(s): $ACTIVE. Wait until completed, then rerun; no changes made."
  else
    log 'NOTE: Gateway job mount not available. Make sure no video generation is in progress.'
  fi
fi

# The Gallery config is normally /models/longcat-video-avatar-1.5.yaml.
# Discover by exact model name, not by broad filename replacement.
RESULT="$("${PYTHON[@]}" - "$MOUNT_SOURCE" "$SEGMENTS" "$MODEL_NAME" <<'PY'
import sys, pathlib, re, os, shutil, tempfile, datetime
root = pathlib.Path(sys.argv[1]).resolve()
requested = int(sys.argv[2])
name = sys.argv[3]

# Look only in the model config directory and one config subdirectory;
# never recursively scan HF checkpoints/cache (57GB model files).
search_dirs = [root, root/'config', root/'configs']
files=[]
for folder in search_dirs:
    if folder.is_dir():
        files += [p for ext in ('*.yaml','*.yml') for p in folder.glob(ext) if p.is_file()]

matches=[]
for p in files:
    content=p.read_text(encoding='utf-8-sig')
    exact_name = re.search(r'^name\s*:\s*[\'\"]?'+re.escape(name)+r'[\'\"]?\s*(?:#.*)?$', content, re.M)
    named_file = p.stem.lower()==name and re.search(r'^backend\s*:\s*longcat-video\s*(?:#.*)?$', content, re.M)
    if exact_name or named_file:
        matches.append((p,content))
if len(matches)!=1:
    print('CANDIDATES:',*[str(p) for p,_ in matches],sep='\n',file=sys.stderr)
    print('FOUND_YAML:',*[str(p) for p in files[:30]],sep='\n',file=sys.stderr)
    raise SystemExit('Expected exactly one LongCat Avatar YAML config; none or multiple found. No files changed.')
p,old=matches[0]
if not p.is_file() or p.is_symlink() or not p.resolve().is_relative_to(root):
    raise SystemExit('Unsafe YAML path. No changes made.')
lines=old.splitlines(keepends=True)
newline='\r\n' if '\r\n' in old else '\n'
option_header=[i for i,s in enumerate(lines) if re.match(r'^options\s*:\s*(?:#.*)?\r?\n?$',s)]
if len(option_header)>1:
    raise SystemExit('Ambiguous multiple options blocks; no changes made.')

oldvalue='(not set)'
if option_header:
    i=option_header[0]
    stop=i+1
    while stop<len(lines):
        line=lines[stop]
        if line.strip() and not line[0].isspace() and not line.lstrip().startswith('#'): break
        stop+=1
    hits=[]
    expr=re.compile(r'^(?P<indent>\s*-\s*)(?P<q>[\'\"]?)(?P<key>max_segments)(?P<sep>\s*:\s*)(?P<n>\d+)(?P=q)(?P<tail>\s*(?:#.*)?)$')
    for j in range(i+1,stop):
        if m:=expr.match(lines[j].rstrip('\r\n')):
            hits.append((j,m))
        elif 'max_segments' in lines[j] and not lines[j].lstrip().startswith('#'):
            raise SystemExit(f'Unsupported max_segments syntax at {p}:{j+1}; no changes made.')
    if len(hits)>1: raise SystemExit('Multiple max_segments entries; no changes made.')
    if hits:
        j,m=hits[0]
        oldvalue=m['n']
        lines[j]=(m['indent']+m['q']+m['key']+m['sep']+str(requested)+m['q']+m['tail']+newline)
    else:
        indent='  '
        for line in lines[i+1:stop]:
            m=re.match(r'^(\s*)-',line)
            if m: indent=m[1];break
        lines.insert(stop,f'{indent}- max_segments:{requested}{newline}')
else:
    # The gallery may omit options when using defaults.
    idx=next((j for j,s in enumerate(lines) if re.match(r'^backend\s*:',s)),None)
    if idx is None: raise SystemExit('No backend key or options block; no changes made.')
    lines.insert(idx+1,f'options:{newline}  - max_segments:{requested}{newline}')

new=''.join(lines)
if old==new:
    print(f'UNCHANGED={p}\nPREVIOUS={oldvalue}\nCURRENT={requested}')
    raise SystemExit(0)
# Pre-validate the resulting line before touching the original.
if not re.search(r'^\s*-\s*[\'\"]?max_segments\s*:\s*'+str(requested)+r'[\'\"]?\s*(?:#.*)?$',new,re.M):
    raise SystemExit('Validation failed; original YAML preserved.')
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
backup=p.with_name(p.name+'.bak.'+stamp)
if backup.exists(): raise SystemExit(f'Backup already exists: {backup}')
shutil.copy2(p,backup)
fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
try:
    with os.fdopen(fd,'w',encoding='utf-8',newline='') as out:
        out.write(new)
        out.flush()
        os.fsync(out.fileno())
    shutil.copystat(p,tmp)
    os.replace(tmp,p)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
print(f'UPDATED={p}\nBACKUP={backup}\nPREVIOUS={oldvalue}\nCURRENT={requested}')
PY
)" || fail 'Model YAML update failed; see details above.'
printf '%s\n' "$RESULT"

if (( ! RESTART )); then
  log "Config saved. Core NOT restarted (--no-restart). After all jobs complete, run: sudo docker restart $CORE"
  exit 0
fi

log "Restarting only $CORE (gateway and other AI services are not restarted)..."
"${DOCKER[@]}" restart "$CORE" >/dev/null || fail 'Core restart failed. Check docker logs getac-longcat-core.'

READY=0
for i in $(seq 1 90); do
  if "${DOCKER[@]}" exec "$CORE" curl -fsS --max-time 3 http://127.0.0.1:8080/readyz >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if (( ! READY )); then
  fail 'Saved YAML and restarted Core, but LocalAI /readyz not healthy in 180s. Check docker logs getac-longcat-core.'
fi
log "Done. max_segments=$SEGMENTS is configured (not yet a 90s GPU inference test)."
log 'Gateway 8500 and other AI containers were not restarted.'
log 'Validate API: curl -fsS http://127.0.0.1:8500/health'
