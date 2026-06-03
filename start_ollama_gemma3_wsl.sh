#!/bin/sh
# Start the Ollama daemon for gemma3:4b on a WSL / GPU-less, low-memory host
# (CPU inference). Google's Gemma family ran better than Qwen on the Linux
# workstation, and gemma3:4b (Q4_K_M, ~2.9GB resident) fits an 8GB WSL with
# headroom while sustaining ~11-12 tok/s on CPU. Override MODEL for another
# Gemma size/quant, e.g.
#   MODEL=gemma3:1b ./start_ollama_gemma3_wsl.sh   # ~0.8GB, ultra-light
#
# WSL note: unlike the GPU launchers, the context window is capped low here.
# On CPU with limited RAM, a 16K+ context blows the KV cache up to 3-4GB and
# drives the host into swap (sub-1 tok/s). 8192 keeps the KV cache small; drop
# to 4096 if memory is tight. Override before running:
#   OLLAMA_CONTEXT_LENGTH=4096 ./start_ollama_gemma3_wsl.sh
#
# Thin launcher: sets the model tag and the WSL context cap, then delegates to
# the shared core in _ollama_serve_common.sh (daemon start, readiness wait,
# lazy pull, foreground).
MODEL="${MODEL:-gemma3:4b}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
. "$(dirname "$0")/_ollama_serve_common.sh"
