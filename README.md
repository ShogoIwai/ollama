# Local LLM Workflow — Ollama + Claude Code + Codex

`ollama/` provides a local LLM environment for Claude Code and Codex,
built on **Ollama**. The default local model is
**`qwen3.6:35b-a3b-mtp-q4_K_M`** (thinking-capable MoE, ~3B active), with its own
thin launcher (`start_ollama_qwen36_35b.sh`) sharing one core
(`_ollama_serve_common.sh`); additional models can be added with the procedure
below, each as one more 2-line launcher. The MCP
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
   Claude Code by env + alias, Codex by profile/alias. No client shares an
   `OPENAI_*` env var, so none can override another. The 5h-quota dynamic routing
   from `vllm/` (`proxy.py` / `quota_route.py` / `usage_route_hook.py` /
   `codex_quota_context.py`) is **not** ported here.

---

## Adding a new LLM

Standard procedure for evaluating and adopting a new local model. Each step is
cheap to undo, so run them in order and stop at step 6 if the model is not worth
keeping — only step 3 and step 7 leave anything in the tree.

> **Manual operator steps.** Pulling a tag (step 2) and restarting the daemon onto
> the new model (step 4) are **run by the operator by hand**, not by the agent —
> they are large downloads / a daemon swap that displaces the currently-loaded
> model. The agent prepares everything else (launcher, switch cases, overlay,
> README) and hands off these two commands for the operator to run. This is the
> standing convention for every new model.

### 1. Find the Ollama tag

Confirm the model exists in the Ollama registry and pick a quantization that fits
24 GB. Estimate weight memory first with the sizing formula in
[Models and memory requirements](#models-and-memory-requirements)
(`Params(B) × bits / 8 × 1.25`), then verify the exact tag/quant is published:

```bash
ollama show <tag>                         # prints params, quant, context if pullable
#   browse tags at https://ollama.com/library/<model>
```

Note the precise tag (e.g. `qwen3.6:35b-a3b-mtp-q4_K_M`, `deepseek-r1:32b`,
`mistral-small:24b`). A tag that does not resolve here will fail at step 2 — do
not guess; the registry is authoritative.

### 2. Pull the tag

```bash
ollama pull <tag>
ollama show <tag>                         # re-confirm quant/context after download
```

Watch disk: GGUF weights land in `~/.ollama/models` (or
`/usr/share/ollama/.ollama/models` under systemd — see the systemd note in
[Quick Start](#2-start-the-server)).

### 3. Create a launcher script for the tag

Copy the closest existing launcher and change only the `MODEL` tag. Every launcher
is a 2-line thin wrapper over `_ollama_serve_common.sh`; nothing else needs to
change.

```bash
cp start_ollama_qwen36_35b.sh start_ollama_<name>.sh
# edit: set MODEL="<tag>"  (override OLLAMA_CONTEXT_LENGTH here only if needed)
chmod +x start_ollama_<name>.sh
```

If you want a `claude --model` / `codex --profile` shortcut for it, also add:

- a `case`/`switch` arm in **both** `source_local` and `source_local.csh`
  mapping the tag → a Codex profile name (see
  [cloud / local static switching](#cloud--local-static-switching)), and
- the matching overlay file `~/.codex/<profile>.config.toml` with
  `model = "<tag>"` and `model_provider = "ollama-local"` (see [Codex](#codex)).

This is optional for a first smoke test — auto-detection from the marker already
makes `source_local` track the launched tag, and the MCP path needs no profile.

### 4. Restart the daemon on the new model

Only one daemon binds `:11434`, so stop the running launcher and start the new
one. The launcher records the tag in `~/.ollama_active_model`, which the MCP
server and `source_local` then auto-detect.

```bash
# stop the currently running launcher (Ctrl-C in its foreground, or kill the serve)
./start_ollama_<name>.sh
ollama ps                                 # confirm the model loaded; check CONTEXT + CPU/GPU split
```

A 100% GPU split with VRAM headroom is the goal; a large CPU share means the
weights+KV cache overflowed 24 GB — drop the quant or `OLLAMA_CONTEXT_LENGTH`.

### 5. Verify it works

Two integration paths — test whichever you intend to use:

- **MCP path** (always safe, text-in/text-out):
  ```bash
  # in Claude Code / Codex with the localllm MCP server registered:
  #   call ask_local("…")  /  ask_local_code("…")  and confirm a sane reply
  ```
- **Direct-connect agentic backend** (only if the model reports `tools`
  capability and emits structured tool calls):
  ```bash
  source ollama/source_local            # tcsh: source ollama/source_local.csh
  claude                                 # drive a small edit; confirm it reaches disk
  codex                                  # confirm a tool call executes
  ```

A model that emits tool calls as plain-text JSON in `content` (e.g. small Gemma)
is **MCP-only** — see the tool-calling caveat in
[WSL / low-memory (CPU)](#use-the-mcp-path-not-direct-connect). Note speed
(`tok/s`), resident VRAM, and whether tool calls land.

### 6. Adopt or drop

Decide against the measured numbers from step 5: does it fit 24 GB with usable
context, run fast enough, and (for direct connect) drive tool calls correctly? If
**no**, drop it — `ollama rm <tag>` reclaims the disk and delete the launcher;
nothing else was committed. If **yes**, continue to step 7.

### 7. Document it in the README

Record the adopted model so the next person does not re-derive it:

- add a row to [Models and memory requirements](#models-and-memory-requirements)
  (or the WSL table) with the **measured** VRAM / context / `tok/s`, not estimates;
- add the launcher to the [Directory Contents](#directory-contents) table and the
  [Quick Start](#2-start-the-server) launcher list;
- if you added a Codex profile in step 3, document the overlay file under
  [Codex](#codex).

Mark estimated vs measured numbers explicitly — the table's authority is that its
listed builds were actually run here.

---

## Removing a model (reclaim disk)

GGUF weights are large (a single 30B+ Q4 build is ~20–24 GB) and accumulate in
the model store, so prune tags you no longer serve. Deletion is the inverse of
[Adding a new LLM](#adding-a-new-llm): remove the on-disk weights, then the
launcher/profile scaffolding that pointed at them.

> **Agent-runnable (unlike adding a model).** Removal does not displace the loaded
> model or trigger a large download, so — unlike pulling (step 2) and the daemon
> swap (step 4) in *Adding a new LLM* — the agent may run `ollama rm` and the
> scaffolding cleanup directly. The **one** guard: never `rm` a tag the running
> daemon still has loaded (`ollama ps`); stop/switch the daemon off it first.

### 1. Check what is on disk and what is loaded

```bash
ollama list                               # all pulled tags + SIZE on disk
ollama ps                                 # what is loaded in memory right now
du -sh ~/.ollama/models                   # total store size (or /usr/share/ollama/.ollama/models under systemd)
```

Do **not** remove a tag that `ollama ps` shows loaded — stop/switch the daemon
off it first (see [Start the server](#2-start-the-server): only one daemon binds
`:11434`).

### 2. Remove the weights

```bash
ollama rm <tag>                           # deletes the GGUF blobs for that tag
ollama list                               # confirm it is gone and SIZE dropped
```

`ollama rm` is reference-counted on the underlying blobs: shared layers are kept
until the last tag referencing them is removed, so removing one of several
related quants frees only its unshared layers. If a copy made with `ollama cp`
(e.g. the `claude-3-5-sonnet` validation-bypass alias in
[Claude Code](#claude-code)) still points at the blobs, remove that copy too.

### 3. Remove the scaffolding

If the model had a dedicated launcher / Codex profile (steps 3 and 7 of *Adding a
new LLM* are the only ones that leave anything in the tree), delete those so the
README and switch logic stay truthful:

- delete the launcher `start_ollama_<name>.sh`;
- remove its `case`/`switch` arm from **both** `source_local` and
  `source_local.csh`, and delete the overlay `~/.codex/<profile>.config.toml`;
- drop its row from [Models and memory requirements](#models-and-memory-requirements),
  [Directory Contents](#directory-contents), and the
  [Quick Start](#2-start-the-server) launcher list.

Leaving a launcher whose tag has been `rm`'d is harmless (the common core
lazy-pulls it back on next start), but it re-downloads the weights you just
freed — so remove the launcher unless you intend to re-pull.

### 4. (Optional) clear the active-model marker

If you removed the tag recorded in `~/.ollama_active_model`, `source_local` would
still resolve the alias to a now-absent model until the next launcher run
rewrites the marker. Start another launcher (which overwrites it) or delete the
marker to fall back to the `qwen3.6:35b-a3b-mtp-q4_K_M` default.

---

## Directory Contents

| File                           | Role                                                                                                                                                     |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `up_version.csh`             | Reinstall Ollama to the latest release, stop/disable the systemd unit, and print the version (manual update helper)                                      |
| `start_ollama_qwen36_35b.sh` | Thin launcher for `qwen3.6:35b-a3b-mtp-q4_K_M` (default; Qwen3.6-35B-A3B MoE, ~3B active, thinking-capable; override `MODEL=qwen3.6:35b` for non-MTP) |
| `start_ollama_gemma3_wsl.sh` | Thin launcher for `gemma3:4b` on a WSL / GPU-less, low-memory host (CPU inference); caps context low (see [WSL / low-memory (CPU)](#wsl--low-memory-cpu)) |
| `_ollama_serve_common.sh`    | Shared core sourced by the launchers (daemon start, readiness wait, lazy pull); records the launched model in `~/.ollama_active_model`                 |
| `source_local` / `.csh`    | LOCAL mode: export Claude Code `ANTHROPIC_*` + alias `claude`/`codex` to local                                                                     |
| `source_cloud` / `.csh`    | CLOUD mode: unset those env vars and `unalias claude`/`codex`                                                                                        |
| `mcp_localllm.py`            | MCP server exposing the active local model as `ask_local` / `ask_local_code` tools (local-model debugging)                                           |
| `usage_report.py`            | Aggregate local LLM token usage from `usage.log`                                                                                                       |
| `usage.log`                  | JSONL usage records written by `mcp_localllm.py` (gitignored)                                                                                          |

---

## Quick Start

### 1. Install Ollama and pull the model

```bash
# Ollama runtime (Linux)
curl -fsSL https://ollama.com/install.sh | sh
ollama -v                 # confirm v0.14.0+ (needed for Anthropic /v1/messages)

ollama pull qwen3.6:35b-a3b-mtp-q4_K_M
ollama run qwen3.6:35b-a3b-mtp-q4_K_M      # optional REPL smoke test
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
./start_ollama_qwen36_35b.sh         # qwen3.6:35b-a3b-mtp-q4_K_M (default; override MODEL=qwen3.6:35b for non-MTP)
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
  `OLLAMA_CONTEXT_LENGTH` (default `96000`);
- if a daemon is already reachable, reports and exits 0 (does nothing);
- otherwise starts `ollama serve` in the background, waits for the API, pulls
  the selected `MODEL` if missing, then keeps the daemon in the foreground.

> Only one daemon binds `:11434`. To switch which model serves, stop the running
> launcher and start the other; the MCP server then auto-detects the newly
> loaded model. Run both side by side only if you give each its own
> `OLLAMA_HOST` port.

> **Context length:** Ollama's auto-picked default is too small for agent use —
> as low as 4K when VRAM < 24GB, and even a 24GB RTX 3090 only defaults to
> ~32768. So the wrapper sets `OLLAMA_CONTEXT_LENGTH=96000` (kept in sync with
> `CLAUDE_CODE_MAX_CONTEXT_TOKENS` in `source_local`). **This applies only
> to the `serve` launched by
> this script** — a daemon started elsewhere (systemd) keeps its own setting.
> Check the loaded context and CPU/GPU split with `ollama ps`.
>
> **VRAM caveat:** the measurements further down were taken at the current 96K
> default. The default model (`qwen3.6:35b-a3b` at 22 GB) leaves only ~650 MiB
> headroom on a 24 GB GPU, so under heavy load its q8_0 KV cache can spill to CPU
> (slower) or OOM. If `ollama ps`
> shows a CPU split, drop `OLLAMA_KV_CACHE_TYPE=q4_0` or lower `OLLAMA_CONTEXT_LENGTH`.

> **Hot standby (`OLLAMA_KEEP_ALIVE`):** by default Ollama unloads an idle model
> after ~5 min, so the next call pays the reload latency. To keep the model
> resident, set `OLLAMA_KEEP_ALIVE` where the daemon is launched (e.g.
> `OLLAMA_KEEP_ALIVE=2h`, or `-1` to never unload). Trade-off: the model holds
> VRAM/RAM while idle. Confirm the unload behaviour with `ollama ps` (the `UNTIL`
> column). The wrapper defaults this to `2h`; override the env to change it.

> **KV-cache quantization (`OLLAMA_KV_CACHE_TYPE`):** for long contexts the KV
> cache dominates VRAM. Setting `OLLAMA_KV_CACHE_TYPE=q8_0` (or `q4_0`) shrinks it
> at a small quality cost; Ollama's own default is `f16`. In Ollama this
> **requires `OLLAMA_FLASH_ATTENTION=1`** to take effect. The wrapper sets
> `OLLAMA_FLASH_ATTENTION=1` and defaults `OLLAMA_KV_CACHE_TYPE=q8_0` (≈half the
> KV VRAM of f16 with quality loss below the noise floor, which is what lets
> 30B+ models hold the 96K context in 24GB); override
> `OLLAMA_KV_CACHE_TYPE=f16` for lossless, or `q4_0` to quantize harder. Both are
> server-launch env vars (set them alongside the daemon, not on an
> already-running one). Verified present in the local Ollama (0.30.2).

---

## Models and memory requirements

`qwen3.6:35b-a3b-mtp-q4_K_M` (thinking-capable MoE, ~3B active) is the default
model on this 24 GB host (measured numbers below). For sizing a generic
30B-class model, the rough quant-vs-memory ladder is:

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

**Qwen3.6-35B-A3B (`qwen3.6:35b-a3b-mtp-q4_K_M`, measured).** Sparse MoE, 35B total
/ **~3B active**, thinking-capable + vision, native 256K context, Apache 2.0. Ollama
publishes the 35B only at q4_K_M (`qwen3.6:35b` 24GB) or the MTP build
(`…-mtp-q4_K_M` 23GB) — **no smaller q2/q3 quant**. **Measured on this host (RTX
3090 24GB):** with the wrapper's `OLLAMA_KV_CACHE_TYPE=q8_0` + flash attention it
loads at **100% GPU, 22 GB resident (23.9 GB VRAM used), 96000 context, ~87 tok/s
generation** (prompt ~233 tok/s) — the q8_0 KV cache is what lets the full 96K
context fit alongside the weights in 24 GB. The 3B-active MoE is what makes a 35B
model this fast. This is the **default** local model. Its ~3B active params are
the structural ceiling on heavy long-document / multi-step reasoning; lifting that
on a 24 GB host would need a **dense** 27–32B (cf. the dropped dense Qwen3.6-27B at
~38 tok/s below for the speed cost).
`/api/show` reports capabilities `['completion','vision','tools','thinking']`, so
it is a candidate **direct-connect** agentic backend (`tools`) and the MCP path
handles its `thinking` with `think:false` as usual — a full agentic tool-driving
loop has not yet been exercised end-to-end here.

> **Evaluated and dropped: Qwen3.6-27B (`qwen3.6:27b-mtp-q4_K_M`).** The **dense**
> 27B sibling (`architecture qwen35`, 27.3B params, no `a3b` MoE sparsity) was
> measured here at **100% GPU, 17 GB, 64000 context, ~38 tok/s** — ~3.7× slower
> than the 35b-a3b (it runs all 27.3B per token vs the MoE's ~3B) while offering
> less capacity and only marginally lower VRAM. The 35b-a3b dominates it on speed
> and capacity at once, so the 27b was **not adopted** and its weights/scaffolding
> were removed. Re-pull only if a specifically dense-27B behaviour is needed.

**Sizing a new model (rough estimate).** Before pulling, estimate weight memory as:

```
Memory(GB) ≈ Params(B) × Precision(bits) / 8 × α      (α ≈ 1.2–1.3 runtime buffer)
```

e.g. a 30B model at Q4 (~4.5 bits effective): `30 × 4.5 / 8 × 1.25 ≈ 21 GB` — plus
the **KV cache**, which grows with context length and is *not* in this figure (see
KV-cache quantization above). The measured quant table is authoritative for the
listed builds; use the formula only for first-pass sizing of new candidates.

**VRAM ↔ context length (measured + estimated).** The 4K auto-limit below 24 GB is
the only hard rule; usable context above it depends on weight size and offload:

| GPU VRAM | Practical context        | Notes                                                                                                       |
| -------- | ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| < 24 GB  | 4K (auto), raise w/ care | Ollama auto-limits to 4K; larger needs explicit override + RAM spill                                        |
| 24 GB    | up to ~96K               | **Measured** on RTX 3090 — per-model detail in the table below (all 100% GPU @ 96000, q8_0 KV cache) |
| 48 GB+   | 256K+ (estimate)         | Report-derived,**not measured** here; confirm with `ollama ps`                                      |

> The 24 GB row is measured on this host; other rows are estimates to be confirmed
> per environment via the `ollama ps` `CONTEXT` column and CPU/GPU split.

**Per-model measured values (RTX 3090, 24 GB).** `OLLAMA_KV_CACHE_TYPE=q8_0`; SIZE /
processor split from `ollama ps`, throughput from `/api/generate`
(`eval_count` ÷ `eval_duration`). Measured at the current wrapper
default of **96000**, **lightly loaded** (KV cache mostly empty — see caveat below):

| Model                          | Context | Processor | VRAM (SIZE) | Throughput |
| ------------------------------ | ------- | --------- | ----------- | ---------- |
| `qwen3.6:35b-a3b-mtp-q4_K_M` | 96000   | 100% GPU  | 22 GB (light load; 23.9/24 GB used) | ~87 tok/s |

> The reported SIZE reflects a near-empty KV cache because Ollama allocates KV
> lazily — at warm-up little of the 96K is in use. With only ~650 MiB VRAM headroom
> (23.9/24 GB), a task that fills toward 96K can grow the q8_0 KV past the ceiling
> and **drop to a CPU split** mid-run. If `ollama ps` shows the split degrade under load, restart with
> `OLLAMA_KV_CACHE_TYPE=q4_0` (halves KV VRAM) or lower `OLLAMA_CONTEXT_LENGTH`.

> The model has a **262144 (256K)** native context, but cannot use it on a
> 24 GB GPU: the figure above (qwen35b 22 GB) was measured at **96K**,
> already near the 24 GB ceiling — the wrapper default is **96000** (to give Claude
> Code agent runs more headroom). The q8_0 KV cache leaves only ~650 MiB headroom and
> **may spill to CPU** under heavy load, so re-check `ollama ps` after a restart and
> fall back to `OLLAMA_KV_CACHE_TYPE=q4_0` or a lower `OLLAMA_CONTEXT_LENGTH` if the
> split or throughput regresses. (SIZE in `ollama ps` does not grow linearly with the
> limit: Ollama allocates KV lazily, so VRAM only fills as context is used.)

---

## WSL / low-memory (CPU)

The model table above targets large GPU / workstation memory. A typical **WSL
host has no usable GPU budget and ~8 GB RAM** (`/dev/dri` exists via WSLg but VRAM
is negligible), so those builds will not load. For that environment, run a small
model **on CPU** instead.

**Default: `gemma3:4b`** (Google Gemma 3, Q4_K_M). Gemma ran better than Qwen on
the Linux workstation, and the 4B build fits an 8 GB host with headroom. Other
Google-family candidates that fit CPU inference:

| Model / tag             | Params | Resident (Q4)     | CPU tok/s     | Use for                          |
| ----------------------- | ------ | ----------------- | ------------- | -------------------------------- |
| `gemma3:1b`           | 1B     | ~0.8 GB           | fast          | ultra-light always-on completion |
| `gemma2:2b`           | 2B     | ~1.6 GB           | —            | light chat                       |
| `codegemma:2b`        | 2B     | ~1.6 GB           | —            | code completion (FIM-oriented)   |
| **`gemma3:4b`** | 4B     | **~2.9 GB** | **~12** | chat / edit / MCP debug          |

Measured on an 8 GB / 12-thread WSL host: `gemma3:4b` runs at **~11–12 tok/s**,
**~2.9 GB resident, VRAM 0.0 (pure CPU)**, context honored at the launcher's cap.

### Start

```bash
./start_ollama_gemma3_wsl.sh           # gemma3:4b, OLLAMA_CONTEXT_LENGTH=8192
#   MODEL=gemma3:1b ./start_ollama_gemma3_wsl.sh          # smaller model
#   OLLAMA_CONTEXT_LENGTH=4096 ./start_ollama_gemma3_wsl.sh   # tighter RAM
```

Unlike the GPU launchers (which default `OLLAMA_CONTEXT_LENGTH=96000`), the WSL
launcher defaults it to **8192**. On CPU with limited RAM, a 16K+ context grows
the KV cache to 3–4 GB and drives the host into swap (sub-1 tok/s); drop to
4096 if memory is tight. Both `MODEL` and `OLLAMA_CONTEXT_LENGTH` can be
overridden before running.

### Use the MCP path, not direct connect

On WSL the **safe integration is the [MCP path](#mcp-integration)**
(`ask_local` / `ask_local_code`) — text-in/text-out, which these small models
handle well, and which doubles as the local-model debug entry point. **Do not**
point Claude Code / Codex at the local server as a direct
agentic backend: `gemma3:4b` reports no `tools` capability, and when prompted for
a tool call it emits the call as **plain-text JSON in `content`**, not a
structured `tool_calls` block — the client cannot detect it and "hallucinates"
edits that never reach disk (the tool-calling conversion problem). Direct connect
would need an Anthropic-emulating gateway (Bifrost / LiteLLM) plus attribution-header
suppression; the MCP path avoids all of that. `gemma3` is also not
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

| File                        | Mode          | Effect                                                                                                                                                                                           |
| --------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `source_local` / `.csh` | LOCAL(Ollama) | export `ANTHROPIC_BASE_URL=:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, `OLLAMA_HOST`, `DISABLE_COMPACT=1`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=96000` (see [Context window](#context-window-in-local-mode)); alias `claude`/`codex` to local (see [Aliases](#aliases-set-by-source_local)) |
| `source_cloud` / `.csh` | CLOUD         | unset the above (tcsh `unsetenv`) and `unalias claude` / `codex`; re-set `ANTHROPIC_API_KEY` if you authenticate by key                                                                  |

### Context window in LOCAL mode

Claude Code resolves its context window — and thus the auto-compact trigger —
from a **built-in per-model table keyed on the model name** (bundle fn `k87`):
`[1m]` tags and `opus-4-8`/`fable-5` etc. get 1M, and **everything it doesn't
recognize falls back to 200000**. The Ollama tags (`qwen3.6:*`)
are unknown, so Claude Code thinks it has 200K and **never auto-compacts before
Ollama's real window** (`OLLAMA_CONTEXT_LENGTH`, default 96000) silently truncates
the oldest tokens — the model quietly loses early context with no error.

There is **no clean way to keep auto-compact and fire it at the real window**: the
only override env, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, is honored **only when
`DISABLE_COMPACT` is set** (bundle fn `v87`). So `source_local` makes the
deliberate trade-off:

- `DISABLE_COMPACT=1` — turns auto-compact off, and
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS=96000` — makes the `/context` gauge and the
  "approaching limit" warning reflect the **real window** (kept equal to
  `OLLAMA_CONTEXT_LENGTH`; change both together).

Net effect: **you compact manually** (`/compact` or `/clear`) when the honest
gauge says you're near the limit, instead of being silently truncated. If you
raise the Ollama window, set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the new value
**before** sourcing. `source_cloud` unsets both, so cloud mode is unaffected.
The MCP path (`ask_local` / `ask_local_code`) is one request per call and never
accumulates a conversation, so none of this applies there.

### Aliases set by `source_local`

`source_local` defines two shell aliases so plain `claude` / `codex` run in
local mode without typing flags; `source_cloud` removes them again. The model
each alias selects is **no longer hard-coded** — it is **auto-detected from the
running launcher** and can still be overridden by two env vars you set **before**
sourcing:

| Env var (override before sourcing) | Default                              | Controls                                          |
| ---------------------------------- | ------------------------------------ | ------------------------------------------------- |
| `LOCALLLM_MODEL`                 | auto (marker → else `qwen3.6:35b-a3b-mtp-q4_K_M`) | the model tag pinned by the `claude` alias      |
| `LOCALLLM_CODEX_PROFILE`         | derived from `LOCALLLM_MODEL`      | the Codex profile selected by the `codex` alias |

**Auto-detection (marker file).** Each start script records the launched model
tag in `~/.ollama_active_model` (written by `_ollama_serve_common.sh` as soon as
`MODEL` is known, so it applies on every path including the already-running
early-exit). When `source_local` runs and `LOCALLLM_MODEL` is unset, it reads
that marker — so sourcing automatically tracks whichever model you started, with
no manual edits. If the marker is missing it falls back to
`qwen3.6:35b-a3b-mtp-q4_K_M`. An
explicit `setenv`/`export LOCALLLM_MODEL` before sourcing always wins.

`LOCALLLM_CODEX_PROFILE`, when unset, is **derived from `LOCALLLM_MODEL`** via a
`switch` in `source_local.csh`: `qwen3.6:*` ⇒ `ollama-qwen36-35b`, everything else ⇒
`ollama-local`. (Each model gets its own explicit case, so an unlisted variant
defaults to `ollama-local`.) Add one
`case` + a matching overlay file per new local model.
(`ollama ps` is *not* used for detection: it only lists models already loaded
into memory on demand, so it is empty right after `ollama serve` starts.)

```bash
# auto: start a model, then just source — both clients follow it
./start_ollama_qwen36_35b.sh               # writes marker = qwen3.6:35b-a3b-mtp-q4_K_M
source ollama/source_local                 # tcsh: source ollama/source_local.csh
#   → claude --model qwen3.6:35b-a3b-mtp-q4_K_M, codex --profile ollama-qwen36-35b

# manual override still works (wins over the marker)
export LOCALLLM_MODEL=qwen3.6:35b          # tcsh: setenv LOCALLLM_MODEL qwen3.6:35b
source ollama/source_local                 # claude alias → claude --model qwen3.6:35b
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

> **Direct connect:** unlike `gemma3:4b` on WSL (which
> can only go through the MCP path — see [WSL / low-memory (CPU)](#wsl--low-memory-cpu)),
> `qwen3.6:35b-a3b-mtp-q4_K_M` reports the `tools` capability and is a candidate
> **direct-connect agentic backend for both Claude Code
> and Codex** on the 24 GB host: `./start_ollama_qwen36_35b.sh` then
> `source ollama/source_local` (claude → `--model qwen3.6:35b-a3b-mtp-q4_K_M`, codex →
> `--profile ollama-qwen36-35b`).

### Claude Code

```bash
# local
source ollama/source_local         # tcsh: source ollama/source_local.csh
claude                             # alias → claude --model $LOCALLLM_MODEL (default qwen3.6:35b-a3b-mtp-q4_K_M)
# (optional) alias to bypass model-name validation:
#   ollama cp qwen3.6:35b-a3b-mtp-q4_K_M claude-3-5-sonnet

# cloud
source ollama/source_cloud         # tcsh: source ollama/source_cloud.csh
claude                             # alias cleared → cloud default
```

### Codex

`source_local` aliases `codex` → `codex --profile $LOCALLLM_CODEX_PROFILE`;
`source_cloud` clears it so `codex` is cloud again. You can still invoke either
explicitly (`codex --profile ollama-local` / `codex`) regardless of which file is
sourced. By default `LOCALLLM_CODEX_PROFILE` is **auto-derived from the detected
`LOCALLLM_MODEL`** (see the auto-detection note above): `qwen3.6:*` ⇒
`ollama-qwen36-35b`, otherwise ⇒ `ollama-local` (one
explicit case per model). To force a specific profile, set
`LOCALLLM_CODEX_PROFILE` before sourcing — Codex picks the model per profile
(overlay file), not per env var, so each profile needs its own overlay file
(e.g. `ollama-qwen36-35b` ⇒ `~/.codex/ollama-qwen36-35b.config.toml` with
`model = "qwen3.6:35b-a3b-mtp-q4_K_M"`).

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
model = "qwen3.6:35b-a3b-mtp-q4_K_M"
model_provider = "ollama-local"
model_context_window = 96000
model_auto_compact_token_limit = 86000
```

Add one overlay file per local model you want a `codex --profile` for; they all
reuse the single shared `ollama-local` provider:

```toml
# ~/.codex/ollama-qwen36-35b.config.toml
model = "qwen3.6:35b-a3b-mtp-q4_K_M"
model_provider = "ollama-local"
model_context_window = 96000
model_auto_compact_token_limit = 86000
```

`model_context_window` tells Codex the local model's real usable window, and
`model_auto_compact_token_limit` makes Codex compact before the transcript can
run into Ollama's 96K server-side limit. Keep `model_context_window` equal to
`OLLAMA_CONTEXT_LENGTH`; keep the compact limit lower than that so there is
headroom for the next prompt, tool results, and model output. The local profiles
use **86K** as the first-pass trigger for a **96K** Ollama daemon.

```bash
codex --profile ollama-local       # local qwen3.6:35b-a3b (loads ollama-local.config.toml)
codex --profile ollama-qwen36-35b  # local qwen3.6:35b-a3b (loads ollama-qwen36-35b.config.toml)
codex                              # cloud (default profile)
```

---

## MCP Integration

> **Scope:** the MCP server is positioned as a **local-model debugging /
> inspection path** — a quick text-in/text-out way to exercise whichever model
> Ollama has loaded from inside Claude Code / Codex. It is **not** a token-saving
> delegation layer; the cloud-vs-local decision is made up front by static
> switching (see [cloud / local static switching](#cloud--local-static-switching)),
> per whole task, not per subtask.

`mcp_localllm.py` exposes the **active local model** as two stdio MCP tools. It
is model-agnostic: it auto-detects whichever model Ollama currently has loaded
(`/api/ps`, falling back to the first installed model from `/api/tags`) and
adapts to that model's capabilities (`/api/show`). For **thinking-capable**
models (e.g. `qwen3.6:35b-a3b`) it sets `think: false` on the native `/api/chat` call so
the answer lands in `content` instead of being consumed by chain-of-thought
under the output-token budget; non-thinking models are called plainly. Only the
Python standard library is used (no OpenAI SDK).

Overrides: `OLLAMA_HOST` (default `http://localhost:11434`), `LOCALLLM_MODEL_ID`
(pin a specific model instead of auto-detecting), `LOCALLLM_MAX_TOKENS`
(default `2048`), `LOCALLLM_TEMPERATURE` (default `0.2`), `LOCALLLM_TOP_P` /
`LOCALLLM_TOP_K` (unset → Ollama defaults; forwarded only when set). Legacy
`QWEN_MODEL_ID` / `QWEN_USAGE_LOG` are still honored for backward compatibility.

> **Multi-turn / thinking accumulation:** the MCP tools are **single-shot** —
> each `ask_local` / `ask_local_code` call sends only a fresh system+user pair
> with no prior turns, and thinking-capable models run with `think: false`. So
> no chain-of-thought is retained or replayed across calls; there is nothing to
> cleanse on this path. (The separate **direct-connect** path,
> `claude --model qwen3.6:35b-a3b-mtp-q4_K_M`, is a real multi-turn conversation; whether reasoning
> blocks accumulate in history there is the client/Ollama template's
> responsibility and is **not handled or verified** in this environment.)

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

### Token limits and sampling

| Limit                | Value                                         | Source                                                        |
| -------------------- | --------------------------------------------- | ------------------------------------------------------------- |
| Output per call      | **≤ 2,048 tokens**                     | `mcp_localllm.py` `num_predict` (`LOCALLLM_MAX_TOKENS`) |
| Sampling temperature | `0.2`                                       | `mcp_localllm.py` (`LOCALLLM_TEMPERATURE`)                |
| Context window       | `OLLAMA_CONTEXT_LENGTH` (96000 via wrapper) | server-side (per loaded model)                                |

`OLLAMA_CONTEXT_LENGTH` is the **combined** input+output budget per loaded
model. The `2,048` figure is the per-call **output** limit set by the MCP server.
Pack as much relevant context as the task needs up to the context window; split
into multiple calls only when the input exceeds it, or when the expected answer
exceeds the 2,048-token output limit.

> **Model-specific sampling (Gemma):** Gemma-family models are tuned for
> `temperature≈1.0, top_p=0.95, top_k=64`, unlike the conservative `0.2` default.
> The MCP server forwards `LOCALLLM_TEMPERATURE`,
> `LOCALLLM_TOP_P`, and `LOCALLLM_TOP_K` to `/api/chat` `options`. `top_p`/`top_k`
> are sent only when set, so non-Gemma models keep Ollama defaults unless you opt in.
> For `gemma3:*` (the WSL/CPU model) via MCP, e.g.
> `LOCALLLM_TEMPERATURE=1.0 LOCALLLM_TOP_P=0.95 LOCALLLM_TOP_K=64`.

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
diff rather than scanning the whole tree. This general rule is documented in
`~/.claude/CLAUDE.md` (Claude Code), `~/.codex/AGENTS.md` (Codex), and — so the
gate's own Codex run also honours it — in the stop-review-gate prompt template
itself via a `<git_scope_rules>` block (keep both prompt copies in sync; see the
table in the *Alternative* section below). The `Stop` hook below remains as a
belt-and-suspenders cleanup for any `rg` that still leaks.

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

### Default: run the stop-gate review on the cloud model (accuracy check for closed local work)

The point of running the Claude Code / Codex harness **directly on the local
(open-weight) model** is token saving and keeping the work **closed** — nothing
leaves the host (see [cloud / local static switching](#cloud--local-static-switching)).
The `localllm` MCP server is *not* this path: it is a debugging / inspection tool
only, so the real token-saving + closed-information win comes from the **direct
harness execution** on the local model, not from delegating subtasks over MCP. The
cost of that win is accuracy: a 26–35B local model reasons less reliably than the
cloud model.

**Policy: let the local model do the closed, cheap work, and let the *review* run
on the cloud model.** The stop-review-gate is where that trade-off is rebalanced —
the diff is handed to the high-accuracy cloud model for the ALLOW/BLOCK check. You
**barter away closure for the review portion only** (just the diff is exposed to
the cloud), in exchange for a trustworthy accuracy gate over work the open-weight
local model produced. The bulk of the context — full repo, intermediate reasoning —
never leaves the host; only the final diff is reviewed in the cloud.

This is the **default** and needs no prompt edit: the stop-review-gate hook spawns
Codex, and Codex shares no `OPENAI_*` env with the local switch (see
[cloud / local static switching](#cloud--local-static-switching)), so the gate's
review **already runs on the cloud** even while Claude Code itself runs on the local
model. To be sure the gate is *not* accidentally pinned to local:

- do **not** source / pass a Codex local profile (`codex --profile ollama-*`) in
  the shell that launches the gate, and
- do **not** add the local-routing block from the *Alternative* below to the prompt
  template (if it is already there, remove it to restore the cloud review).

```sh
grep -n localllm ~/.codex/config.toml         # for the gate: absent / commented = cloud review
ollama ps                                      # local model serves the worker, not the review gate
```

### Alternative: full closure — route the review to the local model too

Use this **only** when the work is sensitive enough that **even the diff must not
reach the cloud**. It gives up the cloud accuracy check above and runs the review
reasoning on the local model as well, keeping everything closed.

The Codex stop-time review gate runs from a **fixed prompt template** — not text
Claude generates per turn. Only the `{{CLAUDE_RESPONSE_BLOCK}}` placeholder is
substituted at runtime with the previous Claude turn's output; the ALLOW/BLOCK
contract and fast-path rules are hard-coded in the template, which
`stop-review-gate-hook.mjs` / `codex-companion.mjs` read and run.

To force the gate's review reasoning onto the **local model** (so Codex keeps file
I/O and the final ALLOW/BLOCK decision but nothing — not even the diff — leaves the
host), add this block to the prompt template:

```text
When reviewing actual code changes and local LLM MCP tools are available, run
the review reasoning on the local model after gathering the relevant repository
context locally. Pass it the concrete diff and relevant file snippets; do not ask
it to read paths or use tools. Keep all file I/O, command execution, and the final
ALLOW/BLOCK decision in Codex. If the previous turn did not make direct edits,
return ALLOW immediately without calling the local model.
```

The block must be present in **both** prompt copies, because a plugin reinstall /
cache refresh overwrites the cache copy from the source copy:

| File                                                                                      | Purpose                                                                         |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `~/.claude/plugins/cache/openai-codex/codex/<ver>/prompts/stop-review-gate.md`          | Runtime prompt used for the stop-gate Codex task                                |
| `~/.claude/plugins/marketplaces/openai-codex/plugins/codex/prompts/stop-review-gate.md` | Source prompt to keep in sync so reinstall/cache refresh does not lose the rule |

The prompt-level rule is inert unless the `localllm` MCP server is also exposed to
the Codex session via `~/.codex/config.toml` (`[mcp_servers.localllm]`, pointing at
`$REP/ollama/mcp_localllm.py`). Verify both the block and the MCP wiring with:

```sh
grep -c "local model" \
  ~/.claude/plugins/cache/openai-codex/codex/*/prompts/stop-review-gate.md \
  ~/.claude/plugins/marketplaces/openai-codex/plugins/codex/prompts/stop-review-gate.md
grep -n localllm ~/.codex/config.toml
```

After any Codex plugin reinstall, re-confirm the cache copy still carries the block.

### Other TIPS options: cloud review without GitHub

The Codex stop-review-gate is **one** way to put a cloud-side accuracy check over
closed local work; it is not the only one. **The constraint here is workflow:** this
repo commits locally and pushes to an **on-prem remote — no GitHub PRs**. So
marketplace review plugins built around `gh` / GitHub PRs (`code-review`,
`pr-review-toolkit`, `coderabbit`, …) **do not fit** and were dropped after a trial
(`code-review` needs `gh pr ...` and an open PR). Only **GitHub-independent**,
local-diff-based options belong here:

| Option                               | GitHub | What it reviews                                                                                                                                         |
| ------------------------------------ | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **stop-review-gate** (above)   | none   | Each turn's edit diff → cloud Codex ALLOW/BLOCK. The default; always on, no extra install                                                              |
| **`/code-review ultra`**     | none   | No-arg form bundles the local branch for a cloud multi-agent review; needs no GitHub remote (user-triggered, billed — cannot be launched by the agent) |
| **direct `git diff` review** | none   | Hand `git diff main...HEAD` (or any range) straight to the cloud model for an inline review — fully independent of any remote                        |

All three run the review on the cloud model, so they keep the same barter — closed,
cheap local work; cloud-side accuracy check on the result — **without** depending on
GitHub. They are **additive** to the stop-review-gate, not a replacement for the
rg-cleanup `Stop` hook above (still needed regardless of who runs the review).
