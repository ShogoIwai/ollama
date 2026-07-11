#!/bin/sh
# Start the Ollama daemon for the 27B dense coder served at its FULL native 256K
# window. The served model is the LOCAL derived model `qwen36-27b-coder-256k`,
# NOT the raw upstream tag SetneufPT/Qwen3.6-27B-CODER-MTP_Q4_105k_24GB-GPU: that
# upstream pins `PARAMETER num_ctx 105000` in its Modelfile, and a Modelfile
# parameter OVERRIDES the OLLAMA_CONTEXT_LENGTH env — so the daemon env alone
# cannot lift the window past 105k. The derived model FROM-inherits the upstream
# (shared weight blobs, mmproj/vision, MTP draft head, sampling params) and only
# overrides num_ctx to 262144 (see qwen36-27b-coder-256k.modelfile).
#
# Fitting 256K in 24GB VRAM requires the q4_0 KV cache — at the shared core's
# default q8_0 KV the load OOMs at 256K (needs a ~9GB reserve on top of ~17GB
# weights). So this launcher pins OLLAMA_KV_CACHE_TYPE=q4_0. Measured on the
# RTX 3090: 256K / 100% GPU / 18GB / ~68 tok/s, structured tool_calls OK.
# q4_0 KV trades a little cache precision for the full window; for q8_0 precision
# instead, run the upstream tag at its 105k window:
#   MODEL=SetneufPT/Qwen3.6-27B-CODER-MTP_Q4_105k_24GB-GPU:latest \
#     OLLAMA_KV_CACHE_TYPE=q8_0 ./start_ollama_qwen36_27b_coder.sh
#
# BUILD ONCE before first launch (not a plain pull — it is a local derived model;
# the shared core's lazy-pull cannot fetch it):
#   ollama pull SetneufPT/Qwen3.6-27B-CODER-MTP_Q4_105k_24GB-GPU:latest   # operator step
#   ollama create qwen36-27b-coder-256k -f qwen36-27b-coder-256k.modelfile
#
# VERIFY after launch: `ollama ps` shows CONTEXT 262144 @ 100% GPU, and
#   curl -s http://127.0.0.1:11434/api/show -d '{"model":"qwen36-27b-coder-256k:latest"}' \
#     | python3 -c 'import sys,json;print(json.load(sys.stdin).get("capabilities"))'
#
# Thin launcher: sets the model tag + KV type and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, foreground). num_ctx is
# baked into the derived model, so OLLAMA_CONTEXT_LENGTH is not needed here.
MODEL="${MODEL:-qwen36-27b-coder-256k:latest}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q4_0}"
export OLLAMA_KV_CACHE_TYPE
. "$(dirname "$0")/_ollama_serve_common.sh"
