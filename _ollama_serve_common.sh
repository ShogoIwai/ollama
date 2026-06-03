# Shared core for the per-model Ollama start scripts. NOT executable on its own.
#
# A launcher (e.g. start_ollama_qwen3_coder.sh) sets MODEL and then sources this
# file. Everything except the model tag is identical across launchers, so it
# lives here once: tuning env, already-running detection, daemon startup, the
# readiness wait, the lazy pull, and keeping the daemon in the foreground.
#
# Required variable (set by the launcher before sourcing):
#   MODEL   the Ollama tag to ensure is pulled (e.g. qwen3-coder, gemma4:26b)
set -eu

: "${MODEL:?MODEL must be set before sourcing _ollama_serve_common.sh}"

# Record the launched model so client shells (source_local.csh) can auto-select
# the matching client model/profile without manual edits. Written as soon as
# MODEL is known, so it applies on every path (including the already-running
# early-exit below).
printf '%s\n' "${MODEL}" > "${HOME}/.ollama_active_model" 2>/dev/null || true

# OpenAI-compatible (/v1) and Anthropic-compatible (/v1/messages, v0.14.0+)
# endpoints are both served on this single host:port.
export OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

# Agent use needs a large context. Ollama auto-limits to 4K when VRAM < 24GB,
# so override explicitly (minimum 64K recommended for coding agents).
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-64000}"

# Hot standby: keep the model resident so back-to-back agent calls don't pay the
# reload latency. Default 2h; set -1 to never unload, or a short value to free
# VRAM sooner. Applies only to the daemon launched below.
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-2h}"

# KV-cache quantization shrinks long-context VRAM at a small quality cost. It
# only takes effect when flash attention is on, so enable both together. Leave
# OLLAMA_KV_CACHE_TYPE at f16 (default, lossless) to disable; set q8_0 / q4_0 to
# quantize.
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-f16}"

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
# `ollama list` prints the tag with its ":latest" / ":26b" suffix, so match the
# full MODEL string.
if ! ollama list 2>/dev/null | grep -q "^${MODEL}"; then
  echo "${MODEL} not found locally; pulling..." >&2
  ollama pull "${MODEL}"
fi

echo "Ollama ready at ${OLLAMA_HOST} serving ${MODEL} (context=${OLLAMA_CONTEXT_LENGTH}). Ctrl-C to stop." >&2

# Keep the daemon in the foreground so this script owns its lifecycle.
trap - EXIT
wait "$SERVE_PID"
