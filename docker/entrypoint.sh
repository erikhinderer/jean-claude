#!/bin/sh
# Start Ollama, then (in the background) make sure the jean-claude model exists.
set -eu

ollama serve &
SERVER=$!
trap 'kill -TERM "$SERVER" 2>/dev/null' INT TERM

if [ "${JC_SKIP_INIT:-0}" != "1" ]; then
  # The client side of init talks to the local server regardless of the bind address.
  ( OLLAMA_HOST="http://127.0.0.1:11434" sh /jc/scripts/init-model.sh ) &
fi

wait "$SERVER"
