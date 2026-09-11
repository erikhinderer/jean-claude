#!/usr/bin/env bash
# Install OpenCode and point it at Jean Claude, with file read/write allowed by default.
#   ./scripts/install-opencode.sh            # install (if needed) + write config
#   ./scripts/install-opencode.sh --config   # only (re)write the config
# Then:  opencode ~/path/to/your/repo
#
# Writes ~/.config/opencode/opencode.json (backing up any existing file) and
# ~/.config/opencode/AGENTS.md (Jean Claude's working rules), and the sandbox test tools
# (~/.config/opencode/tools/, ~/.local/bin/jc-sandbox). Permissions:
#   read / edit / search files ....... allow  (no prompts)
#   read-only shell (ls, cat, git diff) allow
#   run_tests_sandboxed ............. allow  (sandboxed, no network)
#   sandbox_setup (installs deps) .... ask
#   test commands in the shell ....... deny   (use the sandbox)
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
SMALL="$(get_env JC_SMALL_MODEL_NAME)"; SMALL="${SMALL:-jean-claude-mini}"
# Helper model is on unless .env sets JC_SMALL_BASE_MODEL= (empty) — same rule as docker-compose.
if grep -qE '^JC_SMALL_BASE_MODEL=$' "$ENV_FILE" 2>/dev/null; then SMALL=""; fi
python3 - opencode/opencode.json.tmpl "$new" "$URL" "$MODEL" "${SMALL:-$MODEL}" "$CTX" <<'PY' || die "could not render opencode.json"
import json, sys
tmpl, out, url, model, small, ctx = sys.argv[1:]
s = (open(tmpl).read().replace("__OLLAMA_URL__", url).replace("__NUM_CTX__", ctx)
     .replace("__SMALL_MODEL__", "@@SMALL@@").replace("__MODEL__", model))
d = json.loads(s)
models = d["provider"]["jean-claude"]["models"]
helper = models.pop("@@SMALL@@")
if small != model:
    models[small] = helper
d["small_model"] = "jean-claude/" + small
json.dump(d, open(out, "w"), indent=2); open(out, "a").write("\n")
PY

for pair in "$new:opencode.json" "opencode/AGENTS.md:AGENTS.md"; do
  src="${pair%%:*}"; dst="$CFG_DIR/${pair##*:}"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.bak.$(date +%s)"; info "backed up existing $dst"
  fi
  cp "$src" "$dst"; info "wrote $dst"
done
rm -f "$new"

# ── 3. sandbox test tools (WASM + container) ───────────────────────────────
REPO="$(pwd)"
BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR" "$CFG_DIR/tools"
ln -sf "$REPO/sandbox/jc-sandbox" "$BIN_DIR/jc-sandbox"
info "linked $BIN_DIR/jc-sandbox -> $REPO/sandbox/jc-sandbox"
mkdir -p "$CFG_DIR/commands"
for c in opencode/commands/*.md; do cp "$c" "$CFG_DIR/commands/"; info "installed command /$(basename "$c" .md)"; done
for t in opencode/tools/*.ts; do
  sed "s|__JC_SANDBOX__|$BIN_DIR/jc-sandbox|g" "$t" > "$CFG_DIR/tools/$(basename "$t")"
  info "installed tool $(basename "$t" .ts)"
done
# OpenCode installs dependencies listed in the config dir's package.json at startup;
# the tools need @opencode-ai/plugin (merged, not overwritten).
python3 - "$CFG_DIR/package.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("dependencies", {}).setdefault("@opencode-ai/plugin", "latest")
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
command -v docker >/dev/null || warn "docker not found: run_tests_sandboxed needs Docker on this host"

# ── 4. check Jean Claude is reachable ──────────────────────────────────────
if curl -fsS "$URL/api/show" -d "{\"model\":\"$MODEL\"}" >/dev/null 2>&1; then
  info "Jean Claude is up at $URL (model: $MODEL)"
else
  warn "can't reach model '$MODEL' at $URL yet — start the stack with: make up"
fi

cat <<EOF

$(bold "OpenCode is set up to use Jean Claude.")

  cd ~/path/to/your/repo && git switch -c jean-claude/review   # recommended: work on a branch
  opencode                                                    # or: opencode ~/path/to/your/repo

It can read and edit files in that folder without asking. It runs tests only in the
sandbox (run_tests_sandboxed: no network, only the project folder visible); installing
test dependencies (sandbox_setup) asks first. Other shell commands prompt for approval.
Review its changes with: git diff
If 'opencode' isn't found, open a new shell or run: export PATH="\$HOME/.opencode/bin:\$PATH"
EOF
