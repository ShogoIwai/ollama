# Switch the current shell to LOCAL (Ollama) mode.  tcsh/csh:  source ollama/source_local.csh
#
# Points the Anthropic-compatible clients (Claude Code) and the OpenAI-compatible
# clients (Goose) at the local Ollama endpoint on :11434. Return to cloud with
# `source ollama/source_cloud.csh`.
setenv OLLAMA_HOST "http://localhost:11434"

# --- Claude Code (Anthropic-compatible /v1/messages, Ollama v0.14.0+) ---
setenv ANTHROPIC_BASE_URL "http://localhost:11434"
setenv ANTHROPIC_AUTH_TOKEN "ollama"
setenv ANTHROPIC_API_KEY ""

# --- Goose (OpenAI-compatible /v1) ---
setenv OPENAI_BASE_URL "http://localhost:11434/v1"
setenv GOOSE_DISABLE_KEYRING 1
setenv GOOSE_TOOLSHIM 1

echo "[ollama] LOCAL mode: Anthropic/OpenAI clients -> http://localhost:11434 (model: qwen3-coder)"
