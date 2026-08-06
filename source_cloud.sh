# Switch the current shell back to CLOUD mode.  bash/sh:  source ollama/source_cloud.sh
#
# Unsets the local Ollama overrides so the clients fall back to their default
# cloud endpoints. A freshly opened shell is already in cloud mode; this file is
# for returning to cloud within the same shell after `source ollama/source_local.sh`.
# Only ANTHROPIC_* / OLLAMA_HOST are touched here; source_local.sh never set any
# OPENAI_* var, so there is nothing OpenAI-side to unset (Codex stays clean).
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY OLLAMA_HOST
unset DISABLE_COMPACT CLAUDE_CODE_MAX_CONTEXT_TOKENS   # local-mode context-window overrides (see source_local.sh)
# local-mode model-alias pins (see source_local.sh): leaving these set would make
# cloud mode resolve sonnet/opus/haiku to a local Ollama tag the cloud does not have.
unset ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL
unset ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL
unset LOCALLLM_MODEL LOCALLLM_CODEX_PROFILE
unset _LOCALLLM_SOURCED   # sentinel cleared: no longer in LOCAL mode (see source_local.sh)

# Drop the local-mode aliases so `claude` / `codex` revert to their cloud defaults.
unalias claude 2>/dev/null
unalias codex  2>/dev/null

# If you authenticate via API key (not subscription OAuth login), re-export it:
# export ANTHROPIC_API_KEY="<your-key>"

echo "[ollama] CLOUD mode: local overrides unset"
