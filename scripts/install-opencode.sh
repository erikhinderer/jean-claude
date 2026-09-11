#!/usr/bin/env bash
# Install OpenCode and point it at Jean Claude, with file read/write allowed by default.
#   ./scripts/install-opencode.sh            # install (if needed) + write config
#   ./scripts/install-opencode.sh --config   # only (re)write the config
# Then:  opencode ~/path/to/your/repo
#
# Writes ~/.config/opencode/opencode.json (backing up any existing file) and
# ~/.config/opencode/AGENTS.md (Jean Claude's working rules). Permissions:
#   read / edit / search files ....... allow  (no prompts)
#   read-only shell (ls, cat, git diff) allow
#   other shell commands, web fetch .. ask
#   git push, rm -rf, sudo ........... deny
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

CONFIG_ONLY=0
[ "${1:-}" = "--config" ] && CONFIG_ONLY=1

MODEL="$(get_env JC_MODEL_NAME)"; MODEL="${MODEL:-jean-claude}"
PORT="$(get_env OLLAMA_PORT)"; PORT="${PORT:-11434}"
CTX="$(get_env JC_NUM_CTX)"; CTX="${CTX:-65536}"
URL="${JC_OPENCODE_OLLAMA_URL:-http://127.0.0.1:${PORT}}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# ── 1. install the OpenCode CLI ────────────────────────────────────────────
export PATH="$HOME/.opencode/bin:$PATH"
if [ "$CONFIG_ONLY" = 0 ]; then
  if command -v opencode >/dev/null; then
    info "OpenCode already installed: $(opencode --version 2>/dev/null || echo '?')"
  else
    command -v curl >/dev/null || die "curl required"
    info "installing OpenCode (https://opencode.ai/install)"
    curl -fsSL https://opencode.ai/install | bash
  fi
fi

# ── 2. write config + rules ────────────────────────────────────────────────
mkdir -p "$CFG_DIR"
new="$(mktemp)"
sed -e "s|__OLLAMA_URL__|${URL}|g" -e "s|__MODEL__|${MODEL}|g" -e "s|__NUM_CTX__|${CTX}|g" \
  opencode/opencode.json.tmpl > "$new"
python3 -m json.tool "$new" >/dev/null || die "generated opencode.json is not valid JSON"

for pair in "$new:opencode.json" "opencode/AGENTS.md:AGENTS.md"; do
  src="${pair%%:*}"; dst="$CFG_DIR/${pair##*:}"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.bak.$(date +%s)"; info "backed up existing $dst"
  fi
  cp "$src" "$dst"; info "wrote $dst"
done
rm -f "$new"

# ── 3. check Jean Claude is reachable ──────────────────────────────────────
if curl -fsS "$URL/api/show" -d "{\"model\":\"$MODEL\"}" >/dev/null 2>&1; then
  info "Jean Claude is up at $URL (model: $MODEL)"
else
  warn "can't reach model '$MODEL' at $URL yet — start the stack with: make up"
fi

cat <<EOF

$(bold "OpenCode is set up to use Jean Claude.")

  cd ~/path/to/your/repo && git switch -c jean-claude/review   # recommended: work on a branch
  opencode                                                    # or: opencode ~/path/to/your/repo

It can read and edit files in that folder without asking; other shell commands
(tests, installs) prompt for approval. Review its changes with: git diff
If 'opencode' isn't found, open a new shell or run: export PATH="\$HOME/.opencode/bin:\$PATH"
EOF
