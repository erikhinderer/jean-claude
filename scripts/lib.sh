#!/usr/bin/env bash
# Shared helpers for Jean Claude host scripts. Source, don't execute.

bold()  { printf '\033[1m%s\033[0m' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# version_ge A B  -> true if A >= B (dotted numeric versions)
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

ENV_FILE="${ENV_FILE:-.env}"

# GPU memory Jean Claude needs: 21.7 GB weights + ~3.2 GB KV (64K, q8_0) + buffers
JC_NEED_GB=28

get_env() {
  [ -f "$ENV_FILE" ] || return 0
  { grep -E "^$1=" "$ENV_FILE" || true; } | tail -n1 | cut -d= -f2-
}

# set_env KEY VALUE — replace or append, portable across GNU/BSD
set_env() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' "$ENV_FILE" > "$tmp"
  else
    cp "$ENV_FILE" "$tmp"; printf '%s=%s\n' "$key" "$val" >> "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}

random_hex() {
  if command -v openssl >/dev/null; then openssl rand -hex "$1"
  else head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

physical_cores() {
  if command -v lscpu >/dev/null; then
    lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l | tr -d ' '
  elif [ "$(uname -s)" = "Darwin" ]; then sysctl -n hw.physicalcpu
  else echo 12; fi
}

# First amdgpu card's memory pools, in whole GB
_amdgpu_dev() {
  local d
  for d in /sys/class/drm/card*/device; do
    [ -f "$d/mem_info_gtt_total" ] && { echo "$d"; return 0; }
  done
  return 1
}
gpu_gtt_gb()  { local d; d="$(_amdgpu_dev)" || return 1; echo $(( $(cat "$d/mem_info_gtt_total")  / 1024 / 1024 / 1024 )); }
gpu_vram_gb() { local d; d="$(_amdgpu_dev)" || return 1; echo $(( $(cat "$d/mem_info_vram_total") / 1024 / 1024 / 1024 )); }
