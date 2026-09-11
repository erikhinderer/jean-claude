#!/usr/bin/env bash
# Measure Jean Claude throughput on this box.
#   ./scripts/bench.sh                          # current backend from .env
#   ./scripts/bench.sh --backends "vulkan cpu"  # compare backends back to back
#   ./scripts/bench.sh --all                    # vulkan, rocm and cpu
#   ./scripts/bench.sh --ctx 8000 --runs 5      # ~8K-token prompt (agent-sized), 5 runs
# Every run sends a *fresh* prompt (unique first line), so Ollama's prompt cache
# can't inflate prompt-processing speed. Reports pp and generation tokens/s,
# the actual prompt size processed, and the CPU/GPU split.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

RUNS=3; BACKENDS=""; PREDICT=256; CTX=2000
while [ $# -gt 0 ]; do
  case "$1" in
    --all) BACKENDS="vulkan rocm cpu"; shift ;;
    --backends) BACKENDS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --tokens) PREDICT="$2"; shift 2 ;;
    --ctx) CTX="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
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

# Build a request body: a unique nonce first (defeats prefix caching), then a
# synthetic source file of roughly $CTX tokens, then a code-review question.
request_body() { # $1 = extra options as JSON object text ("{}" for none)
  python3 - "$MODEL" "$CTX" "$PREDICT" "$1" <<'PY'
import json, random, sys, uuid
model, ctx, predict, extra = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), json.loads(sys.argv[4])
rnd = random.Random(uuid.uuid4().int)
names = ["order", "invoice", "customer", "shipment", "ledger", "bucket", "scope", "collection", "session", "token"]
chunks, approx = [], 0
i = 0
while approx < ctx:
    a, b = rnd.choice(names), rnd.choice(names)
    fn = (f"def sync_{a}_{b}_{i}(client, {a}_id: str, retries: int = {rnd.randint(1,5)}) -> dict:\n"
          f"    \"\"\"Fetch {a} {a}_id and upsert its {b} into the {b}s collection.\"\"\"\n"
          f"    doc = client.get(f\"{a}::{{{a}_id}}\")\n"
          f"    if doc is None:\n"
          f"        raise KeyError({a}_id)\n"
          f"    for attempt in range(retries):\n"
          f"        try:\n"
          f"            return client.upsert(f\"{b}::{{doc['{b}_id']}}\", doc.get('{b}', {{}}))\n"
          f"        except TimeoutError:\n"
          f"            if attempt == retries - {rnd.randint(0,1)}:\n"
          f"                raise\n"
          f"    return {{}}\n\n")
    chunks.append(fn)
    approx += len(fn) // 3.5
    i += 1
prompt = (f"Benchmark run {uuid.uuid4()}.\n\nHere is a Python module:\n\n```python\n" + "".join(chunks) +
          "```\n\nList the bugs you find in this module, most serious first, with a one-line fix for each.")
opts = {"num_predict": predict, "temperature": 0.7}
opts.update(extra)
print(json.dumps({"model": model, "prompt": prompt, "stream": False, "keep_alive": -1, "options": opts}))
PY
}

run_one() { # $1 = extra options JSON object
  request_body "$1" | curl -fsS "$API/generate" -d @-
}

summarize() { # stdin: one JSON response per line -> "pp_tokens pp_tps gen_tps"
  python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
def rate(n,d): return n/(d/1e9) if d else 0.0
avg=lambda xs: sum(xs)/len(xs) if xs else 0
pt=avg([r.get("prompt_eval_count",0) for r in rows])
pp=avg([rate(r.get("prompt_eval_count",0),r.get("prompt_eval_duration",0)) for r in rows])
tg=avg([rate(r.get("eval_count",0),r.get("eval_duration",0)) for r in rows])
print(f"{pt:9.0f} {pp:8.1f} {tg:8.1f}")'
}

bench_backend() {
  local b="$1" extra="{}" split
  info "backend: $b"
  if [ "$b" != "current" ]; then
    COMPOSE_FILE="$(compose_file_for "$b")" docker compose up -d --force-recreate ollama >/dev/null
  fi
  wait_api
  curl -fsS "$API/show" -d "{\"model\":\"$MODEL\"}" >/dev/null || die "model $MODEL not found — run: make up (and wait for model-init)"
  if [ "$b" = "cpu" ]; then extra="{\"num_gpu\":0,\"num_thread\":$CORES}"; fi

  info "  warm-up (loads the model — can take a minute)"
  if ! run_one "$extra" >/dev/null; then
    warn "  $b: request failed (see: make logs)"; printf '%-8s FAILED\n' "$b" >> "$RESULTS"; return
  fi

  local tmp; tmp="$(mktemp)"
  for i in $(seq 1 "$RUNS"); do
    run_one "$extra" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)))' >> "$tmp"
    printf '    run %s/%s done\n' "$i" "$RUNS"
  done
  split="$(docker compose exec -T ollama ollama ps 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if($i ~ /%/) {print $i" "$(i+1); exit}}' || true)"
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
bold "Jean Claude benchmark — $MODEL, ~${CTX}-token prompt, ${PREDICT} generated tokens, ${RUNS} runs"; echo
printf '%-8s %9s %8s %8s   %s\n' backend "pp tokens" "pp t/s" "gen t/s" "processor"
cat "$RESULTS"
echo
echo "pp = prompt processing (reading input: files, agent instructions), gen = generation (writing)."
echo "Each run uses a fresh prompt, so pp is not inflated by Ollama's prompt cache."
