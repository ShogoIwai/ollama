#!/usr/bin/csh
npm instal -g @anthropic-ai/claude-code@latest
npm instal -g @openai/codex@latest

curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl stop ollama && sudo systemctl disable ollama
ollama --version
