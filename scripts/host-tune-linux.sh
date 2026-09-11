#!/usr/bin/env bash
# One-time Linux host tuning for the Beelink SER9 Pro (Ryzen AI 9 HX 370 / Radeon 890M / 64 GB).
#
# The 890M has no VRAM of its own. By default the kernel caps how much shared
# system RAM (GTT) the iGPU may map at ~50% of RAM, and the BIOS UMA carve-out is
# small. This raises the TTM page limit so the whole Q5_K_M model (21.7 GB) plus
# its KV cache fits on the GPU, and enables the performance power profile.
#
#   sudo ./scripts/host-tune-linux.sh            # 64 GB box -> ~46 GB GPU-mappable (RAM - 16 GB)
#   sudo ./scripts/host-tune-linux.sh --gb 40    # custom limit
#   sudo ./scripts/host-tune-linux.sh --dry-run  # show what would change
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

DRY=0; YES=0; FORCE=0; GB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gb) GB="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -y|--yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || die "Linux only (on Windows/macOS use the native backend)"
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run with sudo (or use --dry-run)"

mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
# Leave 16 GB for the OS, Docker, Open WebUI and its embedding model.
if [ -z "$GB" ]; then GB=$(( mem_gb > 24 ? mem_gb - 16 : mem_gb * 3 / 4 )); fi
[ "$GB" -lt "$mem_gb" ] || die "--gb ($GB) must be less than system RAM (~${mem_gb} GB)"
PAGES=$(( GB * 262144 ))   # 4 KiB pages

cur_pages="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo "?")"
info "system RAM ~${mem_gb} GB; current ttm.pages_limit=${cur_pages}"
info "target: ${GB} GB GPU-mappable -> ttm.pages_limit=${PAGES}"
g="$(gpu_gtt_gb || true)";  [ -n "$g" ] && info "current GTT total: ${g} GB"
v="$(gpu_vram_gb || true)"; [ -n "$v" ] && info "current BIOS UMA carve-out: ${v} GB"

# ── 1. kernel command line (GRUB) ──────────────────────────────────────────
SKIP_GRUB=0
if [ "$FORCE" = 0 ] && [ -n "$v" ] && [ "$v" -ge "$JC_NEED_GB" ]; then
  info "the BIOS carve-out (${v} GB) already fits Jean Claude (~${JC_NEED_GB} GB) — leaving the kernel command line alone"
  info "(to shrink the carve-out and use GTT instead, lower UMA Frame Buffer in BIOS, then re-run with --force)"
  SKIP_GRUB=1
elif [ "$FORCE" = 0 ] && [ "$cur_pages" != "?" ] && [ "$cur_pages" -ge "$PAGES" ]; then
  info "current ttm.pages_limit already >= target — leaving the kernel command line alone"
  SKIP_GRUB=1
fi

GRUB=/etc/default/grub
if [ "$SKIP_GRUB" = 1 ]; then
  :
elif [ -f "$GRUB" ]; then
  line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB" | head -n1)"
  val="${line#GRUB_CMDLINE_LINUX_DEFAULT=}"; val="${val%\"}"; val="${val#\"}"
  # drop any previous ttm/gttsize settings, then append ours
  new="$(printf '%s' "$val" | tr ' ' '\n' | { grep -vE '^(ttm\.pages_limit|ttm\.page_pool_size|amdgpu\.gttsize)=' || true; } | tr '\n' ' ' | sed 's/ *$//')"
  new="${new:+$new }ttm.pages_limit=${PAGES}"
  info "GRUB_CMDLINE_LINUX_DEFAULT:"
  echo "    old: \"$val\""
  echo "    new: \"$new\""
  if [ "$DRY" = 0 ]; then
    if [ "$YES" = 0 ]; then
      read -r -p "Apply and run update-grub? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted"
    fi
    cp "$GRUB" "${GRUB}.jean-claude.bak.$(date +%s)"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$GRUB"
    if command -v update-grub >/dev/null; then update-grub
    elif command -v grub2-mkconfig >/dev/null; then grub2-mkconfig -o /boot/grub2/grub.cfg
    else warn "regenerate your GRUB config manually"; fi
  fi
else
  warn "no $GRUB (systemd-boot?). Add this to your kernel command line manually:"
  echo "    ttm.pages_limit=${PAGES}"
fi

# ── 2. GPU device access for the invoking user ─────────────────────────────
u="${SUDO_USER:-}"
if [ -n "$u" ] && [ "$DRY" = 0 ]; then
  usermod -aG render,video "$u" && info "added $u to render,video groups"
fi

# ── 3. power profile (65 W sustained on the SER9 Pro) ──────────────────────
if command -v powerprofilesctl >/dev/null; then
  if [ "$DRY" = 0 ]; then powerprofilesctl set performance && info "power profile: performance"
  else info "would set power profile: performance"; fi
fi

# ── 4. Vulkan userspace (Mesa RADV) for diagnostics ────────────────────────
if command -v apt-get >/dev/null && ! command -v vulkaninfo >/dev/null; then
  if [ "$DRY" = 0 ]; then apt-get install -y mesa-vulkan-drivers vulkan-tools >/dev/null && info "installed vulkan-tools"
  else info "would install mesa-vulkan-drivers vulkan-tools"; fi
fi

cat <<EOF

$(bold "Next:") reboot if anything above changed, then verify with  make doctor

BIOS (optional; the menu location varies by BIOS version — look under Advanced /
AMD CBS / NBIO / GFX Configuration):
  • UMA Frame Buffer Size: leave small/Auto for the Vulkan backend (it uses GTT).
    If you use the ROCm backend and Ollama reports only a few GB of GPU memory,
    raise it to the maximum your BIOS offers — Ollama then splits layers.
  • Power mode: "Performance" / highest cTDP (65 W) if exposed.
EOF
