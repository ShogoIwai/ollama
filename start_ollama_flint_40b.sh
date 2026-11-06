#!/bin/sh
# Start the Ollama daemon for flint:40b (Recursive Flint, 39.8B-param sparse MoE,
# ~2.5B active, thinking + tools, text-only, Apache 2.0; built for coding agents).
# Registry build is NVFP4 only: 22.9GB weights, native 262K context, and it
# requires Ollama >= 0.40.9 (run up_version.csh first). Measured on a 24GB RTX
# 3090 (Ollama 0.40.15) at the 256K default: 21GB resident, 6%/94% CPU/GPU split,
# ~88 tok/s generation. Text-only: use ocr_to_md.sh for images/PDFs. To try
# reducing the CPU spill, lower the context (untested; verify with ollama ps), e.g.
#   OLLAMA_CONTEXT_LENGTH=65536 ./start_ollama_flint_40b.sh
#
# Thin launcher: sets the model tag and delegates to the shared core in
# _ollama_serve_common.sh (daemon start, readiness wait, lazy pull, foreground).
MODEL="${MODEL:-flint:40b}"
. "$(dirname "$0")/_ollama_serve_common.sh"
