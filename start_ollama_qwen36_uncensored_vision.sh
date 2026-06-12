#!/bin/sh
# Start the Ollama daemon for the Qwen3.6-35B-A3B *Uncensored + Vision* variant
# (fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4, uncensored
# derivative of qwen3.6:35b-a3b that — unlike joe-speedboat/...-Text — KEEPS the
# vision tower (projector bundled in the tag, ~899MB mmproj), so it can load
# images / PDF pages. Sparse MoE ~3B active, tools + thinking, ~22GB weights,
# 256K native context.
#
# EVALUATION launcher — NOT yet the documented default. Before adopting:
#   1. confirm vision is actually wired (see verification below — capabilities
#      MUST include `vision`, otherwise PDF still fails and this tag is useless);
#   2. measure 100% GPU split / context / tok/s with `ollama ps`;
#   3. smoke-test a tool call via the Codex profile.
# See README "Adding a new LLM" steps 5-7.
#
# Verify vision after first pull (daemon must be up):
#   ollama pull fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4
#   curl -s http://127.0.0.1:11434/api/show \
#     -d '{"model":"fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4"}' \
#     | python3 -c 'import sys,json;d=json.load(sys.stdin);print("capabilities:",d.get("capabilities"))'
#   # expect: capabilities: ['completion', 'vision', 'tools', 'thinking']
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4}"
. "$(dirname "$0")/_ollama_serve_common.sh"
