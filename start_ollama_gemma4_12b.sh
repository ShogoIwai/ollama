#!/bin/sh
# Start the Ollama daemon for gemma4:12b (12B dense, q4_K_M, ~7-8GB; fits a
# 24GB GPU fully on-GPU with large KV cache headroom). A lighter, faster
# alternative to gemma4:26b for the same Gemma family. Override MODEL to try
# another quant, e.g.
#   MODEL=gemma4:12b-it-q8_0 ./start_ollama_gemma4_12b.sh
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-gemma4:12b}"
. "$(dirname "$0")/_ollama_serve_common.sh"
