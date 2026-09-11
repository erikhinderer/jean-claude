#!/bin/sh
# Runs inside the one-shot `model-init` container (ollama image, POSIX sh).
# 1. waits for the Ollama server
# 2. pulls the Q5_K_M GGUF from Hugging Face (only if missing, or JC_UPDATE_BASE=1)
# 3. builds the `jean-claude` model from ollama/Modelfile.tmpl
# 4. builds the small helper model (jean-claude-mini) used for titles/summaries
# 5. optionally preloads both so the first chat doesn't wait on a 22 GB load
set -eu

BASE="${JC_BASE_MODEL:-hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q5_K_M}"
NAME="${JC_MODEL_NAME:-jean-claude}"
CTX="${JC_NUM_CTX:-65536}"
TMPL=/jc/ollama/Modelfile.tmpl
OUT=/tmp/Modelfile

log() { printf '[model-init] %s\n' "$*"; }

log "waiting for Ollama at ${OLLAMA_HOST} ..."
i=0
until ollama list >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 150 ]; then log "Ollama never became reachable"; exit 1; fi
  sleep 2
done

if [ "${JC_UPDATE_BASE:-0}" = "1" ] || ! ollama show "$BASE" >/dev/null 2>&1; then
  log "pulling ${BASE} (≈21.7 GB on first run — this takes a while)"
  ollama pull "$BASE"
else
  log "base model already present: ${BASE}"
fi

# Optional per-host parameters
EXTRA=""
if [ -n "${JC_NUM_THREAD:-}" ]; then EXTRA="${EXTRA}PARAMETER num_thread ${JC_NUM_THREAD}
"; fi
if [ -n "${JC_NUM_GPU:-}" ]; then EXTRA="${EXTRA}PARAMETER num_gpu ${JC_NUM_GPU}
"; fi
if [ -n "${JC_NUM_BATCH:-}" ]; then EXTRA="${EXTRA}PARAMETER num_batch ${JC_NUM_BATCH}
"; fi

awk -v base="$BASE" -v ctx="$CTX" -v extra="$EXTRA" '
  /^# Placeholders:/ { next }
  { gsub(/__BASE_MODEL__/, base); gsub(/__NUM_CTX__/, ctx) }
  /^__EXTRA_PARAMS__$/ { printf "%s", extra; next }
  { print }
' "$TMPL" > "$OUT"

log "creating ${NAME} (num_ctx=${CTX}${JC_NUM_THREAD:+, num_thread=$JC_NUM_THREAD}${JC_NUM_GPU:+, num_gpu=$JC_NUM_GPU}${JC_NUM_BATCH:+, num_batch=$JC_NUM_BATCH})"
ollama create "$NAME" -f "$OUT"

# Small helper model for background tasks (session titles/summaries in OpenCode, chat
# titles/tags in Open WebUI). Running those on a separate, tiny model keeps them from
# replacing the main model's cached conversation (Ollama runs one slot per model here).
SMALL_BASE="${JC_SMALL_BASE_MODEL:-}"
SMALL_NAME="${JC_SMALL_MODEL_NAME:-jean-claude-mini}"
if [ -n "$SMALL_BASE" ]; then
  if [ "${JC_UPDATE_BASE:-0}" = "1" ] || ! ollama show "$SMALL_BASE" >/dev/null 2>&1; then
    log "pulling helper model ${SMALL_BASE}"
    ollama pull "$SMALL_BASE"
  fi
  printf 'FROM %s\nPARAMETER num_ctx %s\nPARAMETER temperature 0.3\nPARAMETER top_p 0.9\n' "$SMALL_BASE" "$CTX" > /tmp/Modelfile.mini
  log "creating ${SMALL_NAME} from ${SMALL_BASE} (num_ctx=${CTX})"
  ollama create "$SMALL_NAME" -f /tmp/Modelfile.mini
fi

if [ "${JC_PRELOAD:-1}" = "1" ]; then
  log "preloading ${NAME} into memory ..."
  ollama run "$NAME" "Reply with exactly one word: ready" || log "preload failed (model is still created)"
  if [ -n "$SMALL_BASE" ]; then ollama run "$SMALL_NAME" "Reply with exactly one word: ready" >/dev/null || true; fi
fi

ollama ps || true
log "done — open Open WebUI and pick '${NAME}'"
