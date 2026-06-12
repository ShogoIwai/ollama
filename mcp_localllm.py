#!/usr/bin/env python3
"""MCP server: exposes a local Ollama model (:11434) as Claude Code / Codex tools.

Model-agnostic. The server auto-detects whichever model is currently loaded in
Ollama and adapts its behavior to that model's capabilities:

- The active model is resolved per call from `/api/ps` (loaded model), falling
  back to `/api/tags` (first installed), or the `LOCALLLM_MODEL_ID` override.
- Capabilities are read from `/api/show`. If the model reports `thinking`
  (e.g. qwen3.6:35b-a3b), the request sets `think: false` so the answer lands in
  `content` instead of being consumed by chain-of-thought reasoning under the
  output-token budget. Non-thinking models are called plainly.

Calls go to Ollama's native `/api/chat` endpoint (so the `think` flag is
available); only the Python standard library is used, no third-party SDK.
"""

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

from mcp.server.fastmcp import FastMCP

# Native Ollama host (NOT the OpenAI-compatible /v1 base). Accept either
# OLLAMA_HOST or a legacy OLLAMA_BASE_URL ending in /v1 and normalize.
_raw_host = os.environ.get("OLLAMA_HOST") or os.environ.get("OLLAMA_BASE_URL") or "http://localhost:11434"
OLLAMA_HOST = _raw_host.rstrip("/")
if OLLAMA_HOST.endswith("/v1"):
    OLLAMA_HOST = OLLAMA_HOST[: -len("/v1")]

# Optional pin. When unset the active model is auto-detected per call. Falls
# back to the legacy QWEN_MODEL_ID name for backward compatibility.
MODEL_OVERRIDE = os.environ.get("LOCALLLM_MODEL_ID") or os.environ.get("QWEN_MODEL_ID")
FALLBACK_MODEL = "qwen3.6:35b-a3b-mtp-q4_K_M"

MAX_TOKENS = int(os.environ.get("LOCALLLM_MAX_TOKENS", "2048"))
TEMPERATURE = float(os.environ.get("LOCALLLM_TEMPERATURE", "0.2"))
# top_p / top_k are forwarded only when set, so non-Gemma models keep Ollama's
# defaults while Gemma can opt into its recommended sampling
# (e.g. LOCALLLM_TOP_P=0.95 LOCALLLM_TOP_K=64).
_TOP_P_RAW = os.environ.get("LOCALLLM_TOP_P")
_TOP_K_RAW = os.environ.get("LOCALLLM_TOP_K")
TOP_P = float(_TOP_P_RAW) if _TOP_P_RAW else None
TOP_K = int(_TOP_K_RAW) if _TOP_K_RAW else None

# Lightweight token-usage instrumentation. Append one JSON object per call.
USAGE_LOG = (
    os.environ.get("LOCALLLM_USAGE_LOG")
    or os.environ.get("QWEN_USAGE_LOG")
    or os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage_localllm.log")
)

mcp = FastMCP("localllm")

# Cache model capabilities by model name (static per model). Maps name -> set.
_CAPS_CACHE: dict[str, set] = {}


def _http_json(path: str, payload: dict | None = None, timeout: float = 600.0) -> dict:
    """POST/GET a JSON request to the Ollama native API and return parsed JSON."""
    url = f"{OLLAMA_HOST}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST" if data else "GET"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def _resolve_model() -> str:
    """Pick the active model: explicit override > loaded (/api/ps) > installed > fallback."""
    if MODEL_OVERRIDE:
        return MODEL_OVERRIDE
    try:
        loaded = _http_json("/api/ps", timeout=5.0).get("models") or []
        if loaded:
            return loaded[0].get("name") or loaded[0].get("model") or FALLBACK_MODEL
    except Exception:
        pass
    try:
        installed = _http_json("/api/tags", timeout=5.0).get("models") or []
        if installed:
            return installed[0].get("name") or installed[0].get("model") or FALLBACK_MODEL
    except Exception:
        pass
    return FALLBACK_MODEL


def _capabilities(model: str) -> set:
    """Return the model's capability set (cached). Empty set on failure."""
    if model not in _CAPS_CACHE:
        try:
            caps = _http_json("/api/show", {"model": model}, timeout=10.0).get("capabilities") or []
        except Exception:
            caps = []
        _CAPS_CACHE[model] = set(caps)
    return _CAPS_CACHE[model]


def _log_usage(tool: str, model: str, system: str, user: str, resp: dict, latency_s: float) -> None:
    """Append a JSONL usage record. Never raise into the caller."""
    try:
        prompt_tokens = resp.get("prompt_eval_count")
        completion_tokens = resp.get("eval_count")
        total = None
        if prompt_tokens is not None or completion_tokens is not None:
            total = (prompt_tokens or 0) + (completion_tokens or 0)
        rec = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "source": "localllm",
            "tool": tool,
            "model": model,
            "input_chars": len(system) + len(user),
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": total,
            "latency_s": round(latency_s, 3),
        }
        with open(USAGE_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _chat(system: str, user: str, tool: str = "_chat") -> str:
    model = _resolve_model()
    options = {"num_predict": MAX_TOKENS, "temperature": TEMPERATURE}
    if TOP_P is not None:
        options["top_p"] = TOP_P
    if TOP_K is not None:
        options["top_k"] = TOP_K
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "options": options,
    }
    # Suppress chain-of-thought for thinking-capable models so the answer is
    # returned in `content` rather than eaten by reasoning under the token cap.
    if "thinking" in _capabilities(model):
        payload["think"] = False

    t0 = time.monotonic()
    try:
        resp = _http_json("/api/chat", payload)
    except urllib.error.HTTPError as e:
        # Some non-thinking models reject the `think` field; retry without it.
        if "think" in payload:
            payload.pop("think", None)
            resp = _http_json("/api/chat", payload)
        else:
            raise e
    _log_usage(tool, model, system, user, resp, time.monotonic() - t0)

    msg = resp.get("message") or {}
    # Prefer the actual answer; fall back to `thinking` if content is empty
    # (e.g. a thinking model that ignored think:false).
    return msg.get("content") or msg.get("thinking") or ""


@mcp.tool()
def ask_local(prompt: str) -> str:
    """Ask the local LLM a general question or request.

    Use this for lightweight tasks to save Claude API tokens:
    - Drafting boilerplate code or test cases
    - Explaining a short code snippet
    - Summarizing text
    - Translating comments or variable names
    - Answering simple factual questions about code patterns
    Do NOT use for tasks requiring file system access, tool use, or multi-step reasoning.
    """
    return _chat("You are a helpful coding assistant.", prompt, tool="ask_local")


@mcp.tool()
def ask_local_code(language: str, prompt: str) -> str:
    """Ask the local LLM to write or refactor code in a specific language.

    Use this for:
    - Generating boilerplate / stub implementations
    - Rewriting a function in a different style
    - Writing unit tests given a function signature
    - Translating code from one language to another
    Provide the target language and a clear description.
    """
    system = (
        f"You are an expert {language} programmer. "
        "Output only code unless asked for explanation. "
        "Use concise, idiomatic style."
    )
    return _chat(system, prompt, tool="ask_local_code")


if __name__ == "__main__":
    mcp.run(transport="stdio")
