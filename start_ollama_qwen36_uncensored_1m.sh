#!/bin/sh
# Start the Ollama daemon for the Qwen3.6-35B-A3B *Uncensored + 1M-context*
# variant (satgeze/qwen36-35b-uncensored-1m:q4_k_m-no-mtp, an uncensored derivative of
# qwen3.6:35b-a3b advertising a 1M native context window). Sparse MoE ~3B active,
# thinking-capable, vision-capable. Served at the shared core's 256K (262144)
# default. Measured on a 24GB RTX 3090: 100% GPU / 23GB / ~110 tok/s at 128K;
# at 256K it spills ~6% to CPU (25GB) / ~93 tok/s. The "1m" tag name is the
# model's native limit, not what we load. (The tag's Modelfile also pins
# `num_ctx 262144`, so it would serve 256K even without the core default.)
#
# ADOPTED (optional launcher). Capabilities and a structured tool-call were
# verified here (['completion','vision','tools','thinking']); it is the
# recommended full-window/256K model because, being non-MTP, it stays faster than
# the default MTP build at every context. See README "Models and memory
# requirements".
#
# Re-verify capabilities after any re-pull (daemon must be up):
#   curl -s http://127.0.0.1:11434/api/show \
#     -d '{"model":"satgeze/qwen36-35b-uncensored-1m:q4_k_m-no-mtp"}' \
#     | python3 -c 'import sys,json;d=json.load(sys.stdin);print("capabilities:",d.get("capabilities"))'
#   # expect at least: ['completion', 'tools', 'thinking']  (direct-connect needs `tools`)
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-satgeze/qwen36-35b-uncensored-1m:q4_k_m-no-mtp}"
. "$(dirname "$0")/_ollama_serve_common.sh"
