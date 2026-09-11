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
| `scripts/` | `setup`, `host-tune-linux`, `init-model`, `bench`, `doctor`. |

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

## Configuration reference (`.env`)

| Variable | Default | Notes |
|---|---|---|
| `COMPOSE_FILE` | vulkan overlay | Set by `make backend`. |
| `JC_BASE_MODEL` | Unsloth Q5_K_M | Any `hf.co/...:<quant>` or Ollama library tag works. |
| `JC_NUM_CTX` | `65536` | Context window. The model's native maximum is 262144. |
| `JC_NUM_THREAD` | empty / `12` on cpu | CPU threads. |
| `JC_NUM_GPU` | empty | `999` forces every layer onto the GPU. |
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
