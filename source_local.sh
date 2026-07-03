# Switch the current shell to LOCAL (Ollama) mode.  bash/sh:  source ollama/source_local.sh
#
# Points Claude Code (Anthropic-compatible /v1/messages) at the local Ollama
# endpoint on :11434. Return to cloud with `source ollama/source_cloud.sh`.
#
# NOTE: This file only touches ANTHROPIC_* (Claude Code). It deliberately does
# NOT export any OPENAI_* var: Codex's cloud OpenAI client reads those too, so
# exporting them here would silently redirect Codex to the local server.

# --- Auto-reset stale LOCAL state so re-sourcing tracks a freshly-started model ---
# Switching models used to need `source_cloud.sh` then `source_local.sh`: the previous
# source_local.sh left LOCALLLM_MODEL set, and that leftover beats the ~/.ollama_active_model
# marker, so re-sourcing kept the old model. We mark LOCAL mode with the sentinel
# _LOCALLLM_SOURCED; if it is already set we are re-sourcing over a prior LOCAL
# session, so call source_cloud.sh first to clear LOCALLLM_MODEL/aliases and let the
# marker win. (An explicit `export LOCALLLM_MODEL=...` from a cloud shell carries no
# sentinel, so it is NOT reset and still wins — the documented override is preserved.)
if [ -n "${_LOCALLLM_SOURCED:-}" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/source_cloud.sh" >/dev/null
fi

export OLLAMA_HOST="http://localhost:11434"

# --- Claude Code (Anthropic-compatible /v1/messages, Ollama v0.14.0+) ---
export ANTHROPIC_BASE_URL="http://localhost:11434"
export ANTHROPIC_AUTH_TOKEN="ollama"
export ANTHROPIC_API_KEY=""

# --- Context window: align Claude Code with the local model's real limit ---
# Claude Code resolves the context window from a built-in per-model table keyed
# on the model name. The Ollama tags (qwen3.6:*) are unknown to it,
# so it falls back to 200000 and auto-compact never fires before Ollama's 128K
# window (OLLAMA_CONTEXT_LENGTH) silently truncates the oldest tokens. The
# only override env (CLAUDE_CODE_MAX_CONTEXT_TOKENS) is honored ONLY when
# DISABLE_COMPACT is set (see bundle fn v87). So we trade auto-compact for an
# honest /context gauge + "approaching limit" warning at the real 128K, and drive
# /compact or /clear manually. source_cloud.sh unsets both. Override
# CLAUDE_CODE_MAX_CONTEXT_TOKENS before sourcing if you raise the Ollama window.
export DISABLE_COMPACT=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-128000}"

# --- Model / profile selection (override before sourcing to switch model) ---
# LOCALLLM_MODEL         picks the Ollama tag the `claude` alias pins (e.g.
#                        qwen3.6:35b-a3b-mtp-q4_K_M).
# LOCALLLM_CODEX_PROFILE picks the Codex profile the `codex` alias selects
#                        (overlay file ~/.codex/<profile>.config.toml that sets
#                        the model). Default: ollama-local.
# Example:  export LOCALLLM_MODEL=qwen3.6:35b  before  source ollama/source_local.sh
#
# Auto-detection: the start scripts (_ollama_serve_common.sh) record the launched
# model tag in ~/.ollama_active_model. If LOCALLLM_MODEL is not already set, we
# read that marker so sourcing this file tracks whichever model you started. An
# explicit `export LOCALLLM_MODEL ...` before sourcing always wins.
if [ -z "${LOCALLLM_MODEL:-}" ]; then
    if [ -r "${HOME}/.ollama_active_model" ]; then
        LOCALLLM_MODEL="$(cat "${HOME}/.ollama_active_model")"
    else
        LOCALLLM_MODEL="qwen3.6:35b-a3b-mtp-q4_K_M"
    fi
fi

# Derive the Codex profile (overlay file ~/.codex/<profile>.config.toml) from the
# model unless explicitly set. Add a case + overlay file per new local model.
if [ -z "${LOCALLLM_CODEX_PROFILE:-}" ]; then
    case "${LOCALLLM_MODEL}" in
        fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:*) LOCALLLM_CODEX_PROFILE="ollama-qwen36-uncensored-vision" ;;
        qwen3.6:*)            LOCALLLM_CODEX_PROFILE="ollama-qwen36-35b" ;;
        ornith:*)            LOCALLLM_CODEX_PROFILE="ollama-ornith-35b" ;;
        *)                    LOCALLLM_CODEX_PROFILE="ollama-local" ;;
    esac
fi
export LOCALLLM_MODEL LOCALLLM_CODEX_PROFILE
export _LOCALLLM_SOURCED=1   # sentinel: in LOCAL mode (see auto-reset block above)

# --- Local-mode aliases (cleared by source_cloud.sh) ---
# claude: env already points at Ollama; alias just pins the model name.
# codex : no shared env (OPENAI_* intentionally unset), so the profile flag is
#         what actually selects local. Disable the OAuth Notion MCP only for this
#         local alias; plain `codex` stays cloud and keeps the global MCP config.
alias claude="claude --model ${LOCALLLM_MODEL}"
alias codex="codex --profile ${LOCALLLM_CODEX_PROFILE} -c mcp_servers.notion.enabled=false"

echo "[ollama] LOCAL mode: claude/codex aliased to local (model: ${LOCALLLM_MODEL}, codex profile: ${LOCALLLM_CODEX_PROFILE})"
