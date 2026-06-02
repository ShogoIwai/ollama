# Switch the current shell back to CLOUD mode.  tcsh/csh:  source ollama/source_cloud.csh
#
# Unsets the local Ollama overrides so the clients fall back to their default
# cloud endpoints. A freshly opened shell is already in cloud mode; this file is
# for returning to cloud within the same shell after `source ollama/source_local.csh`.
unsetenv ANTHROPIC_BASE_URL
unsetenv ANTHROPIC_AUTH_TOKEN
unsetenv ANTHROPIC_API_KEY
unsetenv OPENAI_BASE_URL
unsetenv OLLAMA_HOST

# If you authenticate via API key (not subscription OAuth login), re-export it:
# setenv ANTHROPIC_API_KEY "<your-key>"

echo "[ollama] CLOUD mode: local overrides unset"
