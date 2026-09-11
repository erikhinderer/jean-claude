# Jean Claude sandbox images for the WebAssembly backend (built on first use by jc-sandbox).
# Each target = a normal toolchain + Wasmtime. Tests are compiled/run *inside* Wasmtime,
# which itself runs in a locked-down container (see jc-sandbox).
#
#   docker build --target rust-wasm   -t jean-claude-sandbox:rust-wasm   sandbox/
#   docker build --target go-wasm     -t jean-claude-sandbox:go-wasm     sandbox/
#   docker build --target python-wasm -t jean-claude-sandbox:python-wasm sandbox/
ARG WASMTIME_VERSION=""

# ── shared: install the Wasmtime CLI into /usr/local/bin ─────────────────────
FROM debian:bookworm-slim AS wasmtime
ARG WASMTIME_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://wasmtime.dev/install.sh -o /tmp/install.sh \
 && bash /tmp/install.sh ${WASMTIME_VERSION:+--version v${WASMTIME_VERSION}} \
 && install -m 0755 /root/.wasmtime/bin/wasmtime /usr/local/bin/wasmtime \
 && wasmtime --version

# ── Rust: cargo test --target wasm32-wasip1, executed by Wasmtime ────────────
FROM rust:1-slim AS rust-wasm
COPY --from=wasmtime /usr/local/bin/wasmtime /usr/local/bin/wasmtime
RUN rustup target add wasm32-wasip1 && chmod -R a+rX /usr/local/rustup /usr/local/cargo

# ── Go: GOOS=wasip1 GOARCH=wasm go test, executed by Wasmtime ─────────────────
FROM golang:1.24 AS go-wasm
COPY --from=wasmtime /usr/local/bin/wasmtime /usr/local/bin/wasmtime
# Go's stock go_wasip1_wasm_exec pre-opens the whole filesystem (--dir=/). This wrapper
# only pre-opens the project and /tmp, so the WASM guest can't see anything else.
RUN printf '%s\n' '#!/bin/sh' \
      'exec wasmtime run --dir /work::/work --dir /tmp::/tmp --env PWD="$PWD" --env HOME=/tmp -W max-wasm-stack=1048576 "$@"' \
      > /usr/local/bin/jc-wasip1-exec && chmod 0755 /usr/local/bin/jc-wasip1-exec

# ── Python: CPython compiled to WASI (pure-Python projects only) ──────────────
FROM debian:bookworm-slim AS python-wasm
ARG PYTHON_WASI_VERSION=3.13
COPY --from=wasmtime /usr/local/bin/wasmtime /usr/local/bin/wasmtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*
COPY fetch-python-wasi.py /usr/local/bin/fetch-python-wasi.py
# Never fails the build: if the WASI CPython can't be fetched or doesn't start,
# /opt/python-wasi/UNAVAILABLE explains why and jc-sandbox falls back to a container.
RUN python3 /usr/local/bin/fetch-python-wasi.py "$PYTHON_WASI_VERSION" /opt/python-wasi
