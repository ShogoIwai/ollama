#!/bin/sh
# Start the Ollama daemon for the Qwen3.6-35B-A3B IQ3_M build served at the shared
# core's 256K (262144) default. The served model is the LOCAL derived model
# `qwen36-iq3m-256k-fix`, NOT the raw upstream tag: the upstream
# chuangyeyu/Qwen3.6-35B-A3B-IQ3_M:latest ships no renderer/parser in its Ollama
# config, so Ollama auto-generates a tool parser from the GGUF-embedded Jinja
# chat template and fails (400 "Unable to generate parser for this template ...
# System message must be at the beginning.") on every tools+system request, so
# Claude Code / Codex cannot drive it. The fix keeps the IQ3_M weights + vision
# projector and sets renderer/parser=qwen3.5 via native Modelfile directives
# (built-in parser, like the official qwen3.6). Sparse MoE ~3B active (34.7B
# total), thinking + vision, native 256K, IQ3_M weights ~16GB.
#
# BUILD ONCE before first launch (not a plain pull — it is a local derived model):
#   ollama pull chuangyeyu/Qwen3.6-35B-A3B-IQ3_M:latest   # operator step
#   ./build_qwen36_iq3m_fix.sh                            # ollama create + strict tools+system smoke test
#
# ADOPTED (optional launcher). Capabilities + a structured tool-call with a
# leading system message were verified on the fixed model
# (['tools','thinking','completion','vision']); measured 256K / 100% GPU / 19GB /
# ~101 tok/s on the RTX 3090 — the only 35B-A3B build that keeps the full 256K
# window entirely on the GPU. See README "Models and memory requirements".
#
# Re-verify capabilities after any rebuild (daemon must be up):
#   curl -s http://127.0.0.1:11434/api/show \
#     -d '{"model":"qwen36-iq3m-256k-fix:latest"}' \
#     | python3 -c 'import sys,json;d=json.load(sys.stdin);print("capabilities:",d.get("capabilities"))'
#   # expect: ['tools','thinking','completion','vision']  (direct-connect needs `tools`)
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, foreground). NOTE: the
# core's lazy-pull cannot fetch this local-only model — run the BUILD step above.
MODEL="${MODEL:-qwen36-iq3m-256k-fix:latest}"
. "$(dirname "$0")/_ollama_serve_common.sh"
