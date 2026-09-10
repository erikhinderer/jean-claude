#!/usr/bin/env bash
# Prepare .env for this host: secrets, GPU group IDs, and backend selection.
#   ./scripts/setup.sh                 # auto-detect backend
#   ./scripts/setup.sh --backend rocm  # vulkan | rocm | cpu | native
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

BACKEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --backend|-b) BACKEND="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ── prerequisites ──────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not found — install Docker Engine (Linux) or Docker Desktop first"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin not found"
cv="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
if ! version_ge "$cv" "2.20.0"; then
  die "Docker Compose >= 2.20 required (found $cv) for optional depends_on"
fi

# ── .env ───────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env
  info "created .env from .env.example"
fi

if [ -z "$(get_env WEBUI_SECRET_KEY)" ]; then
  set_env WEBUI_SECRET_KEY "$(random_hex 32)"
  info "generated WEBUI_SECRET_KEY"
fi

# ── host detection ─────────────────────────────────────────────────────────
OS="$(uname -s)"
IS_WSL=0
if [ "$OS" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi

if [ -z "$BACKEND" ]; then
  if [ "$OS" = "Linux" ] && [ "$IS_WSL" = 0 ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    BACKEND=vulkan
  elif [ "$OS" = "Linux" ] && [ "$IS_WSL" = 0 ]; then
    BACKEND=cpu
  else
    # Docker Desktop (macOS / Windows / WSL) can't pass the AMD iGPU into containers.
    BACKEND=native
  fi
  info "auto-selected backend: $BACKEND"
fi

case "$BACKEND" in
  vulkan) CF="docker-compose.yml:compose/gpu-vulkan.yml" ;;
  rocm)   CF="docker-compose.yml:compose/gpu-rocm.yml" ;;
  cpu)    CF="docker-compose.yml" ;;
  native) CF="docker-compose.yml:compose/native-ollama.yml" ;;
  *) die "backend must be one of: vulkan rocm cpu native" ;;
esac
set_env COMPOSE_FILE "$CF"

if [ "$BACKEND" = "cpu" ]; then
  set_env JC_NUM_THREAD "$(physical_cores)"
else
  set_env JC_NUM_THREAD ""
fi

if [ "$BACKEND" = "vulkan" ] || [ "$BACKEND" = "rocm" ]; then
  [ -e /dev/dri ] || warn "/dev/dri missing — is the amdgpu driver loaded?"
  [ "$BACKEND" = "rocm" ] && { [ -e /dev/kfd ] || warn "/dev/kfd missing — ROCm needs the amdgpu KFD (kernel >= 6.10 recommended)"; }
  node="$(ls /dev/dri/renderD* 2>/dev/null | head -n1 || true)"
  if [ -n "$node" ]; then set_env RENDER_GID "$(stat -c %g "$node")"; fi
  vg="$(getent group video | cut -d: -f3 || true)"
  if [ -n "$vg" ]; then set_env VIDEO_GID "$vg"; fi
fi

# ── hardware sanity checks (Linux) ─────────────────────────────────────────
if [ "$OS" = "Linux" ] && [ "$IS_WSL" = 0 ]; then
  kv="$(uname -r | cut -d- -f1)"
  version_ge "$kv" "6.10.0" || warn "kernel $kv: Strix Point (Radeon 890M) needs >= 6.10; 6.14+ recommended"

  mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  info "system RAM: ~${mem_gb} GB"

  if [ "$BACKEND" = "vulkan" ] || [ "$BACKEND" = "rocm" ]; then
    gtt_gb="$(gpu_gtt_gb || true)"
    vram_gb="$(gpu_vram_gb || true)"
    [ -n "$vram_gb" ] && info "iGPU UMA carve-out (BIOS): ${vram_gb} GB"
    if [ -n "$gtt_gb" ]; then
      info "iGPU GTT (shared) limit: ${gtt_gb} GB"
      if [ "$gtt_gb" -lt 32 ]; then
        warn "GTT limit is below the ~27 GB Jean Claude needs (21.7 GB weights + KV cache)."
        warn "Run: sudo ./scripts/host-tune-linux.sh   (raises the TTM limit, then reboot)"
      fi
    fi
  fi
fi

cat <<EOF

$(bold "Jean Claude is configured.")  backend=$BACKEND

  Start:        make up            (or: docker compose up -d)
  Watch model:  make logs-init     (first run downloads ~21.7 GB)
  Open:         http://localhost:$(get_env WEBUI_PORT)   — the first account you create is admin
  Tune host:    sudo ./scripts/host-tune-linux.sh   (Linux GPU backends, once)
  Benchmark:    make bench-all     (compares vulkan / rocm / cpu on this box)
EOF
if [ "$BACKEND" = "native" ]; then
  cat <<'EOF'

  native backend: install Ollama on this host (https://ollama.com/download), set
  OLLAMA_FLASH_ATTENTION=1, OLLAMA_KV_CACHE_TYPE=q8_0, OLLAMA_KEEP_ALIVE=-1 and
  OLLAMA_HOST=0.0.0.0 in its environment, restart it, then run `make up`.
EOF
fi
