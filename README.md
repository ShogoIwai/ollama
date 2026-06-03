# Local LLM Workflow — Ollama + Claude Code + Codex

`ollama/` provides a local LLM environment for Claude Code, Codex, and Goose,
built on **Ollama**. Two local models are supported interchangeably —
**`qwen3-coder`** (default, non-thinking) and **`gemma4:26b`** (thinking-capable
MoE) — each with its own thin launcher (`start_ollama_qwen3_coder.sh` /
`start_ollama_gemma4.sh`) sharing one core (`_ollama_serve_common.sh`). The MCP
server auto-detects whichever is loaded; the harness direct-connect picks the
model by the `LOCALLLM_MODEL` env var (see
[cloud / local static switching](#cloud--local-static-switching)). It replaces
the former `vllm/` (vLLM +
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

| File                            | Role                                                                                   |
| ------------------------------- | -------------------------------------------------------------------------------------- |
| `start_ollama_qwen3_coder.sh` | Thin launcher for `qwen3-coder`: sets `MODEL` and sources the shared core          |
| `start_ollama_gemma4.sh`      | Thin launcher for `gemma4:26b` (override `MODEL=` for another size/quant)          |
| `start_ollama_gemma3_wsl.sh`  | Thin launcher for `gemma3:4b` on a WSL / GPU-less, low-memory host (CPU inference); caps context low (see [WSL / low-memory (CPU)](#wsl--low-memory-cpu)) |
| `_ollama_serve_common.sh`     | Shared core sourced by the launchers (daemon start, readiness wait, lazy pull); records the launched model in `~/.ollama_active_model` |
| `source_local` / `.csh`     | LOCAL mode: export Claude Code `ANTHROPIC_*` + alias `claude`/`codex` to local   |
| `source_cloud` / `.csh`     | CLOUD mode: unset those env vars and `unalias claude`/`codex`                      |
| `mcp_localllm.py`             | MCP server exposing the active local model as `ask_local` / `ask_local_code` tools |
| `usage_report.py`             | Aggregate local LLM token usage from `usage.log`                                     |
| `usage.log`                   | JSONL usage records written by `mcp_localllm.py` (gitignored)                        |

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
./start_ollama_qwen3_coder.sh        # qwen3-coder (default)
./start_ollama_gemma4.sh             # gemma4:26b  (override MODEL= for another size)
#   MODEL=gemma4:31b ./start_ollama_gemma4.sh
./start_ollama_gemma3_wsl.sh         # gemma3:4b on WSL / GPU-less CPU host (low ctx)
```

For a WSL / GPU-less, low-memory host, use `start_ollama_gemma3_wsl.sh`. It
differs from the GPU launchers in one way — it caps the context window low so the
KV cache cannot blow past RAM on CPU. See [WSL / low-memory (CPU)](#wsl--low-memory-cpu).

Each launcher is a thin wrapper: it sets the `MODEL` tag and sources the shared
core `_ollama_serve_common.sh`. Adding a new model is one more 2-line launcher —
everything else (daemon start, readiness wait, lazy pull, foreground lifecycle)
lives once in the common file. The wrapper:

- exports `OLLAMA_HOST` (default `http://localhost:11434`) and
  `OLLAMA_CONTEXT_LENGTH` (default `64000`);
- if a daemon is already reachable, reports and exits 0 (does nothing);
- otherwise starts `ollama serve` in the background, waits for the API, pulls
  the selected `MODEL` if missing, then keeps the daemon in the foreground.

> Only one daemon binds `:11434`. To switch which model serves, stop the running
> launcher and start the other; the MCP server then auto-detects the newly
> loaded model. Run both side by side only if you give each its own
> `OLLAMA_HOST` port.

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

## WSL / low-memory (CPU)

The model table above targets large GPU / workstation memory. A typical **WSL
host has no usable GPU budget and ~8 GB RAM** (`/dev/dri` exists via WSLg but VRAM
is negligible), so those builds will not load. For that environment, run a small
model **on CPU** instead.

**Default: `gemma3:4b`** (Google Gemma 3, Q4_K_M). Gemma ran better than Qwen on
the Linux workstation, and the 4B build fits an 8 GB host with headroom. Other
Google-family candidates that fit CPU inference:

| Model / tag         | Params | Resident (Q4) | CPU tok/s | Use for                          |
| ------------------- | ------ | ------------- | --------- | -------------------------------- |
| `gemma3:1b`       | 1B     | ~0.8 GB      | fast      | ultra-light always-on completion |
| `gemma2:2b`       | 2B     | ~1.6 GB      | —        | light chat                       |
| `codegemma:2b`    | 2B     | ~1.6 GB      | —        | code completion (FIM-oriented)   |
| **`gemma3:4b`** | 4B     | **~2.9 GB**  | **~12**  | chat / edit / MCP delegation     |

Measured on an 8 GB / 12-thread WSL host: `gemma3:4b` runs at **~11–12 tok/s**,
**~2.9 GB resident, VRAM 0.0 (pure CPU)**, context honored at the launcher's cap.

### Start

```bash
./start_ollama_gemma3_wsl.sh           # gemma3:4b, OLLAMA_CONTEXT_LENGTH=8192
#   MODEL=gemma3:1b ./start_ollama_gemma3_wsl.sh          # smaller model
#   OLLAMA_CONTEXT_LENGTH=4096 ./start_ollama_gemma3_wsl.sh   # tighter RAM
```

Unlike the GPU launchers (which default `OLLAMA_CONTEXT_LENGTH=64000`), the WSL
launcher defaults it to **8192**. On CPU with limited RAM, a 16K+ context grows
the KV cache to 3–4 GB and drives the host into swap (sub-1 tok/s); drop to
4096 if memory is tight. Both `MODEL` and `OLLAMA_CONTEXT_LENGTH` can be
overridden before running.

### Use MCP delegation, not direct connect

On WSL the **default integration is [MCP delegation](#mcp-integration)**
(`ask_local` / `ask_local_code`) — text-in/text-out, which these small models
handle well. **Do not** point Claude Code / Codex at the local server as a direct
agentic backend: `gemma3:4b` reports no `tools` capability, and when prompted for
a tool call it emits the call as **plain-text JSON in `content`**, not a
structured `tool_calls` block — the client cannot detect it and "hallucinates"
edits that never reach disk (the tool-calling conversion problem). Direct connect
would need an Anthropic-emulating gateway (Bifrost / LiteLLM) plus attribution-header
suppression; MCP delegation avoids all of that. `gemma3` is also not
thinking-capable, so `mcp_localllm.py` calls it plainly.

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

| File                        | Mode          | Effect                                                                                                                                                                                           |
| --------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `source_local` / `.csh` | LOCAL(Ollama) | export `ANTHROPIC_BASE_URL=:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, `OLLAMA_HOST`; alias `claude`/`codex` to local (see [Aliases](#aliases-set-by-source_local)) |
| `source_cloud` / `.csh` | CLOUD         | unset the above (tcsh `unsetenv`) and `unalias claude` / `codex`; re-set `ANTHROPIC_API_KEY` if you authenticate by key                                                                  |

### Aliases set by `source_local`

`source_local` defines two shell aliases so plain `claude` / `codex` run in
local mode without typing flags; `source_cloud` removes them again. The model
each alias selects is **no longer hard-coded** — it is **auto-detected from the
running launcher** and can still be overridden by two env vars you set **before**
sourcing:

| Env var (override before sourcing) | Default                              | Controls                                          |
| ---------------------------------- | ------------------------------------ | ------------------------------------------------- |
| `LOCALLLM_MODEL`                 | auto (marker → else `qwen3-coder`) | the model tag pinned by the `claude` alias      |
| `LOCALLLM_CODEX_PROFILE`         | derived from `LOCALLLM_MODEL`      | the Codex profile selected by the `codex` alias |

**Auto-detection (marker file).** Each start script records the launched model
tag in `~/.ollama_active_model` (written by `_ollama_serve_common.sh` as soon as
`MODEL` is known, so it applies on every path including the already-running
early-exit). When `source_local` runs and `LOCALLLM_MODEL` is unset, it reads
that marker — so sourcing automatically tracks whichever model you started, with
no manual edits. If the marker is missing it falls back to `qwen3-coder`. An
explicit `setenv`/`export LOCALLLM_MODEL` before sourcing always wins.

`LOCALLLM_CODEX_PROFILE`, when unset, is **derived from `LOCALLLM_MODEL`** via a
`switch` in `source_local.csh`: `gemma4*` ⇒ `ollama-gemma`, everything else ⇒
`ollama-local`. Add one `case` + a matching overlay file per new local model.
(`ollama ps` is *not* used for detection: it only lists models already loaded
into memory on demand, so it is empty right after `ollama serve` starts.)

```bash
# auto: start a model, then just source — both clients follow it
./start_ollama_gemma4.sh                   # writes marker = gemma4:26b
source ollama/source_local                 # tcsh: source ollama/source_local.csh
#   → claude --model gemma4:26b, codex --profile ollama-gemma

# manual override still works (wins over the marker)
export LOCALLLM_MODEL=gemma4:26b           # tcsh: setenv LOCALLLM_MODEL gemma4:26b
source ollama/source_local                 # claude alias → claude --model gemma4:26b
```

The two env files resolve the aliases at source time:

| Alias                                                    | Why                                                                           |
| -------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `claude` → `claude --model $LOCALLLM_MODEL`         | env already targets Ollama; the alias just pins the model name                |
| `codex` → `codex --profile $LOCALLLM_CODEX_PROFILE` | Codex shares no env (OPENAI_* stays unset), so the profile flag selects local |

`source_local` also exports `LOCALLLM_MODEL` / `LOCALLLM_CODEX_PROFILE` so the
choice is visible to subprocesses; `source_cloud` unsets both along with the
aliases, so `claude` / `codex` revert to their cloud defaults. (Alias
self-reference is safe — bash/csh do not re-expand the leading word
recursively.)

> **Note:** `LOCALLLM_MODEL` selects the model for the **harness direct-connect**
> (the `claude` alias). It is independent of the MCP server, which always
> auto-detects the loaded model on its own. Make sure the model you point the
> alias at is actually the one the running launcher serves.

### Claude Code

```bash
# local
source ollama/source_local         # tcsh: source ollama/source_local.csh
claude                             # alias → claude --model $LOCALLLM_MODEL (default qwen3-coder)
# (optional) alias to bypass model-name validation:
#   ollama cp qwen3-coder claude-3-5-sonnet

# cloud
source ollama/source_cloud         # tcsh: source ollama/source_cloud.csh
claude                             # alias cleared → cloud default
```

### Codex

`source_local` aliases `codex` → `codex --profile $LOCALLLM_CODEX_PROFILE`;
`source_cloud` clears it so `codex` is cloud again. You can still invoke either
explicitly (`codex --profile ollama-local` / `codex`) regardless of which file is
sourced. By default `LOCALLLM_CODEX_PROFILE` is **auto-derived from the detected
`LOCALLLM_MODEL`** (see the auto-detection note above): `gemma4*` ⇒ `ollama-gemma`,
otherwise ⇒ `ollama-local`. To force a specific profile, set
`LOCALLLM_CODEX_PROFILE` before sourcing — Codex picks the model per profile
(overlay file), not per env var, so each profile needs its own overlay file
(e.g. `ollama-gemma` ⇒ `~/.codex/ollama-gemma.config.toml` with
`model = "gemma4:26b"`).

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

Add one overlay file per local model you want a `codex --profile` for; they all
reuse the single shared `ollama-local` provider:

```toml
# ~/.codex/ollama-gemma.config.toml
model = "gemma4:26b"
model_provider = "ollama-local"
```

```bash
codex --profile ollama-local       # local qwen3-coder (loads ollama-local.config.toml)
codex --profile ollama-gemma       # local gemma4:26b  (loads ollama-gemma.config.toml)
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

To switch Goose's model, edit the single `model:` line in `config.yaml`
(e.g. `model: gemma4:26b`) — Goose has no env-var override here, the value is
read straight from the file.

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

`mcp_localllm.py` exposes the **active local model** as two stdio MCP tools. It
is model-agnostic: it auto-detects whichever model Ollama currently has loaded
(`/api/ps`, falling back to the first installed model from `/api/tags`) and
adapts to that model's capabilities (`/api/show`). For **thinking-capable**
models (e.g. `gemma4`) it sets `think: false` on the native `/api/chat` call so
the answer lands in `content` instead of being consumed by chain-of-thought
under the output-token budget; non-thinking models (e.g. `qwen3-coder`) are
called plainly. Only the Python standard library is used (no OpenAI SDK).

Overrides: `OLLAMA_HOST` (default `http://localhost:11434`), `LOCALLLM_MODEL_ID`
(pin a specific model instead of auto-detecting), `LOCALLLM_MAX_TOKENS`
(default `2048`), `LOCALLLM_TEMPERATURE` (default `0.2`). Legacy `QWEN_MODEL_ID`
/ `QWEN_USAGE_LOG` are still honored for backward compatibility.

### Dependency

The server framework uses FastMCP, so the `mcp` package must be importable by
the **same `python3`** that the client launches. The Ollama calls themselves use
only the standard library; `mcp` is the one third-party requirement.

```bash
python3 -m pip install --user mcp        # once, for the python3 on PATH
python3 -c 'import mcp'                   # verify (no output = OK)
```

> If the client runs a different interpreter, registration connects but tool
> calls fail with `ModuleNotFoundError: No module named 'mcp'`. Install `mcp`
> for that interpreter (or register with its absolute `python3` path).

### Register

```bash
# Claude Code
claude mcp add -s user localllm python3 $REP/ollama/mcp_localllm.py

# Codex
codex mcp add localllm -- python3 $REP/ollama/mcp_localllm.py
```

Verify in Claude Code with `/mcp` (expect `localllm` connected) and call
`ask_local`.

### Available tools

| Tool                                 | Use for                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------- |
| `ask_local(prompt)`                | Prose: Q&A, explanations, summaries, translation, comment/docstring rewrites |
| `ask_local_code(language, prompt)` | Code: generation, refactoring, unit-test skeletons, stubs, code translation  |

### Token usage logging

Each call appends a JSONL record (timestamp, tool, model, token counts,
latency) to `usage.log` (override with `LOCALLLM_USAGE_LOG`). Summarize with:

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

| Tool                                 | Use for                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------- |
| `ask_local(prompt)`                | Prose: Q&A, explanations, summaries, translation, comment/docstring rewrites |
| `ask_local_code(language, prompt)` | Code: generation, refactoring, unit-test skeletons, stubs, code translation  |

**Routing rules**

1. **Pure Q&A / explanation / summary / translation** (good candidate)
   → call `ask_local(prompt=<full request>)`; return the response verbatim.
2. **Code generation / refactoring / unit tests** (formulaic, self-contained)
   → determine the language from context; call `ask_local_code(language=<lang>, prompt=<request + required context>)`; return verbatim.
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
User → Claude Code → MCP (stdio) → mcp_localllm.py → Ollama :11434 → active model
User → Codex       → MCP (stdio) → mcp_localllm.py → Ollama :11434 → active model
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

### Codex stop-review-gate delegation

The Codex stop-time review gate (see
[Tips: rg Process Lingering](#tips-codex-stop-review-gate-rg-process-lingering-issue))
is one concrete place where delegation is wired in. The gate runs from a **fixed
prompt template** — not text Claude generates per turn. Only the
`{{CLAUDE_RESPONSE_BLOCK}}` placeholder is substituted at runtime with the previous
Claude turn's output; the ALLOW/BLOCK contract and fast-path rules are hard-coded in
the template, which `stop-review-gate-hook.mjs` / `codex-companion.mjs` read and run.

To make the gate offload its review reasoning to Qwen (token savings) while Codex keeps
file I/O and the final ALLOW/BLOCK decision, add this **Qwen delegation block** to the
prompt template:

```text
When reviewing actual code changes and local Qwen MCP tools are available, delegate
the review reasoning to Qwen after gathering the relevant repository context locally.
Pass Qwen the concrete diff and relevant file snippets; do not ask Qwen to read paths
or use tools. Keep all file I/O, command execution, and final ALLOW/BLOCK decision in
Codex. If the previous turn did not make direct edits, return ALLOW immediately without
calling Qwen.
```

The block must be present in **both** prompt copies, because a plugin reinstall / cache
refresh overwrites the cache copy from the source copy:

| File                                                                                      | Purpose                                                                         |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `~/.claude/plugins/cache/openai-codex/codex/<ver>/prompts/stop-review-gate.md`          | Runtime prompt used for the stop-gate Codex task                                |
| `~/.claude/plugins/marketplaces/openai-codex/plugins/codex/prompts/stop-review-gate.md` | Source prompt to keep in sync so reinstall/cache refresh does not lose the rule |

The prompt-level rule is inert unless the `localllm` MCP server is also exposed to the
Codex session via `~/.codex/config.toml` (`[mcp_servers.localllm]`, pointing at
`$REP/ollama/mcp_localllm.py`). Verify both the block and the MCP wiring with:

```sh
grep -c delegate \
  ~/.claude/plugins/cache/openai-codex/codex/*/prompts/stop-review-gate.md \
  ~/.claude/plugins/marketplaces/openai-codex/plugins/codex/prompts/stop-review-gate.md
grep -n localllm ~/.codex/config.toml
```

After any Codex plugin reinstall, re-confirm the cache copy still carries the block.

### Token Limits

| Limit                    | Value                                         | Source                                                        |
| ------------------------ | --------------------------------------------- | ------------------------------------------------------------- |
| Output per call (client) | **≤ 2,048 tokens**                     | `mcp_localllm.py` `num_predict` (`LOCALLLM_MAX_TOKENS`) |
| Sampling temperature     | `0.2`                                       | `mcp_localllm.py` (`LOCALLLM_TEMPERATURE`)                |
| Context window           | `OLLAMA_CONTEXT_LENGTH` (64000 via wrapper) | server-side (per loaded model)                                |

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
