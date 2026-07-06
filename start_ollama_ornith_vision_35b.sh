#!/bin/sh
# Start the Ollama daemon for robit/ornith-vision:35b — the VISION-capable build
# of DeepReinforce's Ornith-1.0-35B agentic-coding model. Same qwen35moe arch
# (Qwen-3.5-series sparse MoE ~3B active), Q4_K_M, ~23GB weights, but unlike the
# text-only ornith:35b this tag BUNDLES a vision projector, so it can consume
# images / PDF pages directly (no ocr_to_md.sh preprocessing step needed).
#
# Measured on this host (RTX 3090 24GB) at the shared 128K context default:
#   /api/show capabilities ['completion','vision','tools','thinking']
#   100% GPU, 23 GB resident, ~114 tok/s gen (prompt ~403 tok/s)
#   vision OCR verified correct; tool-calls return a structured tool_calls block.
#
# CAUTION: this tag's NATIVE context is 262144 (256K). If loaded at full 256K it
# spills to ~92% GPU / 8% CPU on a 24 GB GPU and VISION inference then fails with
# "unexpected EOF". The shared core caps OLLAMA_CONTEXT_LENGTH at 128K, which
# keeps it 100% GPU and working — do NOT raise the context past ~128K here.
#
# Verify vision after first pull (daemon must be up):
#   ollama pull robit/ornith-vision:35b
#   curl -s http://127.0.0.1:11434/api/show \
#     -d '{"model":"robit/ornith-vision:35b"}' \
#     | python3 -c 'import sys,json;d=json.load(sys.stdin);print("capabilities:",d.get("capabilities"))'
#   # expect: capabilities: ['completion', 'vision', 'tools', 'thinking']
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-robit/ornith-vision:35b}"
. "$(dirname "$0")/_ollama_serve_common.sh"
