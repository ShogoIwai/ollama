#!/usr/bin/sh
curl -fsSL https://ollama.com/install.sh | sh
ollama --version
sudo systemctl stop ollama && sudo systemctl disable ollama

