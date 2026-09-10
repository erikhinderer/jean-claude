#!/usr/bin/env bash
# Health + placement check: is Jean Claude up, and is the model on the iGPU?
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

[ -f .env ] || die "no .env — run ./scripts/setup.sh first"
MODEL="$(get_env JC_MODEL_NAME)"; MODEL="${MODEL:-jean-claude}"

bold "Stack"; echo
echo "  COMPOSE_FILE=$(get_env COMPOSE_FILE)"
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null | sed 's/^/  /'

if [ "$(uname -s)" = "Linux" ]; then
  echo; bold "Host"; echo
  echo "  kernel:        $(uname -r)"
  echo "  RAM total:     $(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 )) GB"
  echo "  ttm limit:     $(( $(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0) / 262144 )) GB (pages_limit)"
  v="$(gpu_vram_gb || true)"; g="$(gpu_gtt_gb || true)"
  echo "  iGPU UMA/VRAM: ${v:-?} GB   iGPU GTT: ${g:-?} GB"
  if [ -n "$g" ] && [ "$g" -lt 32 ]; then warn "GTT < 32 GB: model will spill to CPU. Run sudo ./scripts/host-tune-linux.sh"; fi
  command -v powerprofilesctl >/dev/null && echo "  power profile: $(powerprofilesctl get 2>/dev/null)"
  [ -e /dev/kfd ] && echo "  /dev/kfd:      present (ROCm possible)" || echo "  /dev/kfd:      missing"
fi

if docker compose ps --status running --services 2>/dev/null | grep -qx ollama; then
  echo; bold "Ollama"; echo
  docker compose exec -T ollama ollama --version 2>/dev/null | sed 's/^/  /'
  echo "  GPU discovery (from logs):"
  docker compose logs ollama 2>/dev/null | grep -iE 'inference compute|no compatible|vulkan|rocm|amdgpu|gfx11' | tail -n 6 | sed 's/^/    /'
  echo "  models:"
  docker compose exec -T ollama ollama list 2>/dev/null | sed 's/^/    /'
  echo "  loaded (PROCESSOR should read 100% GPU on vulkan/rocm):"
  docker compose exec -T ollama ollama ps 2>/dev/null | sed 's/^/    /'
fi

echo; bold "Endpoints"; echo
p="$(get_env OLLAMA_PORT)"; w="$(get_env WEBUI_PORT)"
curl -fsS "http://127.0.0.1:${p:-11434}/api/tags" >/dev/null 2>&1 && echo "  Ollama API   OK   http://127.0.0.1:${p:-11434}" || echo "  Ollama API   DOWN"
curl -fsS "http://127.0.0.1:${w:-3000}/health" >/dev/null 2>&1 && echo "  Open WebUI   OK   http://localhost:${w:-3000}" || echo "  Open WebUI   DOWN (still starting? make logs)"
curl -fsS "http://127.0.0.1:${p:-11434}/api/show" -d "{\"model\":\"$MODEL\"}" >/dev/null 2>&1 \
  && echo "  Model        OK   $MODEL" || echo "  Model        MISSING — check: make logs-init"
