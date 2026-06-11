#!/bin/sh
# Start the Ollama daemon for LiquidAI/lfm2.5-1.2b-instruct on a WSL / GPU-less,
# low-memory host (CPU inference). LFM2.5-1.2B is a hybrid Liquid-architecture
# 1.17B model built for on-device deployment; the *instruct* build (unlike the
# text-only lfm2.5-thinking) is published with tool-use support, which is why it
# is the WSL tool-calling candidate. At Q4_K_M it is ~731MB on disk — far
# lighter than gemma3:4b (~2.9GB) — so it fits an 8GB WSL host with wide
# headroom. Override MODEL for another quant, e.g.
#   MODEL=LiquidAI/lfm2.5-1.2b-instruct:q8_0 ./start_ollama_lfm25_wsl.sh   # ~1.2GB
#
# Tool-calling caveat (see README "WSL / low-memory (CPU)"): the model reporting
# tool use does NOT guarantee Ollama emits a *structured* tool_calls block. If it
# emits the call as plain-text JSON in `content` (as gemma3 does), it is MCP-only
# and cannot drive direct-connect agentic edits. Verify with /api/show
# capabilities + a real tool-call smoke test before adopting for direct connect.
#
# WSL note: the context default here is 32768 (the model's native window), NOT
# the 8192 the gemma3 launcher uses. Two reasons: (1) Claude Code's system prompt
# alone is ~23K tokens, so direct connect simply fails under 8192
# ("exceeds the available context size") — and direct connect is this model's
# whole point; (2) LFM2.5 is a *hybrid* model with only 6 attention layers (of
# 16), so its KV cache is far smaller than a dense model's at the same length and
# fits this 8GB host. If RAM is tight, drop it back down before running:
#   OLLAMA_CONTEXT_LENGTH=8192 ./start_ollama_lfm25_wsl.sh   # MCP-only / small tasks
# 32768 is the model's native ceiling; do not raise past it.
#
# Thin launcher: sets the model tag and the WSL context cap, then delegates to
# the shared core in _ollama_serve_common.sh (daemon start, readiness wait,
# lazy pull, foreground).
MODEL="${MODEL:-LiquidAI/lfm2.5-1.2b-instruct:q4_k_m}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
. "$(dirname "$0")/_ollama_serve_common.sh"
