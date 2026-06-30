#!/bin/sh
# Start the Ollama daemon for ornith:35b — a qwen35moe-architecture build
# (Qwen3.6-35B-A3B family, sparse MoE ~3B active), gguf Q4_K_M, ~21GB weights,
# no bundled vision projector (text-only). Smoke-test candidate; measured
# VRAM/context/tok/s to be filled into the README after a real run.
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-ornith:35b}"
. "$(dirname "$0")/_ollama_serve_common.sh"
