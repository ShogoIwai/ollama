#!/bin/sh
# Start the Ollama daemon for qwen3.6:35b-a3b (Qwen3.6-35B-A3B, sparse MoE,
# ~3B active, thinking-capable, Apache 2.0). Default tag is the MTP q4_K_M build
# (22GB resident). Measured on a 24GB RTX 3090: loads 100% GPU @ 64K context,
# ~144 tok/s generation, because the wrapper's q8_0 KV cache (+ flash attention)
# keeps the full context in VRAM alongside the weights. Override MODEL for the
# non-MTP build, e.g.
#   MODEL=qwen3.6:35b ./start_ollama_qwen36_35b.sh
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-qwen3.6:35b-a3b-mtp-q4_K_M}"
. "$(dirname "$0")/_ollama_serve_common.sh"
