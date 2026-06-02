#!/bin/sh
# Start the Ollama daemon for qwen3-coder.
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="qwen3-coder"
. "$(dirname "$0")/_ollama_serve_common.sh"
