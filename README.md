Code: generation, refactoring, unit-test skeletons, stubs, code translation

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

| File                                         | Role                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `up_version.csh`                           | Reinstall Ollama to the latest release, stop/disable the systemd unit, and print the version (manual update helper)                                                                                                                                                                                                                                                                     |
| `start_ollama_qwen36_35b.sh`               | Thin launcher for `qwen3.6:35b-a3b-mtp-q4_K_M` (default; Qwen3.6-35B-A3B MoE, ~3B active, thinking-capable; override `MODEL=qwen3.6:35b` for non-MTP)                                                                                                                                                                                                                               |
| `start_ollama_qwen36_uncensored_vision.sh` | Thin launcher for `fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4` (optional; uncensored derivative of the default that **keeps vision** — handles image/PDF input; ~125 tok/s, Codex profile `ollama-qwen36-uncensored-vision`)                                                                                                                            |
| `start_ollama_lfm25_wsl.sh`                | Thin launcher for `LiquidAI/lfm2.5-1.2b-instruct:q4_k_m` on a WSL / GPU-less host (CPU; default WSL model); **tool-capable** (structured `tool_calls`), so it can drive direct connect (see [WSL / low-memory (CPU)](#wsl--low-memory-cpu))                                                                                                                                      |
| `_ollama_serve_common.sh`                  | Shared core sourced by the launchers (daemon start, readiness wait, lazy pull); records the launched model in `~/.ollama_active_model`                                                                                                                                                                                                                                                |
| `source_local` / `.csh`                  | LOCAL mode: export Claude Code `ANTHROPIC_*` + alias `claude`/`codex` to local                                                                                                                                                                                                                                                                                                    |
| `source_cloud` / `.csh`                  | CLOUD mode: unset those env vars and `unalias claude`/`codex`                                                                                                                                                                                                                                                                                                                       |
| `mcp_codex.py`                             | MCP server that forks a task from Claude Code into a one-shot Codex (GPT-5.5) run pinned to a single repo as its sandbox (`fork_to_codex` / `ask_codex`), and the host's external-access path: `web_rag` (live web search) + `notion_page` (create/update Notion pages via the Notion MCP) — see [Codex task fork via MCP](#codex-task-fork-via-mcp-each-repo-as-its-own-sandbox) |
| `mcp_localllm.py`                          | MCP server exposing the active local model as `ask_local` / `ask_local_code` tools (**deprecated**; register on demand for local-model debugging only)                                                                                                                                                                                                                        |
| `usage_report.py`                          | Aggregate local LLM**and** Codex usage from `usage_localllm.log` + `usage_codex.log`                                                                                                                                                                                                                                                                                          |
| `usage_codex.log`                          | JSONL usage records written by `mcp_codex.py` (gitignored)                                                                                                                                                                                                                                                                                                                            |
| `usage_localllm.log`                       | JSONL usage records written by `mcp_localllm.py` (gitignored)                                                                                                                                                                                                                                                                                                                         |

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
./start_ollama_qwen36_uncensored_vision.sh  # fredrezones55/Qwen3.6-...-HauhauCS-Aggressive:Q4 (optional; uncensored + vision for image/PDF)
./start_ollama_lfm25_wsl.sh          # LiquidAI/lfm2.5-1.2b-instruct on WSL / GPU-less CPU host (tool-capable)
```

For a WSL / GPU-less, low-memory host, use `start_ollama_lfm25_wsl.sh`. It
differs from the GPU launchers in one way — it caps the context window lower (32K
vs 96K) so the KV cache cannot blow past RAM on CPU. See
[WSL / low-memory (CPU)](#wsl--low-memory-cpu).

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

**Qwen3.6-35B-A3B Uncensored + Vision (`fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4`,
measured — adopted).** The **optional uncensored launcher** (the official
Apache-2.0 build remains the default). An uncensored community derivative of the
default (same `qwen35moe` architecture, ~3B active, native 256K context) that
drops the content-refusal/judgement layer **but keeps the vision tower**
(projector / mmproj bundled in the tag, ~899MB), so it can load images and PDF
pages. It **replaced** an earlier text-only uncensored build
(`joe-speedboat/...-Uncensored-Text`, since removed) that could not handle
PDF/image input. `Q4` ≈ 22GB weights. **Measured on this host (RTX 3090 24GB)**
with the shared wrapper settings (`OLLAMA_KV_CACHE_TYPE=q8_0` + flash attention):
`/api/show` capabilities `['completion','vision','tools','thinking']` (**vision
present** — projector is bundled), **100% GPU, 22 GB resident, 96000 context,
~125 tok/s** generation, and a `/api/chat` tool-call smoke test returned a
**structured `tool_calls` block with empty `content`** (`think:false`, no thinking
leak); **both Claude Code and Codex were confirmed running on it via direct
connect**. Caveats: it is a **non-official derivative** (weaker
provenance/reproducibility than the Apache-2.0 default), and uncensored sampling
defaults tend to be aggressive — the MCP path overrides temperature via
`LOCALLLM_TEMPERATURE=0.2`, but direct connect inherits the bundled defaults.
Re-verify after any re-pull that capabilities still include `vision` (if the tag
ever ships without the bundled projector, PDF/image silently breaks):

```sh
ollama pull fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4
curl -s http://127.0.0.1:11434/api/show \
  -d '{"model":"fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4"}' \
  | python3 -c 'import sys,json;print("capabilities:",json.load(sys.stdin).get("capabilities"))'
# expect: capabilities: ['completion', 'vision', 'tools', 'thinking']
```

Being vision-capable it resides ~22 GB on the RTX 3090 (comparable to the official
default), so watch KV-cache headroom under heavy context.
Launch with `./start_ollama_qwen36_uncensored_vision.sh` (Codex profile
`ollama-qwen36-uncensored-vision`, overlay `~/.codex/ollama-qwen36-uncensored-vision.config.toml`).

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

| Model                                                               | Context | Processor | VRAM (SIZE)                         | Throughput |
| ------------------------------------------------------------------- | ------- | --------- | ----------------------------------- | ---------- |
| `qwen3.6:35b-a3b-mtp-q4_K_M`                                      | 96000   | 100% GPU  | 22 GB (light load; 23.9/24 GB used) | ~87 tok/s  |
| `fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4` | 96000   | 100% GPU  | 22 GB (vision-capable)              | ~125 tok/s |

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

**Default: `LiquidAI/lfm2.5-1.2b-instruct:q4_k_m`** (LiquidAI LFM2.5, hybrid
1.17B). Chosen over the former gemma3:4b default because it is **tool-capable**:
it **emits a structured `tool_calls` block** (not plain-text JSON in `content`),
so unlike gemma3 it can drive **direct connect** on WSL, not just the MCP path.
Being a *hybrid* model (only 6 attention layers of 16) its KV cache stays small,
so it holds its full **32K** native window on this 8 GB host. **Measured on the
8 GB / 12-thread WSL host** (`start_ollama_lfm25_wsl.sh`, q4_k_m): `/api/show`
capabilities `['tools','thinking','completion']`; **~0.9 GB resident, 100% CPU,
~40 tok/s**; a `get_weather` tool-call test returned a proper structured
`tool_calls` (empty `content`), and a plain `think:false` chat returned clean
`content` with no thinking leak (MCP path safe).

> Pick the **`-instruct`** build, **not** `lfm2.5-thinking`, which Ollama
> publishes text-only / without tool support. Other small CPU-fit candidates
> (gemma3:1b/4b, gemma2:2b, codegemma:2b) work via the MCP path but report no
> `tools` capability, so they cannot drive direct connect — hence the switch.

| Model / tag                                        | Params | Resident (Q4)     | CPU tok/s     | tool_calls | Use for                                                |
| -------------------------------------------------- | ------ | ----------------- | ------------- | ---------- | ------------------------------------------------------ |
| **`LiquidAI/lfm2.5-1.2b-instruct:q4_k_m`** | 1.17B  | **~0.9 GB** | **~40** | structured | **WSL direct-connect tool use**, chat, MCP debug |

> **Direct connect is enabled but limited by model size.** Both clients launch
> and Claude Code accepts a prompt, but a 1.2B model under Claude Code's ~23K-token
> system prompt is weak in practice; the realistic main use on WSL is the **MCP
> path** (`ask_local`) and light **Codex** tool tasks. Claude Code direct connect
> needs `OLLAMA_CONTEXT_LENGTH` ≥ ~32K just to fit the system prompt (the launcher
> defaults to 32768 for this reason); set `CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768`
> before sourcing so the gauge matches the real window.

### Start

```bash
./start_ollama_lfm25_wsl.sh            # LiquidAI/lfm2.5-1.2b-instruct:q4_k_m, ctx 32768
#   OLLAMA_CONTEXT_LENGTH=8192 ./start_ollama_lfm25_wsl.sh    # tighter RAM / MCP-only
#   MODEL=LiquidAI/lfm2.5-1.2b-instruct:q8_0 ./start_ollama_lfm25_wsl.sh   # ~1.2GB
```

Unlike the GPU launchers (which default `OLLAMA_CONTEXT_LENGTH=96000`), the WSL
launcher defaults it to **32768** — the model's native ceiling, needed so Claude
Code's ~23K-token system prompt fits on direct connect. LFM2.5's hybrid design
keeps the KV cache small enough to hold 32K on this 8 GB host; drop to 8192 if
RAM is tight (MCP-only / small tasks then). Both `MODEL` and
`OLLAMA_CONTEXT_LENGTH` can be overridden before running.

### Integration: MCP path (primary) + limited direct connect

On WSL the **always-safe integration is the [MCP path](#mcp-integration)**
(`ask_local` / `ask_local_code`) — text-in/text-out, which small models handle
well, and which doubles as the local-model debug entry point. With the default
`lfm2.5-1.2b-instruct`, **direct connect also works** (it reports `tools` and
emits a structured `tool_calls` block), so Claude Code / Codex can in principle
drive edits — but a 1.2B model is weak under their large system prompts, so treat
direct connect as "runs, lightly usable" and keep the MCP path as the main use.

> **Tool-calling conversion caveat (for other WSL models).** A model that does
> **not** report `tools` and emits the call as **plain-text JSON in `content`**
> (e.g. the former gemma3:4b default) is **MCP-only**: the client cannot detect
> the call and "hallucinates" edits that never reach disk. Such models would need
> an Anthropic-emulating gateway (Bifrost / LiteLLM) plus attribution-header
> suppression for direct connect; the MCP path avoids all of that. This is the
> exact failure lfm2.5's structured `tool_calls` avoids — verify it with the
> `/api/show` capabilities + a tool-call smoke test before adopting any new WSL
> model for direct connect.

---

## cloud / local static switching

Switching is done by sourcing one of two env files. There is no dynamic
routing. A freshly opened shell is already in cloud mode; `source_local`
exports the Ollama overrides, and `source_cloud` unsets them to return to cloud
within the same shell.

The env files toggle **Claude Code only** (`ANTHROPIC_*`). They deliberately
do **not** touch any `OPENAI_*` variable — Codex's cloud OpenAI client reads
those too, so exporting them would silently redirect Codex to the local server.

| File                        | Mode          | Effect                                                                                                                                                                                                                                                                                                               |
| --------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_local` / `.csh` | LOCAL(Ollama) | export `ANTHROPIC_BASE_URL=:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, `OLLAMA_HOST`, `DISABLE_COMPACT=1`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=96000` (see [Context window](#context-window-in-local-mode)); alias `claude`/`codex` to local (see [Aliases](#aliases-set-by-source_local)) |
| `source_cloud` / `.csh` | CLOUD         | unset the above (tcsh `unsetenv`) and `unalias claude` / `codex`; re-set `ANTHROPIC_API_KEY` if you authenticate by key                                                                                                                                                                                      |

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

| Env var (override before sourcing) | Default                                              | Controls                                          |
| ---------------------------------- | ---------------------------------------------------- | ------------------------------------------------- |
| `LOCALLLM_MODEL`                 | auto (marker → else `qwen3.6:35b-a3b-mtp-q4_K_M`) | the model tag pinned by the `claude` alias      |
| `LOCALLLM_CODEX_PROFILE`         | derived from `LOCALLLM_MODEL`                      | the Codex profile selected by the `codex` alias |

**Auto-detection (marker file).** Each start script records the launched model
tag in `~/.ollama_active_model` (written by `_ollama_serve_common.sh` as soon as
`MODEL` is known, so it applies on every path including the already-running
early-exit). When `source_local` runs and `LOCALLLM_MODEL` is unset, it reads
that marker — so sourcing automatically tracks whichever model you started, with
no manual edits. If the marker is missing it falls back to
`qwen3.6:35b-a3b-mtp-q4_K_M`. An
explicit `setenv`/`export LOCALLLM_MODEL` before sourcing always wins.

`LOCALLLM_CODEX_PROFILE`, when unset, is **derived from `LOCALLLM_MODEL`** via a
`switch` in `source_local.csh`:
`fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:*` ⇒
`ollama-qwen36-uncensored-vision`, `qwen3.6:*` ⇒ `ollama-qwen36-35b`, everything else ⇒
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

> **Direct connect:** the WSL default `LiquidAI/lfm2.5-1.2b-instruct` also reports
> `tools` and emits structured `tool_calls`, so it can drive direct connect too —
> just weakly, being 1.2B (see [WSL / low-memory (CPU)](#wsl--low-memory-cpu)). On
> the 24 GB host, `qwen3.6:35b-a3b-mtp-q4_K_M` reports the `tools` capability and is a candidate
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
`LOCALLLM_MODEL`** (see the auto-detection note above):
`fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:*` ⇒ `ollama-qwen36-uncensored-vision`,
`qwen3.6:*` ⇒ `ollama-qwen36-35b`, otherwise ⇒ `ollama-local` (one
explicit case per model). To force a specific profile, set
`LOCALLLM_CODEX_PROFILE` before sourcing — Codex picks the model per profile
(overlay file), not per env var, so each profile needs its own overlay file
(e.g. `ollama-qwen36-35b` ⇒ `~/.codex/ollama-qwen36-35b.config.toml` with
`model = "qwen3.6:35b-a3b-mtp-q4_K_M"`).

> **Resume picker caveat:** cloud (default) and local (separate profile) Codex
> runs do **not** share the same `/resume` list. Sessions started with the cloud
> default provider and sessions started with a local profile (`ollama-local`
> etc.) appear in separate resume listings, and `codex resume --all` does not
> merge them either. In current Codex there is no way to make a local-profile run
> show up in the cloud-default resume list (or vice versa).

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

Another overlay reuses the same provider for the uncensored + vision variant
(only the `model` line differs):

```toml
# ~/.codex/ollama-qwen36-uncensored-vision.config.toml  (uncensored + vision)
model = "fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4"
model_provider = "ollama-local"
model_context_window = 96000
model_auto_compact_token_limit = 86000
```

```bash
codex --profile ollama-local             # local qwen3.6:35b-a3b (loads ollama-local.config.toml)
codex --profile ollama-qwen36-35b        # local qwen3.6:35b-a3b (loads ollama-qwen36-35b.config.toml)
codex --profile ollama-qwen36-uncensored-vision # local Uncensored + vision (loads ollama-qwen36-uncensored-vision.config.toml)
codex                                    # cloud (default profile)
```

---

## MCP Integration

> **Scope:** three stdio MCP servers ship here, with very different standing:
>
> - **`codex` (`mcp_codex.py`) — task-fork bridge.** Forks a self-contained task
>   from Claude Code into a one-shot Codex (GPT-5.5) run pinned to a single repo
>   as its sandbox (`fork_to_codex` / `ask_codex`). This is the
>   [accuracy/cross-model review path](#codex-task-fork-via-mcp-each-repo-as-its-own-sandbox)
>   and the way Codex sidesteps both the multi-repo launch root and its own
>   cloud/local session-sharing limits.
>   The same server is also the host's **external-access bridge**: `web_rag`
>   (`codex exec -c tools.web_search=true`, live web search with cited sources) and `notion_page`
>   (create/update Notion pages through the Notion MCP registered in Codex's
>   config). These absorb what the old `gemini` server did — query `web_rag`
>   whenever an answer depends on facts outside the model's knowledge (anything
>   post-cutoff, any "latest"/release/version/pricing claim) rather than guessing.
> - **`localllm` (`mcp_localllm.py`) — deprecated, register on demand only.** Its
>   path is **single-shot** (no history), so it cannot share Claude Code's
>   working context; that need is served better by a **separate terminal**
>   running `source_local` + `claude --model` with a shared resume. Use `localllm`
>   only as an optional debugging path for the loaded Ollama model when you
>   explicitly want to exercise it — it is **not registered by default**.
>
> None of these is a token-saving subtask-delegation layer; the cloud-vs-local
> decision is made up front by static switching (see
> [cloud / local static switching](#cloud--local-static-switching)), per whole
> task, not per subtask. (`codex` differs in kind: it hands off a *whole*
> bounded task to a different model, not a subtask of the current one.)

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

### Register (on demand only)

> `localllm` is **deprecated** as an everyday tool and **not registered by
> default** — see the [Scope](#mcp-integration) note above. Register it only when
> you explicitly want to debug the loaded Ollama model, and prefer a
> **session-scoped** add (`-s local`) so it does not linger in every project.

```bash
# Claude Code (session-scoped; drop -s for project, or -s user to pin globally)
claude mcp add -s local localllm python3 $REP/ollama/mcp_localllm.py

# Codex
codex mcp add localllm -- python3 $REP/ollama/mcp_localllm.py
```

Verify in Claude Code with `/mcp` (expect `localllm` connected) and call
`ask_local`. Remove it again with `claude mcp remove localllm` when done.

---

## Codex task fork via MCP (each repo as its own sandbox)

> **Status: this supersedes the old `stop-review-gate` rg/review machinery.** That
> section has been **reset** (see [What was reset, and why](#what-was-reset-and-why)
> at the end). The only piece carried forward from it is the rg-cleanup `Stop`
> hook, kept purely as insurance — see
> [Insurance: rg-cleanup `Stop` hook](#insurance-keep-the-claude-code-rg-cleanup-stop-hook).

`mcp_codex.py` lets Claude Code **fork a whole, self-contained task to Codex
(GPT-5.5)**, with each fork pinned to **one repository as its sandbox**. It is a
thin stdio MCP server (stdlib + FastMCP) that shells out to `codex exec`:

```sh
codex exec -C <repo> -s <sandbox> --skip-git-repo-check "<task>"
```

The `-C <repo>` flag makes that single repository Codex's entire working root —
**that repo *is* the sandbox**.

### Why fork through Claude Code (the two constraints it dissolves)

This repo's workspace is a launch root (`~/rep`) holding **many independently
cloned repositories side by side**, not one git repo. This rule is mirrored in the global `CLAUDE.md` / `AGENTS.md`. 

Two long-standing problems came from that, and the fork model removes both at the source:

1. **The multi-repo root constraint becomes a non-issue for Codex.** Because every
   fork is pinned with `-C <repo>`, Codex only ever sees one real git working
   tree and never the root. The whole "operate at the second level or deeper /
   `git` fails at the root / `rg .` fallback" problem (the original cause of the
   lingering `rg` processes) **never arises** — Codex is structurally prevented
   from running at the root.
2. **Codex's cloud/local session-sharing limit becomes irrelevant.** Codex cannot
   merge a cloud session with a local-profile session (the resume picker keeps
   them separate; see [Codex](#codex)). But a fork carries no session: **Claude
   Code holds the working context** and packs everything Codex needs into the
   `task` string, then each `codex exec` runs **fresh and stateless**. There is
   no session to share or merge, so the limitation simply does not apply.

In short: forking *from* Claude Code lets Codex work as if the awkward
side-by-side-clones layout did not exist, and lets the cloud Codex model act on
context that originated in a (possibly local) Claude Code run.

### Tools

| Tool                                   | Sandbox             | Use for                                                                                                                                       |
| -------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `fork_to_codex(task, repo, sandbox)` | `workspace-write` | Hand off a bounded coding task (implement / refactor / fix) that should run**inside one repo**. Codex edits the repo.                   |
| `ask_codex(question, repo)`          | `read-only`       | Read-only question about a repo — explanation, review, "where/how is X here". No edits.                                                      |
| `web_rag(query, repo)`               | `read-only`       | External-access path: live web search (`codex exec -c tools.web_search=true`) with cited sources. Use for anything post-cutoff or "latest". |
| `notion_page(task, repo)`            | `read-only`       | Create or update Notion pages via the Notion MCP registered in Codex's config. Writes go to Notion, not the repo.                             |

`repo` is resolved relative to `CODEX_FORK_BASE` (default `~/rep`) or accepts an
absolute path; **that repo is the sandbox**. Each call is **one-shot and
stateless** — put everything Codex needs in `task`/`question`; it cannot see the
Claude Code conversation. `sandbox` accepts `read-only`, `workspace-write`
(default), or `danger-full-access`.

### External access: web search (`web_rag`) and Notion (`notion_page`)

Outward access is **folded into `mcp_codex.py`** rather than a separate bridge:
`web_rag` and `notion_page` are two more tools on the same one-shot `codex exec`
fork, both `read-only` on the filesystem (`repo` only supplies the fork's working
root) — Codex searches/writes *externally* but never edits the repo. They reuse
the Codex login (`~/.codex`) and the same env knobs (`CODEX_BIN`,
`CODEX_FORK_BASE`, `CODEX_MODEL`, `CODEX_FORK_TIMEOUT`); no extra auth or
registration. They absorb what the old standalone `gemini` server
(`mcp_gemini.py`) did — removed, recover from git history if wanted.

**`web_rag`** uses Codex's native Responses `web_search` tool
(`codex exec -c tools.web_search=true`), returning up-to-date answers with cited
URLs.

> **When to use `web_rag` (both cloud and local):** whenever an answer depends on
> facts outside the agent's own knowledge — anything post-cutoff, any
> "latest"/release/version/pricing claim, or any external fact the agent is not
> certain of — query `web_rag` *before* answering, rather than answering from
> memory or guessing.

**`notion_page`** writes through the Notion MCP that Codex registers in its own
config (`[mcp_servers.notion]` → `https://mcp.notion.com/mcp`); the tool itself
holds no Notion logic, so the same offload is reachable via `ask_codex` with a
Notion task in the prompt — `notion_page` exists only to label the write intent
(`ask_codex` advertises read-only). Low-frequency by design; the setup below is
the one irreproducible part worth keeping.

Register the Notion MCP with Codex once (adds `[mcp_servers.notion]` to
`~/.codex/config.toml`), then complete its OAuth:

```bash
codex mcp add notion --url https://mcp.notion.com/mcp
codex mcp login notion        # OAuth in the browser; grants page access
```

> **Required Notion config — auto-approve, OAuth connector only.** Because the fork
> runs `codex exec` **non-interactively** (`stdin` is closed), any MCP tool call
> that needs per-call approval is auto-**cancelled** (`user cancelled MCP tool call`). So the OAuth `notion` connector must be set to auto-approve in
> `~/.codex/config.toml`:
>
> ```toml
> [mcp_servers.notion]
> url = "https://mcp.notion.com/mcp"
> default_tools_approval_mode = "approve"   # "approve" = auto-approve (values: auto | prompt | approve)
> ```
>
> Without it, `notion_page` returns `user cancelled MCP tool call`. Do **not** rely
> on the Bearer-token `codex_apps` managed connector — it lacks page access and
> returns `UNAUTHORIZED`; phrase the `task` to use the OAuth `notion` connector
> explicitly. Verified end-to-end (append + delete on a target page).

### How it routes to the cloud model

The fork reuses the Codex login on the host (`~/.codex`) and runs on whatever
model Codex is configured to use (**GPT-5.5** by default; pin with `CODEX_MODEL`).
It is the **cloud** Codex path: it does **not** read the `OPENAI_*` variables that
`source_local` leaves unset, so even when Claude Code itself runs on the local
open-weight model, a fork is reviewed/executed by the high-accuracy cloud model.
This is the same "barter" the old stop-review-gate aimed for — closed, cheap local
work; cloud-side accuracy on the result — but driven **explicitly, per task**, by
Claude Code calling the tool, instead of an implicit per-turn hook.

### Register in Claude Code (and optionally Codex)

```bash
claude mcp add -s user codex python3 $REP/ollama/mcp_codex.py
# (optional) expose to a Codex session too, for Codex-to-Codex forks:
codex mcp add codex -- python3 $REP/ollama/mcp_codex.py
```

Environment overrides (all optional):

| Var                         | Default                           | Meaning                                            |
| --------------------------- | --------------------------------- | -------------------------------------------------- |
| `CODEX_BIN`               | `codex` on PATH → nvm fallback | Codex CLI binary (MCP host may lack the nvm PATH)  |
| `CODEX_FORK_BASE`         | `~/rep`                         | Base that a relative `repo` resolves against     |
| `CODEX_FORK_DEFAULT_REPO` | (empty)                           | Repo used when a call omits `repo`               |
| `CODEX_MODEL`             | (empty → Codex default, GPT-5.5) | Pin the model for forks                            |
| `CODEX_FORK_TIMEOUT`      | `1800`                          | Per-fork wall-clock cap (seconds)                  |
| `CODEX_FORK_USAGE_LOG`    | `ollama/usage_codex.log`        | JSONL usage log (same schema as the other servers) |

Usage is logged one JSONL record per call (`source: "codex"`, plus `repo` /
`sandbox`), matching `usage_localllm.log` so `usage_report.py` can aggregate both.

### Insurance: keep the Claude Code rg-cleanup `Stop` hook

The fork model means Codex no longer runs at the multi-repo root, so the
`stop-review-gate` `rg .` fallback that orphaned `rg` processes should not fire
anymore. The `Stop` hook below is **kept as belt-and-suspenders only** — it costs
nothing and still cleans up any stray `rg` from other sources.

Add to `~/.claude/settings.json`; Claude Code runs it automatically when each
session ends:

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

The hook matches `rg` processes by **session ID (SID)**. SID is inherited from the
parent at fork and does not change when a process becomes orphaned — so even after
a spawner exits and `rg` is reparented to init, it retains the Claude Code
session's SID.

> **Best-effort:** not a perfect filter. `rg` processes started from the same
> terminal session that launched Claude Code share the SID and would also be
> killed. In practice that trade-off is acceptable — intentional long-running `rg`
> searches in the same terminal as an active Claude Code session are rare.

---

## Local model bridge (`mcp_localllm.py`) — deprecated, on demand

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

### Available tools

| Tool                                 | Use for                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------- |
| `ask_local_code(language, prompt)` | Code: generation, refactoring, unit-test skeletons, stubs, code translation  |
| `ask_local(prompt)`                | Prose: Q&A, explanations, summaries, translation, comment/docstring rewrites |

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

> **Model-specific sampling.** The MCP server forwards `LOCALLLM_TEMPERATURE`,
> `LOCALLLM_TOP_P`, and `LOCALLLM_TOP_K` to `/api/chat` `options`; `top_p`/`top_k`
> are sent only when set, so a model keeps Ollama's defaults unless you opt in.
> Use this when a model is tuned away from the conservative `0.2` default — e.g.
> the former gemma3 WSL model wanted `temperature≈1.0, top_p=0.95, top_k=64`. The
> current WSL default `lfm2.5-1.2b-instruct` runs fine at the `0.2` default.

---

## Token usage logging

Each `mcp_localllm.py` call appends a JSONL record (timestamp, source, tool,
model, token counts, latency) to `usage_localllm.log` (override with
`LOCALLLM_USAGE_LOG`); `mcp_codex.py` writes the same schema to
`usage_codex.log` (override with `CODEX_FORK_USAGE_LOG`). Codex rows
have null token fields — `codex exec` does not report token counts —
so token columns reflect local-LLM usage only, while call/latency columns cover
both. `usage_report.py` reads both logs at once:

```bash
python3 ollama/usage_report.py                  # both logs, source / tool table
python3 ollama/usage_report.py --by source      # group by source (localllm / codex)
python3 ollama/usage_report.py --by tool        # group by tool
python3 ollama/usage_report.py --by day         # group by day
python3 ollama/usage_report.py --json           # machine-readable totals
python3 ollama/usage_report.py usage_codex.log  # one explicit file
```
