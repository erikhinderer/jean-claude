# Jean Claude

A fully local coding chatbot: **Qwen3-Coder-30B-A3B-Instruct (Q5_K_M)** served by **Ollama**, with **Open WebUI** as the chat UI, all in Docker.

<img width="1470" height="812" alt="image" src="https://github.com/user-attachments/assets/070add1f-2697-4064-b045-9754c3cafbdf" />

| Target hardware | |
|---|---|
| CPU | AMD Ryzen AI 9 HX 370: 12 Zen 5 cores / 24 threads, up to 5.1 GHz |
| GPU | Radeon 890M iGPU: RDNA 3.5, 16 CUs, `gfx1150`, no dedicated VRAM |
| Memory | 64 GB LPDDR5X-8000 (unified, shared with the iGPU) |
| Storage | 2 TB PCIe 4.0 NVMe |

## Quick start

```bash
git clone <this repo> jean-claude && cd jean-claude
make setup          # writes .env: secret key, GPU group IDs, picks a backend
sudo make tune      # Linux + GPU only, one time: lets the iGPU use ~46 GB of RAM. Reboot afterwards.
make up             # starts Ollama + Open WebUI and pulls the 21.7 GB model
make logs-init      # follow the download / model build
```

Then open **http://localhost:3000** (or `http://<mini-pc-ip>:3000` from another machine). The first account you create becomes the admin. Once you've signed up, set `WEBUI_ENABLE_SIGNUP=False` in `.env` and run `make up` again.

`make doctor` shows whether the model landed on the GPU. `make bench-all` measures every backend on your machine.

## Working with local code bases (Workspace → Knowledge)

Jean Claude can't read files on your computer by itself. Open WebUI runs in its own container, and the model only sees what you send it. To have it review a whole code base in the chat UI, load the code into a **knowledge base**. Open WebUI indexes the files, and the model searches them with its built-in knowledge tools (`search_knowledge_files`, `query_knowledge_files`).

**1. Make a clean copy of the repository** on the machine running your browser, because uploads go through the browser. `git archive` exports only tracked files, so `.git`, `node_modules`, virtualenvs, build output and git-ignored secrets such as `.env` stay out:

```bash
mkdir -p ~/kb/couchbase-data-generator
git -C ~/github-erikhinderer/couchbase-data-generator archive HEAD | tar -x -C ~/kb/couchbase-data-generator
```

**2. Create the knowledge base.** Go to **Workspace → Knowledge → +**, give it a name (for example `couchbase-data-generator`) and a short description, then **Create**.

**3. Upload the code.** Open the knowledge base, click **+**, choose **Upload directory** and select the folder from step 1. Wait until every file shows as processed. Indexing runs on the CPU and can take a few minutes for a large repo.

**4. Use it in a chat.** In a new chat with `jean-claude`, type `#` in the message box, pick the knowledge base, then ask. For example:

> Review this codebase for bugs, most serious first. For each one give the file, the line, what goes wrong and a suggested fix.

Other prompts that work well: *"Explain how data generation flows from the CLI to Couchbase"*, *"Which functions have no error handling around network calls?"*, *"Write unit tests for `<file>`"*.

**5. Optional: make a dedicated assistant.** Go to **Workspace → Models → +**, choose `jean-claude` as the base model, and attach the knowledge base under **Knowledge**. Give it a name like *Couchbase Data Generator Reviewer*. Every chat with that model then has the code available automatically.

**Keep it current.** A knowledge base is a snapshot. After significant changes, re-export (step 1), then delete the old files in the knowledge base and upload the new folder, or delete and recreate the knowledge base.

**What to expect:**

- **The model sees search results, not the whole repo.** Retrieval sends it the chunks most relevant to your question, so specific questions ("how are bucket credentials handled?") get better answers than "check everything". For a whole-file review, attach individual files with **+** in the chat box instead.
- **Small repos can be sent in full.** After attaching the knowledge base (or a file) in the chat box, click it and choose **Use Entire Document**. Open WebUI then sends the complete contents instead of search excerpts. This only works if the code fits in the 64K-token context; under ~20K tokens is where it beats search. The global switch is **Admin Panel → Settings → Documents → Bypass Embedding and Retrieval**. It applies to every chat and loads *every* file of an attached knowledge base, so leave it off for large repos.
- **The chat UI is read-only.** Here Jean Claude can find bugs and propose fixes, but it can't edit files or run your tests. To have it make the changes and run the tests itself, use OpenCode (next section).
- **Don't upload secrets.** Check the exported folder for credentials, keys or `.env` files before uploading. Anything in a knowledge base is visible to users you share it with.

## Coding agent: OpenCode (reads and writes your files)

The chat UI can't touch your files, but Jean Claude can work directly on a repository through [OpenCode](https://opencode.ai), an open-source terminal coding agent. OpenCode runs on the host, in your project folder. It gives Jean Claude tools to list, read, search and **edit files** and to run shell commands, and it executes what the model asks for. The model still runs locally in Ollama, so no code leaves the machine.

**Install it (once per machine):**

```bash
make opencode        # installs the OpenCode CLI and writes ~/.config/opencode/{opencode.json,AGENTS.md}
```

This points OpenCode at the local Ollama API (`http://127.0.0.1:11434/v1`, model `jean-claude`, 64K context) for both its main and background tasks, so nothing goes to a cloud model. Any existing `opencode.json` is backed up first. Run `./scripts/install-opencode.sh --config` to rewrite only the config, for example after changing `JC_NUM_CTX`.

**Use it:**

```bash
cd ~/github-erikhinderer/couchbase-data-generator
git switch -c jean-claude/review      # work on a branch so every change is easy to review or discard
opencode
```

Then ask in plain language. For example: *"Review this repository for bugs, run the tests, and fix anything that's broken. Explain each change before you make it."* Jean Claude runs the tests itself, inside the sandbox described in the next section. When it's done, review the work with `git diff` and commit what you want to keep.

**Default permissions** (from `opencode/opencode.json.tmpl`):

| Action | Default |
|---|---|
| Read, search and **edit files** in the project | **allow**: no prompts |
| Read-only shell commands (`ls`, `cat`, `grep`, `find`, `git status/diff/log/show`) | allow |
| Running tests via `run_tests_sandboxed` (no network, project folder only) | allow |
| Installing test dependencies via `sandbox_setup` (network) | ask |
| Test commands in the shell (`pytest`, `npm test`, `go test`, …) | deny: use the sandbox |
| Any other shell command (installs, builds) and web fetches | ask |
| Files outside the project folder | ask |
| `git push`, `rm -rf`, `sudo` | deny |

`opencode/AGENTS.md` holds Jean Claude's working rules: read the project first, make small focused changes, run the tests, suggest a branch, never touch secrets or push. To change permissions for everyone, edit the template and re-run `make opencode`. To change them for one project, add an `opencode.json` to that project's root. OpenCode merges project settings over the global config.

**Speed:** OpenCode sends a large instruction prompt (~7K tokens) with the first request. On the Radeon 860M that takes roughly 40 seconds, and later steps are much faster because Ollama reuses the processed prompt. Keep `jean-claude` on the GPU (`make ps` should show `100% GPU`).

## Sandboxed test runs (WebAssembly + container)

Jean Claude runs its own tests through OpenCode, but never directly on the host. Two custom OpenCode tools (installed by `make opencode`) route every test run through `sandbox/jc-sandbox`:

| Tool | What it does | Permission |
|---|---|---|
| `run_tests_sandboxed` | Detects the project and runs its tests in a sandbox. Returns the output (last 200 lines) and the exit code. | allow |
| `sandbox_setup` | Installs the project's dependencies into its sandbox cache. This is the only step with network access. | **ask** |

Test commands typed into the shell (`pytest`, `npm test`, `go test`, `cargo test`, `make test`, …) are **denied**, so tests go through the sandbox. The deny list catches the usual forms, not every possible spelling.

**Which sandbox runs** (`--backend auto`):

| Project | Detected by | Backend | How it runs |
|---|---|---|---|
| Rust | `Cargo.toml` | **WASM** | `cargo test --target wasm32-wasip1`, with each test binary executed by **Wasmtime** |
| Go | `go.mod` | **WASM** | `GOOS=wasip1 GOARCH=wasm go test ./...`, executed by **Wasmtime** |
| Python | `pyproject.toml`, `setup.py`, `requirements*.txt`, … | container | a virtualenv plus `python -m pytest` |
| Node | `package.json` | container | `npm`/`pnpm`/`yarn test` (chosen from the lockfile) |

- **Pure-Python projects** can opt into WASM with `backend: wasm`. That runs pytest on a WebAssembly build of CPython. Dependencies with compiled C extensions (for example the Couchbase SDK), sockets, threads and subprocesses aren't available there, and the tool says so if you try.
- **Node.js** test suites can't run in WebAssembly, so they always use the container.

**Isolation, both backends:**

- **Network:** none during tests.
- **Container:** a throwaway container with a read-only root filesystem, running as your user (non-root). All Linux capabilities are dropped, `no-new-privileges` is set, and CPU, memory, process-count and time are capped (defaults: 4 CPUs, 4 GB, 512 processes, 15 minutes).
- **Files:** only the project folder is mounted, at `/work`, plus a per-project dependency cache at `~/.cache/jean-claude-sandbox/`.
- **WASM adds a second boundary:** the tests themselves run inside Wasmtime. It sees only explicitly pre-opened directories and has no sockets.

**Try it by hand:**

```bash
make sandbox-test DIR=~/github-erikhinderer/couchbase-data-generator SETUP=1   # first run: install deps, then test
make sandbox-test DIR=~/github-erikhinderer/couchbase-data-generator           # later runs
./sandbox/jc-sandbox info --dir <repo>          # show what it detected and the exact commands
./sandbox/jc-sandbox test --dir <repo> -- python -m pytest tests/test_x.py -k name
make sandbox-images                              # optional: pre-build the WASM images (otherwise built on first use)
make sandbox-clean                               # delete all cached dependencies
```

Tuning (environment variables): `JC_SBX_TIMEOUT`, `JC_SBX_MEMORY`, `JC_SBX_CPUS`, `JC_SBX_PIDS`, `JC_SBX_MAX_LINES`, `JC_SBX_PYTHON_IMAGE` / `NODE_IMAGE` / `GO_IMAGE` / `RUST_IMAGE`, and `JC_SBX_CACHE`. The full log of the last run is at `/tmp/jc-sandbox-last.log`.

**Integration tests that need a service** (for example a Couchbase cluster) fail offline by design. To allow them, start the service on a dedicated Docker network and run `jc-sandbox test --network <that-network>`. The sandbox can then reach only that network, not the internet.

## Architecture

```
┌──────────────┐   :3000   ┌──────────────┐  :11434  ┌──────────────────────────────┐
│   Browser    │ ────────▶ │  Open WebUI  │ ───────▶ │ Ollama                        │
└──────────────┘           │  (RAG embeds │          │  jean-claude:latest           │
                           │   on CPU)    │          │   └ hf.co/unsloth/…:Q5_K_M    │
                           └──────────────┘          │  Vulkan │ ROCm │ CPU          │
                                                     └──────────────────────────────┘
        model-init (one-shot): pull GGUF → build jean-claude from ollama/Modelfile.tmpl → preload
```

| File | Purpose |
|---|---|
| `docker-compose.yml` | Base stack. Runs CPU-only if used by itself. |
| `compose/gpu-vulkan.yml` | Radeon 890M through Mesa RADV Vulkan. **Default on Linux.** |
| `compose/gpu-rocm.yml` | Radeon 890M through ROCm/HIP (`ollama/ollama:rocm`). |
| `compose/native-ollama.yml` | Uses an Ollama installed on the host (for Windows or macOS). |
| `ollama/Modelfile.tmpl` | The Jean Claude model: sampling settings, context size, tool-call parser, persona. |
| `compose/hub-image.yml` | Uses the published `erikhinderer/jean-claude` image for Ollama. |
| `Dockerfile`, `docker/` | The `erikhinderer/jean-claude` image. |
| `opencode/` | OpenCode config template and Jean Claude's agent rules (`make opencode`). |
| `sandbox/` | `jc-sandbox` test runner and the WASM sandbox images (Wasmtime + Rust/Go/CPython-WASI). |
| `scripts/` | `setup`, `host-tune-linux`, `init-model`, `bench`, `doctor`, `publish-image`, `install-opencode`. |

The backend is chosen by `COMPOSE_FILE` in `.env`. To switch, run `make backend B=vulkan|rocm|cpu|native` and then `make up`.

## How it's tuned for this hardware

### Model and quantization

- **Q5_K_M from Unsloth** (`hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q5_K_M`, 21.7 GB). Ollama's own library only has q4_K_M, q8_0 and fp16 for this model, so the GGUF comes from Hugging Face.
- **`RENDERER qwen3-coder` and `PARSER qwen3-coder`** in the Modelfile. These are the prompt renderer and tool-call parser the official `qwen3-coder` library model uses. Without them, a Hugging Face GGUF falls back to a generic template and native tool calling breaks.
- **Qwen's recommended sampling:** `temperature 0.7`, `top_p 0.8`, `top_k 20`, `repeat_penalty 1.05`.
- **It's a MoE model**: 30.5B total parameters, but only ~3.3B are active per token. Each token reads only ~2.3 GB of weights, which makes it fast on a memory-bandwidth-limited APU. A dense 30B model would be several times slower here.

### Memory budget (64 GB unified)

| Item | Size |
|---|---|
| Q5_K_M weights | 21.7 GB |
| KV cache, 64K context, `q8_0` (~48 KiB/token: 48 layers × 4 KV heads × 128 dim) | ~3.2 GB |
| Compute buffers | ~1–2 GB |
| **Jean Claude total** | **~27 GB** |
| OS + Docker + Open WebUI (incl. embedding model) | ~4–6 GB |

This leaves plenty of room. You can raise `JC_NUM_CTX` to `131072` (~6.4 GB of KV) and still fit comfortably. At 256K the KV cache alone is ~13 GB, and prompt processing on an iGPU gets slow long before you fill it.

Runtime settings (`docker-compose.yml`):

| Setting | Why |
|---|---|
| `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` | Halves KV-cache memory compared with f16, with negligible quality loss. A quantized KV cache requires flash attention. |
| `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1` | This is a single-user box. Each extra parallel slot allocates another full context of KV cache. |
| `OLLAMA_KEEP_ALIVE=-1` + `JC_PRELOAD=1` | Loads the 22 GB model once and keeps it in memory. No reload delay between chats. |
| `OLLAMA_LOAD_TIMEOUT=15m` | The first load from SSD into GTT can be slow. |
| Open WebUI: autocomplete and arena off, embeddings on CPU | Keeps background requests from queueing behind your chat on the one GPU. |

### The iGPU: GTT, not VRAM

The 890M has no VRAM of its own. It gets a small BIOS carve-out ("UMA frame buffer") and can also map ordinary system RAM through **GTT**. By default the Linux kernel caps GTT at roughly half of RAM, which is too small for a 22 GB model plus its KV cache.

`scripts/host-tune-linux.sh` sets `ttm.pages_limit` on the kernel command line (RAM minus 16 GB, which is ~46 GB on this box), adds you to the `render`/`video` groups, and switches to the `performance` power profile. After you reboot, `make doctor` should report GTT at ~46 GB and `ollama ps` should show **100% GPU**.

**If your BIOS already reserves 32 GB** (*UMA Frame Buffer Size* = 32G), the model and its KV cache (~28 GB) fit entirely in that dedicated carve-out, and no kernel tuning is needed. `make setup` and `host-tune-linux.sh` detect this and leave the kernel command line alone. The trade-off is that Linux only sees the remaining ~30 GB, which is still plenty for the OS and Open WebUI.

**BIOS:** with the Vulkan backend, leave *UMA Frame Buffer Size* small or on Auto, because RADV uses GTT. If you use ROCm and Ollama detects only a few GB of GPU memory, raise the UMA frame buffer to the maximum your BIOS offers. Ollama will then split layers between GPU and CPU.

### Choosing a backend

| Backend | When to use it |
|---|---|
| **vulkan** (default) | Mesa RADV on RDNA 3.5 is a proven path for large MoE GGUFs on the HX 370, and it uses GTT memory directly. |
| **rocm** | Ollama's ROCm v7 build lists the HX 370 (`gfx1150`) as supported. It can win on prompt processing. Only if it logs "no compatible GPUs", uncomment `HSA_OVERRIDE_GFX_VERSION` in `compose/gpu-rocm.yml`. |
| **cpu** | 12 Zen 5 cores on LPDDR5X-8000. A 3B-active MoE runs well on CPU alone, and on some kernel/driver combinations the iGPU is slower than CPU. `setup.sh` sets `num_thread` to the physical core count. |
| **native** | The Windows 11 side of the SER9 Pro, or a Mac. Docker Desktop can't pass the AMD iGPU into containers, so Ollama runs on the host (Vulkan on Windows) and Open WebUI stays in Docker. |

Don't pick by assumption. Run `make bench-all` once on the real box. It benchmarks vulkan, rocm and cpu with the same prompt and seed, prints prompt and generation tokens/s plus the GPU/CPU split, and then restores your configured backend.

## Everyday commands

```bash
make up / make down       # start / stop (models and chats persist in Docker volumes)
make chat                 # terminal chat with jean-claude
make model                # rebuild the model after editing ollama/Modelfile.tmpl or JC_* in .env
make update               # newer images + re-pull the GGUF + rebuild
make ps                   # containers + what's loaded where
make doctor               # diagnostics
make clean                # DELETE volumes (model + chats)
```

Use it from other tools. The Ollama API is on `http://127.0.0.1:11434` (localhost only by default; set `OLLAMA_BIND=0.0.0.0` to expose it on your LAN, but note the Ollama API has no authentication):

```bash
curl http://127.0.0.1:11434/api/chat -d '{"model":"jean-claude","messages":[{"role":"user","content":"Write a bash retry loop"}]}'
```

OpenAI-compatible clients (Continue, Aider, Cline, and similar): base URL `http://<host>:11434/v1`, model `jean-claude`.

## Docker Hub image: `erikhinderer/jean-claude`

The Ollama half of the stack is also published as a single image. It is `ollama/ollama` with the Jean Claude Modelfile, tuning and entrypoint baked in (~3.7 GB). The 21.7 GB weights are **not** in the image. On first start the container pulls them into `/root/.ollama` and builds `jean-claude`; after that, starts are instant.

Pull it:

```bash
docker pull erikhinderer/jean-claude:latest
```

Run it on its own (Linux + Radeon via Vulkan; drop `--device` for CPU-only):

```bash
docker run -d --name jean-claude --restart unless-stopped \
  --device /dev/dri --group-add video --group-add render \
  -v jean-claude:/root/.ollama -p 127.0.0.1:11434:11434 \
  erikhinderer/jean-claude:latest
docker logs -f jean-claude      # watch the first-run download
```

Or use it inside this stack in place of stock Ollama + `model-init`. Set this in `.env` (it must come last):

```
COMPOSE_FILE=docker-compose.yml:compose/gpu-vulkan.yml:compose/hub-image.yml
```

Every setting is an environment variable (`JC_NUM_CTX`, `JC_BASE_MODEL`, `OLLAMA_KV_CACHE_TYPE`, …). Set `JC_SKIP_INIT=1` to run it as plain Ollama.

Publishing (maintainer):

```bash
docker login -u erikhinderer   # use a Docker Hub access token as the password
make publish                   # linux/amd64 + linux/arm64 → :latest and :YYYY.MM.DD
```

`make image` builds it locally without pushing. `DOCKERHUB.md` is the text for the Docker Hub repository overview.

## Configuration reference (`.env`)

| Variable | Default | Notes |
|---|---|---|
| `COMPOSE_FILE` | vulkan overlay | Set by `make backend`. |
| `JC_BASE_MODEL` | Unsloth Q5_K_M | Any `hf.co/...:<quant>` or Ollama library tag works. |
| `JC_NUM_CTX` | `65536` | Context window. The model's native maximum is 262144. |
| `JC_NUM_THREAD` | empty / `12` on cpu | CPU threads. |
| `JC_NUM_GPU` | empty | `999` forces every layer onto the GPU. |
| `JC_NUM_BATCH` | empty (512) | Prompt batch size. Compare values with `./scripts/bench.sh --batch "512 1024 2048"`. |
| `JC_PRELOAD` | `1` | Load the model into memory right after it's built. |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Use `f16` for maximum fidelity, `q4_0` for very long contexts. |
| `OLLAMA_TAG` / `OLLAMA_ROCM_TAG` | `latest` / `rocm` | Pin these (for example `0.33.3` / `0.33.3-rocm`) for reproducible builds. |
| `OPEN_WEBUI_TAG` | `main` | Pin to a release tag for stability. |
| `WEBUI_PORT` / `WEBUI_BIND` | `3000` / `0.0.0.0` | |
| `WEBUI_ENABLE_SIGNUP` | `True` | Set to `False` after you create the admin account. |

Open WebUI stores many settings in its own database once you've changed them in the admin UI. After that, the UI setting takes precedence over the environment variable.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ollama ps` shows e.g. `40%/60% CPU/GPU` | GTT is too small. Run `sudo make tune`, reboot, and check `make doctor`. Or lower `JC_NUM_CTX`. |
| Logs say "no compatible GPUs" (rocm) | Kernel ≥ 6.10 is needed for Strix Point; 6.14+ is recommended. Try `HSA_OVERRIDE_GFX_VERSION` in `compose/gpu-rocm.yml`, or use `vulkan`. |
| Vulkan: permission denied on `/dev/dri` | Re-run `make setup`, which re-detects `RENDER_GID`/`VIDEO_GID`. |
| Garbled output or crashes with flash attention on one backend | Set `OLLAMA_FLASH_ATTENTION=0` **and** `OLLAMA_KV_CACHE_TYPE=f16` (a quantized KV cache requires FA), then `make up`. |
| Tool calls come back as plain text | Make sure you're using `jean-claude` (not the raw `hf.co/...` model) so the `qwen3-coder` parser is active. Run `make model` to rebuild it. |
| First reply is slow | That's the initial 22 GB load. With `KEEP_ALIVE=-1` it happens once per Ollama restart. |
| Pull fails partway | Run `make model` again. The download resumes. |
