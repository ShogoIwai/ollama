#!/bin/sh
# Start the Ollama daemon for gemma4:26b (26B-A4B MoE, q4_K_M, ~18GB; fits a
# 24GB GPU). Override MODEL to try another quant/size, e.g.
#   MODEL=gemma4:31b ./start_ollama_gemma4_26b.sh
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-gemma4:26b}"
. "$(dirname "$0")/_ollama_serve_common.sh"
