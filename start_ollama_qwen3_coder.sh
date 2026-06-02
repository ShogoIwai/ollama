#!/bin/sh
# Start the Ollama daemon for qwen3-coder.
#
# Replaces the vLLM start script. Ollama loads the model lazily on first
# request, so this script only needs to export tuning env vars and run the
# daemon. On first run, pull the model:  ollama pull qwen3-coder
set -eu

# OpenAI-compatible (/v1) and Anthropic-compatible (/v1/messages, v0.14.0+)
# endpoints are both served on this single host:port.
export OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

# Agent use needs a large context. Ollama auto-limits to 4K when VRAM < 24GB,
# so override explicitly (minimum 64K recommended for coding agents).
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-64000}"

# If a daemon is already serving on this host (e.g. systemd unit), there is
# nothing to start. `ollama serve` would otherwise fail with
# "bind: address already in use". Just report and exit successfully.
if curl -fsS --max-time 3 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
  echo "Ollama already running at ${OLLAMA_HOST}; nothing to start." >&2
  echo "(Note: OLLAMA_CONTEXT_LENGTH from this script does NOT apply to an" >&2
  echo " already-running daemon. Set it where that daemon is launched.)" >&2
  exit 0
fi

# Start the daemon in the background first: `ollama list` / `ollama pull` all
# talk to the HTTP API, so they only work once the server is up.
ollama serve &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null' INT TERM EXIT

# Wait for the API to become reachable (up to ~30s).
i=0
while ! curl -fsS --max-time 2 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "ollama serve did not become ready in time" >&2
    exit 1
  fi
  sleep 1
done

# Pull the model if it is not present yet (no-op if already downloaded).
if ! ollama list 2>/dev/null | grep -q '^qwen3-coder'; then
  echo "qwen3-coder not found locally; pulling..." >&2
  ollama pull qwen3-coder
fi

echo "Ollama ready at ${OLLAMA_HOST} (context=${OLLAMA_CONTEXT_LENGTH}). Ctrl-C to stop." >&2

# Keep the daemon in the foreground so this script owns its lifecycle.
trap - EXIT
wait "$SERVE_PID"
