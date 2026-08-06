# Switch the current shell back to CLOUD mode.  tcsh/csh:  source ollama/source_cloud.csh
#
# Unsets the local Ollama overrides so the clients fall back to their default
# cloud endpoints. A freshly opened shell is already in cloud mode; this file is
# for returning to cloud within the same shell after `source ollama/source_local.csh`.
# Only ANTHROPIC_* / OLLAMA_HOST are touched here; source_local never set any
# OPENAI_* var, so there is nothing OpenAI-side to unset (Codex stays clean).
unsetenv ANTHROPIC_BASE_URL
unsetenv ANTHROPIC_AUTH_TOKEN
unsetenv ANTHROPIC_API_KEY
unsetenv OLLAMA_HOST
if ($?DISABLE_COMPACT) unsetenv DISABLE_COMPACT                          # local-mode context-window
if ($?CLAUDE_CODE_MAX_CONTEXT_TOKENS) unsetenv CLAUDE_CODE_MAX_CONTEXT_TOKENS  # overrides (see source_local)
# local-mode model-alias pins (see source_local.csh): leaving these set would make
# cloud mode resolve sonnet/opus/haiku to a local Ollama tag the cloud does not have.
if ($?ANTHROPIC_DEFAULT_SONNET_MODEL) unsetenv ANTHROPIC_DEFAULT_SONNET_MODEL
if ($?ANTHROPIC_DEFAULT_OPUS_MODEL) unsetenv ANTHROPIC_DEFAULT_OPUS_MODEL
if ($?ANTHROPIC_DEFAULT_HAIKU_MODEL) unsetenv ANTHROPIC_DEFAULT_HAIKU_MODEL
if ($?ANTHROPIC_SMALL_FAST_MODEL) unsetenv ANTHROPIC_SMALL_FAST_MODEL
if ($?LOCALLLM_MODEL) unsetenv LOCALLLM_MODEL
if ($?LOCALLLM_CODEX_PROFILE) unsetenv LOCALLLM_CODEX_PROFILE
if ($?_LOCALLLM_SOURCED) unsetenv _LOCALLLM_SOURCED   # sentinel cleared: no longer in LOCAL mode
# Drop the local-mode aliases so `claude` / `codex` revert to their cloud defaults.
unalias claude
unalias codex

# If you authenticate via API key (not subscription OAuth login), re-export it:
# setenv ANTHROPIC_API_KEY "<your-key>"

echo "[ollama] CLOUD mode: local overrides unset"
