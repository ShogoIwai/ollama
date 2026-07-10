#!/bin/sh
# Build the local derived model `qwen36-iq3m-256k-fix` from the upstream
# chuangyeyu/Qwen3.6-35B-A3B-IQ3_M:latest tag and verify it can drive tools.
#
# The fix is entirely in qwen36-iq3m-256k-fix.modelfile (native RENDERER/PARSER
# directives) — see that file's header. This script is just `ollama create` plus
# a STRICT tools+system smoke test on the /v1/messages path Claude Code uses.
#
# Prereqs: `ollama pull chuangyeyu/Qwen3.6-35B-A3B-IQ3_M:latest` (operator step);
# a running daemon reachable at 127.0.0.1:11434; python3; curl with
# --fail-with-body (curl >= 7.76).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="qwen36-iq3m-256k-fix"

echo "[1/2] ollama create ${MODEL}"
ollama create "${MODEL}" -f "${DIR}/qwen36-iq3m-256k-fix.modelfile"

echo "[2/2] strict smoke test: /v1/messages with tools + system must return tool_use"
ollama stop "${MODEL}" >/dev/null 2>&1 || true
curl --connect-timeout 10 --max-time 600 --fail-with-body --show-error -s http://127.0.0.1:11434/v1/messages \
  -H 'content-type: application/json' -d '{
  "model":"'"${MODEL}"'","max_tokens":512,
  "system":"You are a helpful assistant. Call the tool directly.",
  "messages":[{"role":"user","content":"What is the weather in Tokyo? Use the get_weather tool."}],
  "tools":[{"name":"get_weather","description":"Get weather for a city","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]}' \
 | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "error" in d:
    sys.exit("FAIL 400: " + json.dumps(d["error"]))
blocks = [b.get("type") for b in d.get("content", [])]
if d.get("stop_reason") != "tool_use" or "tool_use" not in blocks:
    sys.exit("FAIL: expected stop_reason=tool_use with a tool_use block, got "
             + repr(d.get("stop_reason")) + " blocks=" + repr(blocks))
print("    OK stop_reason=tool_use blocks=" + repr(blocks))'
echo "Done. Launch with ./start_ollama_qwen36_iq3m_256k.sh"
