#!/usr/bin/env bash
# Measure Jean Claude throughput on this box.
#   ./scripts/bench.sh                    # current backend from .env
#   ./scripts/bench.sh --all              # vulkan, rocm and cpu back to back
#   ./scripts/bench.sh --backends "vulkan cpu" --runs 5
# Reports prompt-processing and generation tokens/s plus the CPU/GPU split.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

RUNS=3; BACKENDS=""; PREDICT=256
while [ $# -gt 0 ]; do
  case "$1" in
    --all) BACKENDS="vulkan rocm cpu"; shift ;;
    --backends) BACKENDS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --tokens) PREDICT="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
command -v curl >/dev/null || die "curl required"
command -v python3 >/dev/null || die "python3 required"

MODEL="$(get_env JC_MODEL_NAME)"; MODEL="${MODEL:-jean-claude}"
PORT="$(get_env OLLAMA_PORT)"; PORT="${PORT:-11434}"
API="http://127.0.0.1:${PORT}/api"
ORIG_CF="$(get_env COMPOSE_FILE)"
CORES="$(physical_cores)"

PROMPT='Write a Python function that parses an ISO-8601 duration string such as "P3DT4H12M" into total seconds. Include type hints, docstring, error handling, and three pytest tests.'

compose_file_for() {
  case "$1" in
    vulkan) echo "docker-compose.yml:compose/gpu-vulkan.yml" ;;
    rocm)   echo "docker-compose.yml:compose/gpu-rocm.yml" ;;
    cpu)    echo "docker-compose.yml" ;;
    *) die "unknown backend $1" ;;
  esac
}

wait_api() {
  for _ in $(seq 1 90); do curl -fsS "$API/tags" >/dev/null 2>&1 && return 0; sleep 2; done
  die "Ollama API not reachable at $API"
}

run_one() { # $1 = extra options JSON fragment
  curl -fsS "$API/generate" -d @- <<EOF
{"model":"$MODEL","prompt":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROMPT"),
 "stream":false,"keep_alive":-1,
 "options":{"num_predict":$PREDICT,"seed":42,"temperature":0.7$1}}
EOF
}

summarize() { # stdin: one JSON response per line
  python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
def rate(n,d): return n/(d/1e9) if d else 0.0
pp=[rate(r.get("prompt_eval_count",0),r.get("prompt_eval_duration",0)) for r in rows]
tg=[rate(r.get("eval_count",0),r.get("eval_duration",0)) for r in rows]
avg=lambda xs: sum(xs)/len(xs) if xs else 0
print(f"{avg(pp):8.1f} {avg(tg):8.1f}")'
}

bench_backend() {
  local b="$1" extra="" split
  info "backend: $b"
  if [ -n "$b" ] && [ "$b" != "current" ]; then
    COMPOSE_FILE="$(compose_file_for "$b")" docker compose up -d --force-recreate ollama >/dev/null
  fi
  wait_api
  curl -fsS "$API/show" -d "{\"model\":\"$MODEL\"}" >/dev/null || die "model $MODEL not found — run: make up (and wait for model-init)"
  [ "$b" = "cpu" ] && extra=",\"num_gpu\":0,\"num_thread\":$CORES"

  info "  warm-up (loads the model — can take a minute)"
  run_one "$extra" >/dev/null || { warn "  $b: request failed (see: make logs)"; echo "$b FAILED" >> "$RESULTS"; return; }

  local tmp; tmp="$(mktemp)"
  for i in $(seq 1 "$RUNS"); do
    run_one "$extra" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)))' >> "$tmp"
    printf '    run %s/%s done\n' "$i" "$RUNS"
  done
  split="$(docker compose exec -T ollama ollama ps 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if($i ~ /%/) {print $i" "$(i+1); exit}}')"
  printf '%-8s %s   %s\n' "$b" "$(summarize < "$tmp")" "${split:-?}" >> "$RESULTS"
  rm -f "$tmp"
}

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT
if [ -z "$BACKENDS" ]; then
  bench_backend current
else
  for b in $BACKENDS; do bench_backend "$b"; done
  info "restoring backend from .env"
  COMPOSE_FILE="$ORIG_CF" docker compose up -d --force-recreate ollama >/dev/null
fi

echo
bold "Jean Claude benchmark — $MODEL, ${PREDICT} tokens, ${RUNS} runs"; echo
printf '%-8s %8s %8s   %s\n' backend "pp t/s" "gen t/s" "processor"
cat "$RESULTS"
echo
echo "pp = prompt processing, gen = generation. Pick the backend with the best gen t/s:"
echo "  make backend B=<vulkan|rocm|cpu> && make up"
