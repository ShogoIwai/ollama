#!/usr/bin/csh
npm instal -g @openai/codex@latest
npm instal -g @openai/codex@latest

curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl stop ollama && sudo systemctl disable ollama
ollama --version
