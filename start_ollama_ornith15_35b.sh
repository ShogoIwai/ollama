#!/bin/sh
# Start the Ollama daemon for ornith-1.5:35b (Ornith-1.5-35B-A3B, sparse MoE,
# ~3B active, vision + thinking + tools, arch qwen35moe -- same family as the
# qwen3.6 default, native 256K, so it shares the core's context default).
# Registry build is Q4_K_M: 22GB weights + 903MB BF16 clip projector.
# Measured on a 24GB RTX 3090 at the 256K default: 26GB resident, 11%/89%
# CPU/GPU split, ~97 tok/s generation -- about 2x the qwen3.6 MTP default at the
# same context. To eliminate the 11% CPU spill entirely, lower the context, e.g.
#   OLLAMA_CONTEXT_LENGTH=65536 ./start_ollama_ornith15_35b.sh
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-ornith-1.5:35b}"
. "$(dirname "$0")/_ollama_serve_common.sh"
