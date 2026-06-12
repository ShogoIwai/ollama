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


def _run_agy(prompt: str, tool: str) -> str:
    """Run a single non-interactive prompt through `agy -p` and return its stdout.

    --dangerously-skip-permissions lets agy use its tools (web search, file
    reads) without an interactive approval prompt, which would otherwise hang a
    headless call. Safe here: the tool only ever runs the prompts we pass it.
    """
    cmd = [AGY_BIN, "--print", prompt, "--dangerously-skip-permissions"]
    # Give agy slightly less time than our subprocess wall so it can flush a
    # partial answer instead of being SIGKILLed mid-write.
    cmd += ["--print-timeout", f"{max(TIMEOUT - 15, 30)}s"]
    if AGY_MODEL:
        cmd += ["--model", AGY_MODEL]

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
        _log(tool, len(prompt), time.monotonic() - started, "timeout")
        return f"[gemini error] agy timed out after {TIMEOUT}s"

    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    _log(tool, len(prompt), time.monotonic() - started, f"rc={proc.returncode}")

    if proc.returncode != 0 and not out:
        tail = err[-800:] if err else "(no stderr)"
        return f"[gemini error] agy exited {proc.returncode}: {tail}"
    return out or "[gemini error] empty response"


def _log(tool: str, input_chars: int, latency_s: float, status: str) -> None:
    """Append a JSONL record matching mcp_localllm.py's schema (token fields
    are null because agy does not report token counts). Never raise."""
    try:
        rec = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "source": "gemini",
            "tool": tool,
            "model": AGY_MODEL or "agy-default",
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
