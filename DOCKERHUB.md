# Jean Claude

A local coding assistant: **Qwen3-Coder-30B-A3B-Instruct (Q5_K_M)** on **Ollama**, tuned for AMD Ryzen AI mini PCs (Ryzen AI 9 HX 370 / Radeon 890M, 64 GB), with GPU acceleration through Vulkan.

This image is `ollama/ollama` plus the Jean Claude model definition, runtime tuning and an entrypoint. The 21.7 GB model weights download on first start into the `/root/.ollama` volume, and the container then builds the `jean-claude` model.

## Run

```bash
docker run -d --name jean-claude --restart unless-stopped \
  --device /dev/dri --group-add video --group-add render \
  -v jean-claude:/root/.ollama -p 127.0.0.1:11434:11434 \
  erikhinderer/jean-claude:latest

docker logs -f jean-claude          # first run: ~22 GB download
docker exec -it jean-claude ollama run jean-claude
```

- Without `--device /dev/dri` it runs on the CPU. The model is a mixture-of-experts with ~3B parameters active per token, so it is still usable on a CPU alone.
- The API is Ollama's native API on port 11434, plus an OpenAI-compatible endpoint at `/v1`. Use the model name `jean-claude`.
- For a chat UI, use the full stack with Open WebUI: https://github.com/erikhinderer/jean-claude

## What's tuned

| | |
|---|---|
| Model | `hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q5_K_M` with the `qwen3-coder` renderer and tool-call parser |
| Sampling | temperature 0.7, top_p 0.8, top_k 20, repeat_penalty 1.05 |
| Context | 65,536 tokens, `q8_0` KV cache with flash attention (~3.2 GB) |
| Memory | ~28 GB total, so it needs a 32 GB BIOS UMA carve-out or a GTT limit raised on the host |
| Runtime | keep-alive forever, 1 model, 1 parallel slot, 15-minute load timeout |

## Environment variables

| Variable | Default | |
|---|---|---|
| `JC_NUM_CTX` | `65536` | Context window. The model's native maximum is 262144. |
| `JC_BASE_MODEL` | Unsloth Q5_K_M | Any `hf.co/…:<quant>` or Ollama library tag. |
| `JC_NUM_THREAD` | *(auto)* | Set to the physical core count for CPU-only use. |
| `JC_NUM_GPU` | *(auto)* | `999` forces every layer onto the GPU. |
| `JC_NUM_BATCH` | *(512)* | Prompt batch size; 1024–2048 can speed up prompt processing on iGPUs. |
| `JC_PRELOAD` | `1` | Load the model into memory right after it's built. |
| `JC_UPDATE_BASE` | `0` | `1` re-pulls the weights on start. |
| `JC_SKIP_INIT` | `0` | `1` runs the image as plain Ollama. |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | `f16` or `q4_0`. |
| `OLLAMA_VULKAN` | `1` | Set to `0` to disable the Vulkan GPU backend. |
| `OLLAMA_IGPU_ENABLE` | `1` | Required for integrated Radeon GPUs; Ollama skips them otherwise. |

## Tags

- `latest`: the newest build, on `ollama/ollama:latest`
- `YYYY.MM.DD`: a dated build

Platforms: `linux/amd64`, `linux/arm64`.
