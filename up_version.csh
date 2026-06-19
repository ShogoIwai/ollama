#!/usr/bin/csh
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl stop ollama && sudo systemctl disable ollama
ollama --version
