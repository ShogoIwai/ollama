# Switch the current shell to LOCAL (Ollama) mode.  tcsh/csh:  source ollama/source_local.csh
#
# Points Claude Code (Anthropic-compatible /v1/messages) at the local Ollama
# endpoint on :11434. Return to cloud with `source ollama/source_cloud.csh`.
#
# NOTE: This file only touches ANTHROPIC_* (Claude Code). It deliberately does
# NOT setenv any OPENAI_* var: Codex's cloud OpenAI client reads those too, so
# setting them here would silently redirect Codex to the local server. Goose
# is local-only and gets its endpoint entirely from ~/.config/goose/config.yaml,
# so it needs no shell env and never conflicts with Codex.
setenv OLLAMA_HOST "http://localhost:11434"

# --- Claude Code (Anthropic-compatible /v1/messages, Ollama v0.14.0+) ---
setenv ANTHROPIC_BASE_URL "http://localhost:11434"
setenv ANTHROPIC_AUTH_TOKEN "ollama"
setenv ANTHROPIC_API_KEY ""

# --- Model / profile selection (override before sourcing to switch model) ---
# LOCALLLM_MODEL         picks the Ollama tag the `claude` alias pins (e.g.
#                        qwen3-coder, gemma4:26b).
# LOCALLLM_CODEX_PROFILE picks the Codex profile the `codex` alias selects
#                        (overlay file ~/.codex/<profile>.config.toml that sets
#                        the model). Default: ollama-local.
# Example:  setenv LOCALLLM_MODEL gemma4:26b  before  source ollama/source_local.csh
#
# Auto-detection: the start scripts (_ollama_serve_common.sh) record the launched
# model tag in ~/.ollama_active_model. If LOCALLLM_MODEL is not already set, we
# read that marker so sourcing this file tracks whichever model you started. An
# explicit `setenv LOCALLLM_MODEL ...` before sourcing always wins.
if (! $?LOCALLLM_MODEL) then
    if (-r "$HOME/.ollama_active_model") then
        setenv LOCALLLM_MODEL "`cat $HOME/.ollama_active_model`"
    else
        setenv LOCALLLM_MODEL "qwen3-coder"
    endif
endif

# Derive the Codex profile (overlay file ~/.codex/<profile>.config.toml) from the
# model unless explicitly set. Add a case + overlay file per new local model.
if (! $?LOCALLLM_CODEX_PROFILE) then
    switch ("$LOCALLLM_MODEL")
        case gemma4*:
            setenv LOCALLLM_CODEX_PROFILE "ollama-gemma"
            breaksw
        default:
            setenv LOCALLLM_CODEX_PROFILE "ollama-local"
            breaksw
    endsw
endif

# --- Local-mode aliases (cleared by source_cloud.csh) ---
# claude: env already points at Ollama; alias just pins the model name.
# codex : no shared env (OPENAI_* intentionally unset), so the profile flag is
#         what actually selects local. Plain `codex` (no alias) stays cloud.
alias claude "claude --model $LOCALLLM_MODEL"
alias codex "codex --profile $LOCALLLM_CODEX_PROFILE"

echo "[ollama] LOCAL mode: claude/codex aliased to local (model: $LOCALLLM_MODEL, codex profile: $LOCALLLM_CODEX_PROFILE)"
