# Local LLM Workflow — Ollama + Claude Code + Codex

`ollama/` provides a local LLM environment for Claude Code, Codex, and Goose,
built on **Ollama + qwen3-coder**. It replaces the former `vllm/` (vLLM +
Qwen3-Coder-30B-A3B-AWQ) setup: only the inference backend changes; the clients
still talk to the same OpenAI-compatible (`/v1`) and Anthropic-compatible
(`/v1/messages`) endpoints, now served on a single port `11434`.

Two things differ from the vLLM setup:

1. **Independent repository.** Ollama assets live here in `ollama/`, separate
   from `vllm/`. The two are independent; you can keep `vllm/` around for
   rollback and switch clients by env/profile only.
2. **No quota monitoring.** cloud / local switching is **static, per client**:
   Claude Code by env + alias, Codex by profile/alias, and Goose is local-only
   via its own `config.yaml` (no env, never cloud). No client shares an
   `OPENAI_*` env var, so none can override another. The 5h-quota dynamic routing
   from `vllm/` (`proxy.py` / `quota_route.py` / `usage_route_hook.py` /
   `codex_quota_context.py`) is **not** ported here.

---

## Directory Contents

| File                            | Role                                                                         |
| ------------------------------- | ---------------------------------------------------------------------------- |
| `start_ollama_qwen3_coder.sh` | Server start wrapper: exports tuning env, runs `ollama serve`, pulls model |
| `source_local` / `.csh`     | LOCAL mode: export Claude Code `ANTHROPIC_*` + alias `claude`/`codex` to local |
| `source_cloud` / `.csh`     | CLOUD mode: unset those env vars and `unalias claude`/`codex`                |
| `mcp_qwen.py`                 | MCP server exposing Qwen as `ask_qwen` / `ask_qwen_code` tools           |
| `usage_report.py`             | Aggregate local Qwen token usage from `usage.log`                          |
| `usage.log`                   | JSONL usage records written by `mcp_qwen.py` (gitignored)                  |

---

## Quick Start

### 1. Install Ollama and pull the model

```bash
# Ollama runtime (Linux)
curl -fsSL https://ollama.com/install.sh | sh
ollama -v                 # confirm v0.14.0+ (needed for Anthropic /v1/messages)

ollama pull qwen3-coder
ollama run qwen3-coder     # optional REPL smoke test
```

> **systemd note:** the installer may register `ollama.service` (running as the
> `ollama` user) and start it on boot. If you run the server yourself via the
> wrapper below, stop and disable that unit first, otherwise `ollama serve`
> fails with `bind: address already in use`:
>
> ```bash
> sudo systemctl stop ollama && sudo systemctl disable ollama
> ```
>
> The systemd unit stores models under `/usr/share/ollama/.ollama/models`,
> while a user-launched `serve` reads `~/.ollama/models`. If you switch the
> run user, move the model store (and `chown` it) or set `OLLAMA_MODELS`, or
> the model will be re-pulled.

### 2. Start the server

```bash
./start_ollama_qwen3_coder.sh
```

The wrapper:

- exports `OLLAMA_HOST` (default `http://localhost:11434`) and
  `OLLAMA_CONTEXT_LENGTH` (default `64000`);
- if a daemon is already reachable, reports and exits 0 (does nothing);
- otherwise starts `ollama serve` in the background, waits for the API, pulls
  `qwen3-coder` if missing, then keeps the daemon in the foreground.

> **Context length:** Ollama auto-limits context to 4K when VRAM < 24GB (e.g.
> RTX 3090 24GB defaults to 32768). Agent use needs more, so the wrapper sets
> `OLLAMA_CONTEXT_LENGTH=64000`. **This applies only to the `serve` launched by
> this script** — a daemon started elsewhere (systemd) keeps its own setting.
> Check the loaded context and CPU/GPU split with `ollama ps`.

---

## Models and memory requirements

`qwen3-coder` (MoE, ~3B active, large native context, non-thinking mode by
default) is the primary candidate. Pick a GGUF quantization to fit your memory:

| Quant      | Memory      | Target environment    | tok/s  |
| ---------- | ----------- | --------------------- | ------ |
| UD-Q2_K    | ~26–30 GB  | 32 GB unified memory  | 15–25 |
| UD-Q4_K_XL | ~35–40 GB  | 64 GB Mac / RTX 5090  | 20–30 |
| Q6_K       | ~50–55 GB  | 96 GB workstation     | 25–40 |
| Q8_0       | ~65–70 GB  | 128 GB WS / multi-GPU | 30–45 |
| FP8        | ~90–110 GB | H100 / A100           | 40–60 |

> On a 24 GB GPU, a strongly quantized GGUF runs with partial CPU offload
> (`ollama ps` shows the split). Final selection should be confirmed against
> measured VRAM and speed requirements.

---

## cloud / local static switching

Switching is done by sourcing one of two env files. There is no dynamic
routing. A freshly opened shell is already in cloud mode; `source_local`
exports the Ollama overrides, and `source_cloud` unsets them to return to cloud
within the same shell.

The env files toggle **Claude Code only** (`ANTHROPIC_*`). They deliberately
do **not** touch any `OPENAI_*` variable — Codex's cloud OpenAI client reads
those too, so exporting them would silently redirect Codex to the local server.
**Goose is local-only and self-contained**: its endpoint lives entirely in
`~/.config/goose/config.yaml`, so Goose needs no shell env, is unaffected by
these files, and never conflicts with Codex. See the [Goose](#goose) section.

| File                        | Mode          | Effect                                                                                                  |
| --------------------------- | ------------- | ------------------------------------------------------------------------------------------------------- |
| `source_local` / `.csh` | LOCAL(Ollama) | export `ANTHROPIC_BASE_URL=:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, `OLLAMA_HOST`; alias `claude`/`codex` to local (see [Aliases](#aliases-set-by-source_local)) |
| `source_cloud` / `.csh` | CLOUD         | unset the above (tcsh `unsetenv`) and `unalias claude` / `codex`; re-set `ANTHROPIC_API_KEY` if you authenticate by key |

### Aliases set by `source_local`

`source_local` defines two shell aliases so plain `claude` / `codex` run in
local mode without typing flags; `source_cloud` removes them again:

| Alias                                | Why                                                                        |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `claude` → `claude --model qwen3-coder` | env already targets Ollama; the alias just pins the model name             |
| `codex` → `codex --profile ollama-local` | Codex shares no env (OPENAI_* stays unset), so the profile flag selects local |

After `source_cloud` the aliases are dropped and `claude` / `codex` revert to
their cloud defaults. (Alias self-reference is safe — bash/csh do not re-expand
the leading word recursively.)

### Claude Code

```bash
# local
source ollama/source_local         # tcsh: source ollama/source_local.csh
claude                             # alias → claude --model qwen3-coder
# (optional) alias to bypass model-name validation:
#   ollama cp qwen3-coder claude-3-5-sonnet

# cloud
source ollama/source_cloud         # tcsh: source ollama/source_cloud.csh
claude                             # alias cleared → cloud default
```

### Codex

`source_local` aliases `codex` → `codex --profile ollama-local`; `source_cloud`
clears it so `codex` is cloud again. You can still invoke either explicitly
(`codex --profile ollama-local` / `codex`) regardless of which file is sourced.

The profile mechanism is independent of the env files. Since Codex
v0.136 the profile **must not** live in `config.toml` as a `[profiles.<name>]`
table (or a `profile = "..."` selector) — Codex rejects it with a "legacy
profile" error. Keep only the shared provider definition in `config.toml`:

```toml
# ~/.codex/config.toml
[model_providers.ollama-local]
name = "Ollama"
base_url = "http://localhost:11434/v1"
```

and put the profile-specific settings in their own overlay file named
`~/.codex/<profile>.config.toml`:

```toml
# ~/.codex/ollama-local.config.toml
model = "qwen3-coder"
model_provider = "ollama-local"
```

```bash
codex --profile ollama-local       # local (loads ollama-local.config.toml)
codex                              # cloud (default profile)
```

### Goose

Goose is **local-LLM only** and fully **self-contained** — it does **not** use
the `source_local` / `source_cloud` env files and shares **no** environment
variable with Codex. All of its settings live in `~/.config/goose/config.yaml`:

```yaml
OPENAI_BASE_URL: http://localhost:11434/v1
OPENAI_HOST: http://localhost:11434/v1
OPENAI_BASE_PATH: v1/chat/completions
GOOSE_DISABLE_KEYRING: 1
GOOSE_TOOLSHIM: 1
active_provider: openai
providers:
  openai:
    enabled: true
    model: qwen3-coder
    configured: true
```

Goose reads config-file keys the same way it reads env vars, so keeping
`OPENAI_BASE_URL` (and the two `GOOSE_*` settings) in `config.yaml` means Goose
always targets the local server **without** any shell export. This is the key
to not colliding with Codex: previously `source_local` exported `OPENAI_BASE_URL`
into the shell, which Codex's cloud OpenAI client also honors and would follow
to the local endpoint. With the endpoint confined to `config.yaml`, Codex's
cloud/local choice (its `--profile`) and Goose's local-only target are fully
independent — no env var is shared, so neither overrides the other.

---

## MCP Integration

`mcp_qwen.py` exposes the local Qwen model as two stdio MCP tools. It talks to
Ollama's OpenAI-compatible endpoint via the OpenAI SDK; `OLLAMA_BASE_URL`
(default `http://localhost:11434/v1`) and `QWEN_MODEL_ID` (default
`qwen3-coder`) can override the target.

### Register

```bash
# Claude Code
claude mcp add -s user qwen-local python3 $REP/ollama/mcp_qwen.py

# Codex
codex mcp add qwen-local -- python3 $REP/ollama/mcp_qwen.py
```

Verify in Claude Code with `/mcp` (expect `qwen-local` connected) and call
`ask_qwen`.

### Available tools

| Tool                                | Use for                                                                      |
| ----------------------------------- | ---------------------------------------------------------------------------- |
| `ask_qwen(prompt)`                | Prose: Q&A, explanations, summaries, translation, comment/docstring rewrites |
| `ask_qwen_code(language, prompt)` | Code: generation, refactoring, unit-test skeletons, stubs, code translation  |

### Token usage logging

Each call appends a JSONL record (timestamp, tool, model, token counts,
latency) to `usage.log` (override with `QWEN_USAGE_LOG`). Summarize with:

```bash
python3 ollama/usage_report.py            # daily / per-tool table
python3 ollama/usage_report.py --by tool  # group by tool
python3 ollama/usage_report.py --json     # machine-readable totals
```

---

## Tips: Codex stop-review-gate rg Process Lingering Issue

Codex's `stop-review-gate` hook spawns `codex-companion.mjs`, which scans the repository with `rg .`. After the task completes or times out, child `rg` processes can remain orphaned — keeping load average elevated.

### Root Cause & Primary Mitigation: Operate at the Second Level or Deeper

The harness launch root (the top-level workspace directory) is not a single git
repository — it holds many independently-cloned repositories. When `git` is run
from that root it fails, so the review gate falls back to extracting the diff with
a repository-wide `rg .`, which is exactly what spawns the lingering `rg` processes.

**The first-line fix is to always operate at the second level or deeper**, i.e.
`cd` into the concrete target project (`<workspace-root>/<project>/<subdir>`, a
real git working tree) before any `git` / diff operation, instead of the launch
root. Inside a single repository `git` stays valid and the gate extracts a real
diff rather than scanning the whole tree. This general rule is documented in both
`~/.claude/CLAUDE.md` (Claude Code) and `~/.codex/AGENTS.md` (Codex). The `Stop`
hook below remains as a belt-and-suspenders cleanup for any `rg` that still leaks.

### Fix: Claude Code `Stop` Hook

Add the following to `~/.claude/settings.json`. Claude Code runs it automatically when each session ends, killing any lingering `rg` processes before they accumulate.

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "MY_SID=$(ps -p $$ -o sid= 2>/dev/null | tr -d ' '); pgrep -u \"$(id -un)\" rg 2>/dev/null | while read p; do [ \"$(ps -p $p -o sid= 2>/dev/null | tr -d ' ')\" = \"$MY_SID\" ] && kill $p 2>/dev/null; done; true"
          }
        ]
      }
    ]
  }
}
```

The hook matches `rg` processes by **session ID (SID)**. SID is inherited from the parent at fork and does not change when a process becomes orphaned — so even after `codex-companion.mjs` exits and `rg` is reparented to init, it retains the Claude Code session's SID.

> **Best-effort:** this is not a perfect filter. `rg` processes started from the same terminal session that launched Claude Code share the same SID and would also be killed. In practice this trade-off is acceptable — intentional long-running `rg` searches in the same terminal as an active Claude Code session are rare.

---

## Delegation Mode

Both Claude Code and Codex act as orchestration layers that can route individual
subtasks to the local Qwen for the core reasoning or generation step. This
applies across all cloud models — the same policy governs Claude Code and Codex
regardless of which model or effort level is active.

### Delegation Principle

This section is the **single source of truth** for both the Qwen offload
criteria and the MCP call best practices. The client configuration files
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) should reference this section
rather than restate the rules, so all clients stay in sync.

The key design point is that delegation should **not** be handled as a static
model-switch policy. Instead, the decision should be based on the **task
characteristics** and on whether moving work to Qwen actually reduces the
expensive reasoning burden on the primary agent.

In other words, the question is not "which model is active?" but "is this
subtask a good candidate for offload?".

Model choice and effort level are an **orthogonal** axis. They control how
deeply the cloud model reasons about the work it keeps — not whether a subtask is
offloaded. A weaker/cheaper model does not mean "offload everything," and a
stronger model does not mean "offload nothing"; the offload boundary is the same
in both cases and is determined only by task shape.

#### Offload criteria (when to route to Qwen)

**Good offload candidates**

- Highly repetitive or formulaic work
- Localized inputs with limited context (one file, one function, a short passage)
- Outputs that are easy to verify quickly
- Tasks where small formatting or wording differences are acceptable
- Boilerplate generation, stubs, short summaries, translation, and simple transformations

**Poor offload candidates**

- Cross-file reasoning or system-wide consistency checks
- Root-cause analysis and architecture decisions
- Tasks where mistakes can silently introduce bugs
- Cases where preparing the handoff context is almost as expensive as doing the work directly
- Anything requiring the delegate model to read files by path, call tools, or maintain state across calls

The decision procedure is the same for every client and every model:

1. classify the task by shape first
2. decide whether delegation reduces the primary agent's reasoning load
3. then choose whether to route the subtask to local Qwen

That keeps the system portable across Claude Code, Codex, and future clients,
because the offload decision is expressed in terms of work shape rather than in
terms of a specific model family.

#### Call best practices (how to call the MCP tools)

These apply identically to every client (Claude Code, Codex, future clients).

**Tool selection**

| Tool                                | Use for                                                                      |
| ----------------------------------- | ---------------------------------------------------------------------------- |
| `ask_qwen(prompt)`                | Prose: Q&A, explanations, summaries, translation, comment/docstring rewrites |
| `ask_qwen_code(language, prompt)` | Code: generation, refactoring, unit-test skeletons, stubs, code translation  |

**Routing rules**

1. **Pure Q&A / explanation / summary / translation** (good candidate)
   → call `ask_qwen(prompt=<full request>)`; return the response verbatim.
2. **Code generation / refactoring / unit tests** (formulaic, self-contained)
   → determine the language from context; call `ask_qwen_code(language=<lang>, prompt=<request + required context>)`; return verbatim.
3. **Tasks requiring file I/O** → the client reads/searches files itself, passes
   the actual relevant content (never a path) to Qwen, then applies the result
   with its own editing tools and verifies.
4. **Multi-step tasks** → break into the smallest steps; offload each good
   candidate; keep root-cause analysis and cross-file reasoning in the cloud
   model; the client owns orchestration, context packaging, and validation.

**Handoff constraints** — Qwen has no filesystem access, no tool access, and no
memory across calls. Always pass the actual relevant text in the prompt; never
ask Qwen to read a path, call a tool, or rely on a previous call.

**What NOT to do when offloading**

- Do not also generate the answer yourself for an offloaded subtask.
- Do not restate Qwen's output in your own words when its output suffices.
- Do not call Qwen and then layer your own commentary on top.
- Do not force-offload a poor candidate (cross-file, root-cause, high-risk) just to save tokens.

**Token budget** — see [Token Limits](#token-limits). In short: ≤ 2,048 output
tokens per call. Pack as much relevant context as the task needs, up to the
model's context window. Split into multiple calls only when the input exceeds
the context window (one file per call, combine yourself) or the expected answer
exceeds the 2,048-token output limit (split the output across calls).

### Architecture

```
User → Claude Code → MCP (stdio) → mcp_qwen.py → Ollama :11434 → qwen3-coder
User → Codex       → MCP (stdio) → mcp_qwen.py → Ollama :11434 → qwen3-coder
```

The cloud model handles orchestration: reading files, running searches, applying
edits, and verifying results. Qwen handles the text-in/text-out reasoning or
generation step.

### Configuration locations

The offload criteria and call best practices live only in the
[Delegation Principle](#delegation-principle) above. The per-client files below
do **not** restate them — they carry a pointer to that section plus any
client-specific note (tool names, who owns file I/O):

| Client      | Configuration file      |
| ----------- | ----------------------- |
| Claude Code | `~/.claude/CLAUDE.md` |
| Codex       | `~/.codex/AGENTS.md`  |

### Token Limits

| Limit                    | Value                                         | Source                              |
| ------------------------ | --------------------------------------------- | ----------------------------------- |
| Output per call (client) | **≤ 2,048 tokens**                     | `mcp_qwen.py` `max_tokens=2048` |
| Sampling temperature     | `0.2`                                       | `mcp_qwen.py` request param       |
| Context window           | `OLLAMA_CONTEXT_LENGTH` (64000 via wrapper) | server-side (per loaded model)      |

`OLLAMA_CONTEXT_LENGTH` is the **combined** input+output budget per loaded
model. The `2,048` figure is the per-call **output** limit set by the MCP server.

---

## Risks and notes

- **Context default trap:** Ollama auto-limits to 4K below 24 GB VRAM. Set
  `OLLAMA_CONTEXT_LENGTH` (≥ 64K) explicitly for agent use.
- **Tool-call (function calling) behavior:** depends on model/template; verify
  Goose / Codex tool calls after migrating.
- **Model equivalence:** AWQ(30B-A3B) and GGUF(qwen3-coder) are different builds;
  output quality/speed can differ. Track delegation quality regression via
  `usage_report.py` before/after.
- **Static-switch responsibility:** dynamic routing is gone, so cloud/local
  selection is the user's explicit choice. There is no automatic quota-exhaustion
  fallback.

## Rollback

The migration is local (base_url + start script + env + repo). To revert,
ignore `ollama/` and use the previous `vllm/` environment (`start_vllm_*.sh`
plus quota monitoring). The two repos are independent, so you can also run
`ollama` alongside and switch clients by env/profile only.
