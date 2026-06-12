#!/bin/sh
# Start the Ollama daemon for the Qwen3.6-35B-A3B *Uncensored-Text* variant
# (joe-speedboat/Qwen3.6-35B-A3B-Uncensored-Text:Q4_K_M, abliterated text-only
# derivative of the Apache-2.0 qwen3.6:35b-a3b; sparse MoE, ~3B active,
# tools + thinking, ~21GB weights, 256K native context). Text-only: unlike the
# official default it carries no vision tower. EVALUATION launcher — measure
# 100% GPU split / context / tok/s with `ollama ps` before adopting (see README
# "Adding a new LLM" steps 5-7); it is NOT yet the documented default.
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-joe-speedboat/Qwen3.6-35B-A3B-Uncensored-Text:Q4_K_M}"
. "$(dirname "$0")/_ollama_serve_common.sh"
