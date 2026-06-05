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
# 12b is small enough (~9 GB on-GPU) that its full native 262144 (256K) context
# fits in 24 GB at 100% GPU with q8_0 KV cache (~11 GB total, ~60 tok/s; measured).
# So this launcher raises the shared 64000 default to the native limit. The larger
# 26b / qwen35b builds do NOT have this headroom — leave them at the 64000 default.
# Override here if you want a smaller window: OLLAMA_CONTEXT_LENGTH=64000 ./start_ollama_gemma4_12b.sh
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-262144}"
. "$(dirname "$0")/_ollama_serve_common.sh"
