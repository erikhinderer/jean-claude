# Jean Claude — Ollama with the Jean Claude model definition and tuning baked in.
# The 21.7 GB Q5_K_M weights are NOT in the image: on first start the container
# pulls them into /root/.ollama (mount a volume there) and builds `jean-claude`.
#
#   docker build -t erikhinderer/jean-claude .
#   docker run -d --name jean-claude --device /dev/dri \
#     -v jean-claude:/root/.ollama -p 11434:11434 erikhinderer/jean-claude
ARG OLLAMA_TAG=latest
FROM ollama/ollama:${OLLAMA_TAG}

ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="Jean Claude" \
      org.opencontainers.image.description="Local coding assistant: Qwen3-Coder-30B-A3B (Q5_K_M) on Ollama, tuned for AMD Ryzen AI (Radeon 890M, Vulkan)" \
      org.opencontainers.image.source="https://github.com/erikhinderer/jean-claude" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0"

# Runtime tuning (see README "How it's tuned for this hardware"); all overridable with -e.
ENV OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_KEEP_ALIVE=-1 \
    OLLAMA_MAX_LOADED_MODELS=1 \
    OLLAMA_NUM_PARALLEL=1 \
    OLLAMA_FLASH_ATTENTION=1 \
    OLLAMA_KV_CACHE_TYPE=q8_0 \
    OLLAMA_CONTEXT_LENGTH=65536 \
    OLLAMA_LOAD_TIMEOUT=15m \
    OLLAMA_VULKAN=1 \
    JC_BASE_MODEL=hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q5_K_M \
    JC_MODEL_NAME=jean-claude \
    JC_NUM_CTX=65536 \
    JC_NUM_THREAD= \
    JC_NUM_GPU= \
    JC_UPDATE_BASE=0 \
    JC_PRELOAD=1 \
    JC_SKIP_INIT=0

COPY --chmod=0755 docker/entrypoint.sh /jc/entrypoint.sh
COPY --chmod=0755 scripts/init-model.sh /jc/scripts/init-model.sh
COPY ollama/Modelfile.tmpl /jc/ollama/Modelfile.tmpl

VOLUME ["/root/.ollama"]
EXPOSE 11434
# Healthy = API is serving. The model may still be downloading; see `docker logs`.
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=20 CMD ["ollama", "list"]

ENTRYPOINT ["/bin/sh", "/jc/entrypoint.sh"]
