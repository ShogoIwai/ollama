#!/usr/bin/env python3
"""MCP server: exposes the Antigravity CLI (`agy -p`) as Claude Code / Codex tools.

Purpose: give a *local* LLM run (source_local) a reliable external-access path.
Local models are weak at web access / RAG (see the "Verify web access" session),
so instead of building a crawler + vector store, we delegate every outward call
to Gemini via the already-authenticated Antigravity CLI.

Auth: reuses the OAuth credentials under ~/.gemini (Code Assist / cloud-platform
scope) that `agy` already holds. No GEMINI_API_KEY needed -- this works even on
an enterprise account where an API key cannot be minted. The CLI runs each
prompt non-interactively with `agy -p` and prints the answer. `agy` is agentic
and has live web search, so `ask_gemini_web` returns up-to-date, grounded text.

Only the Python standard library + FastMCP are used (matches mcp_localllm.py).
"""

import json
import os
import subprocess
import time
from datetime import datetime, timezone

from mcp.server.fastmcp import FastMCP

# Path to the Antigravity CLI binary. Override with AGY_BIN if it moves.
AGY_BIN = os.environ.get("AGY_BIN") or os.path.expanduser("~/.local/bin/agy")

# Working directory for the CLI session. agy resolves its workspace from cwd, so
# point it at a real, trusted directory (settings.json trustedWorkspaces).
AGY_WORKDIR = os.environ.get("AGY_WORKDIR") or os.path.expanduser("~/rep")

# Model pin. We force a Gemini model so this "gemini" tool actually runs on
# Gemini -- agy's own default comes from ~/.gemini settings (currently
# "Claude Opus 4.6 (Thinking)"), which is both off-brand here and slower.
# Flash (Low) keeps latency and token usage down for web/RAG lookups -- the
# account's token limit is tight. Override via AGY_MODEL; set it
# empty (AGY_MODEL=) to fall back to agy's configured default. See `agy models`.
AGY_MODEL = os.environ.get("AGY_MODEL", "Gemini 3.5 Flash (Low)") or None

# Fallback chain for rate-limit / empty-response recovery. When a call comes back
# empty (agy prints nothing when a model is throttled -- it exits 0 with no
# stdout), we retry the same prompt on the next model here.
#
# In practice this account's Gemini tiers share a quota: when one Gemini model is
# throttled the others usually are too, so escalating across Gemini tiers buys
# nothing (verified 2026-06-13). The chain is therefore one model per provider --
# Gemini -> Claude -> GPT-OSS -- so a single throttle hop reaches a different
# quota bucket and returns a real answer fast. Non-Gemini answers are tagged in
# the output so the caller knows it isn't Gemini. Override via
# AGY_MODEL_FALLBACKS (comma-separated). The primary AGY_MODEL is tried first
# and de-duplicated out of this list.
_DEFAULT_FALLBACKS = [
    "Gemini 3.5 Flash (Low)",
    "Claude Sonnet 4.6 (Thinking)",
    "GPT-OSS 120B (Medium)",
]

# Models that are not Gemini; answers from these get a banner so the caller is
# not misled into thinking the "gemini" tool actually ran on Gemini.
def _is_gemini(model) -> bool:
    return bool(model) and model.lower().startswith("gemini")
_fallback_env = os.environ.get("AGY_MODEL_FALLBACKS")
AGY_MODEL_FALLBACKS = (
    [m.strip() for m in _fallback_env.split(",") if m.strip()]
    if _fallback_env is not None
    else _DEFAULT_FALLBACKS
)

# Ordered list of models to try: primary first, then any fallback not already
# covered. None (agy default) is kept as a final attempt if AGY_MODEL is unset.
def _model_chain() -> list:
    chain = []
    if AGY_MODEL:
        chain.append(AGY_MODEL)
    for m in AGY_MODEL_FALLBACKS:
        if m and m not in chain:
            chain.append(m)
    if not chain:
        chain.append(None)  # fall back to agy's configured default
    return chain

# Hard wall-clock cap for a single call (seconds). agy's own --print-timeout is
# set just under this so the CLI returns before subprocess.run kills it.
TIMEOUT = int(os.environ.get("AGY_TIMEOUT", "300"))

# Usage log: one JSONL record per call, same schema as mcp_localllm.py's
# usage_localllm.log so usage_report.py can aggregate both. agy does not expose
# token counts, so those fields are null here.
USAGE_LOG = (
    os.environ.get("AGY_USAGE_LOG")
    or os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage_gemini.log")
)

mcp = FastMCP("gemini")


def _run_agy_once(prompt: str, tool: str, model) -> tuple:
    """Run one `agy -p` attempt on `model`. Returns (text, ok).

    `ok` is False when the attempt should trigger a fallback retry: an empty
    response (agy prints nothing when the model is rate-limited -- it still exits
    0) or a non-zero exit with no usable stdout. A genuine answer sets ok=True.

    --dangerously-skip-permissions lets agy use its tools (web search, file
    reads) without an interactive approval prompt, which would otherwise hang a
    headless call. Safe here: the tool only ever runs the prompts we pass it.
    """
    cmd = [AGY_BIN, "--print", prompt, "--dangerously-skip-permissions"]
    # Give agy slightly less time than our subprocess wall so it can flush a
    # partial answer instead of being SIGKILLed mid-write.
    cmd += ["--print-timeout", f"{max(TIMEOUT - 15, 30)}s"]
    if model:
        cmd += ["--model", model]

    label = model or "agy-default"
    started = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=AGY_WORKDIR,
            # Detach stdin: when this server is spawned by an MCP host, our stdin
            # is the JSON-RPC pipe. agy would otherwise inherit and block on it
            # (and could steal client bytes). DEVNULL makes agy run headless.
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        _log(tool, len(prompt), time.monotonic() - started, "timeout", label)
        # Timeout is not a quota signal, but retrying on a faster tier may help.
        return (f"[gemini error] agy timed out after {TIMEOUT}s", False)

    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    _log(tool, len(prompt), time.monotonic() - started,
         f"rc={proc.returncode}", label)

    if proc.returncode != 0 and not out:
        tail = err[-800:] if err else "(no stderr)"
        return (f"[gemini error] agy exited {proc.returncode}: {tail}", False)
    if not out:
        # Empty stdout with rc=0 is agy's rate-limit / throttle signature.
        return ("[gemini error] empty response", False)
    return (out, True)


def _run_agy(prompt: str, tool: str) -> str:
    """Run a prompt through `agy -p`, falling back across the model chain on
    rate-limit / empty responses. Returns the first real answer, or the last
    error annotated with the models tried.
    """
    chain = _model_chain()
    last = "[gemini error] empty response"
    for i, model in enumerate(chain):
        text, ok = _run_agy_once(prompt, tool, model)
        if ok:
            if not _is_gemini(model):
                # Be honest: this answer did not come from Gemini.
                return (f"[note] Gemini was rate-limited; answered with "
                        f"'{model}' instead.\n\n{text}")
            return text
        last = text
        # Brief backoff before escalating to the next tier (skip after last).
        if i < len(chain) - 1:
            time.sleep(1)
    tried = ", ".join(m or "agy-default" for m in chain)
    return f"{last} (all models rate-limited/failed; tried: {tried})"


def _log(tool: str, input_chars: int, latency_s: float, status: str,
         model: str = None) -> None:
    """Append a JSONL record matching mcp_localllm.py's schema (token fields
    are null because agy does not report token counts). Never raise."""
    try:
        rec = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "source": "gemini",
            "tool": tool,
            "model": model or AGY_MODEL or "agy-default",
            "input_chars": input_chars,
            "prompt_tokens": None,
            "completion_tokens": None,
            "total_tokens": None,
            "latency_s": round(latency_s, 3),
            "status": status,
        }
        with open(USAGE_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


@mcp.tool()
def ask_gemini_web(query: str) -> str:
    """Answer a question using Gemini with live web search (grounded).

    Use this whenever the local model needs *external* information: current
    facts, library/API docs, release notes, "what is the latest ...", looking up
    anything not in the local repo. Gemini searches the web and returns an
    up-to-date answer with sources where available. This is the external-access
    path for source_local runs -- prefer it over trying to fetch/RAG locally.
    """
    grounded = (
        "Search the web for current, authoritative information and answer the "
        "following. Cite source URLs inline.\n\n" + query
    )
    return _run_agy(grounded, tool="ask_gemini_web")


@mcp.tool()
def ask_gemini(prompt: str) -> str:
    """Send a prompt to Gemini (no forced web search).

    Use for reasoning, long-text summarization, code explanation, or drafting --
    tasks that do not require fresh external lookups. Gemini may still use its
    tools if it deems them necessary.
    """
    return _run_agy(prompt, tool="ask_gemini")


if __name__ == "__main__":
    mcp.run()
