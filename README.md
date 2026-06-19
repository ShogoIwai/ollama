# Local LLM Workflow — Ollama + Claude Code + Codex

`ollama/` provides a local LLM environment for Claude Code and Codex,
built on **Ollama**. The default local model is
**`qwen3.6:35b-a3b-mtp-q4_K_M`** (thinking-capable MoE, ~3B active), with its own
thin launcher (`start_ollama_qwen36_35b.sh`) sharing one core
(`_ollama_serve_common.sh`); additional models can be added with the procedure
below, each as one more 2-line launcher. The harness direct-connect picks the
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
makes `source_local` track the launched tag.

### 4. Restart the daemon on the new model

Only one daemon binds `:11434`, so stop the running launcher and start the new
one. The launcher records the tag in `~/.ollama_active_model`, which
`source_local` then auto-detects.

```bash
# stop the currently running launcher (Ctrl-C in its foreground, or kill the serve)
./start_ollama_<name>.sh
ollama ps                                 # confirm the model loaded; check CONTEXT + CPU/GPU split
```

A 100% GPU split with VRAM headroom is the goal; a large CPU share means the
weights+KV cache overflowed 24 GB — drop the quant or `OLLAMA_CONTEXT_LENGTH`.

### 5. Verify it works

Test the integration path:

- **Direct-connect agentic backend** (only if the model reports `tools`
  capability and emits structured tool calls):
  ```bash
  source ollama/source_local            # tcsh: source ollama/source_local.csh
  claude                                 # drive a small edit; confirm it reaches disk
  codex                                  # confirm a tool call executes
  ```

A model that emits tool calls as plain-text JSON in `content` (e.g. small Gemma)
cannot drive direct connect — see the tool-calling caveat in
[WSL / low-memory (CPU)](#wsl--low-memory-cpu). Note speed
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

| File                                         | Role                                                                                                                                                                                                                                                                                                                                                                                |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `up_version.csh`                           | Reinstall Ollama to the latest release, stop/disable the systemd unit, and print the version (manual update helper)                                                                                                                                                                                                                                                                 |
| `start_ollama_qwen36_35b.sh`               | Thin launcher for `qwen3.6:35b-a3b-mtp-q4_K_M` (default; Qwen3.6-35B-A3B MoE, ~3B active, thinking-capable; override `MODEL=qwen3.6:35b` for non-MTP)                                                                                                                                                                                                                           |
| `start_ollama_qwen36_uncensored_vision.sh` | Thin launcher for `fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4` (optional; uncensored derivative of the default that **keeps vision** — handles image/PDF input; ~125 tok/s, Codex profile `ollama-qwen36-uncensored-vision`)                                                                                                                        |
| `start_ollama_lfm25_wsl.sh`                | Thin launcher for `LiquidAI/lfm2.5-1.2b-instruct:q4_k_m` on a WSL / GPU-less host (CPU; default WSL model); **tool-capable** (structured `tool_calls`), so it can drive direct connect (see [WSL / low-memory (CPU)](#wsl--low-memory-cpu))                                                                                                                                  |
| `_ollama_serve_common.sh`                  | Shared core sourced by the launchers (daemon start, readiness wait, lazy pull); records the launched model in `~/.ollama_active_model`                                                                                                                                                                                                                                            |
| `source_local` / `.csh`                  | LOCAL mode: export Claude Code `ANTHROPIC_*` + alias `claude`/`codex` to local                                                                                                                                                                                                                                                                                                |
| `source_cloud` / `.csh`                  | CLOUD mode: unset those env vars and `unalias claude`/`codex`                                                                                                                                                                                                                                                                                                                   |

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
> launcher and start the other; `source_local` then auto-detects the newly
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
it is a candidate **direct-connect** agentic backend (`tools`) — a full agentic
tool-driving loop has not yet been exercised end-to-end here.

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
defaults tend to be aggressive — direct connect inherits the bundled defaults.
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
so unlike gemma3 it can drive **direct connect** on WSL.
Being a *hybrid* model (only 6 attention layers of 16) its KV cache stays small,
so it holds its full **32K** native window on this 8 GB host. **Measured on the
8 GB / 12-thread WSL host** (`start_ollama_lfm25_wsl.sh`, q4_k_m): `/api/show`
capabilities `['tools','thinking','completion']`; **~0.9 GB resident, 100% CPU,
~40 tok/s**; a `get_weather` tool-call test returned a proper structured
`tool_calls` (empty `content`), and a plain `think:false` chat returned clean
`content` with no thinking leak.

> Pick the **`-instruct`** build, **not** `lfm2.5-thinking`, which Ollama
> publishes text-only / without tool support. Other small CPU-fit candidates
> (gemma3:1b/4b, gemma2:2b, codegemma:2b) report no
> `tools` capability, so they cannot drive direct connect — hence the switch.

| Model / tag                                        | Params | Resident (Q4)     | CPU tok/s     | tool_calls | Use for                                                |
| -------------------------------------------------- | ------ | ----------------- | ------------- | ---------- | ------------------------------------------------------ |
| **`LiquidAI/lfm2.5-1.2b-instruct:q4_k_m`** | 1.17B  | **~0.9 GB** | **~40** | structured | **WSL direct-connect tool use**, chat |

> **Direct connect is enabled but limited by model size.** Both clients launch
> and Claude Code accepts a prompt, but a 1.2B model under Claude Code's ~23K-token
> system prompt is weak in practice; treat it as lightly usable. Claude Code direct connect
> needs `OLLAMA_CONTEXT_LENGTH` ≥ ~32K just to fit the system prompt (the launcher
> defaults to 32768 for this reason); set `CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768`
> before sourcing so the gauge matches the real window.

### Start

```bash
./start_ollama_lfm25_wsl.sh            # LiquidAI/lfm2.5-1.2b-instruct:q4_k_m, ctx 32768
#   OLLAMA_CONTEXT_LENGTH=8192 ./start_ollama_lfm25_wsl.sh    # tighter RAM
#   MODEL=LiquidAI/lfm2.5-1.2b-instruct:q8_0 ./start_ollama_lfm25_wsl.sh   # ~1.2GB
```

Unlike the GPU launchers (which default `OLLAMA_CONTEXT_LENGTH=96000`), the WSL
launcher defaults it to **32768** — the model's native ceiling, needed so Claude
Code's ~23K-token system prompt fits on direct connect. LFM2.5's hybrid design
keeps the KV cache small enough to hold 32K on this 8 GB host; drop to 8192 if
RAM is tight (small tasks then). Both `MODEL` and
`OLLAMA_CONTEXT_LENGTH` can be overridden before running.

### Integration: direct connect

On WSL the integration is **direct connect** via the cloud/local env switch. With
the default `lfm2.5-1.2b-instruct`, direct connect works (it reports `tools` and
emits a structured `tool_calls` block), so Claude Code / Codex can in principle
drive edits — but a 1.2B model is weak under their large system prompts, so treat
direct connect as "runs, lightly usable."

> **Tool-calling caveat (for other WSL models).** A model that does
> **not** report `tools` and emits the call as **plain-text JSON in `content`**
> (e.g. the former gemma3:4b default) **cannot drive direct connect**: the client
> cannot detect the call and "hallucinates" edits that never reach disk. Driving
> such a model would need an Anthropic-emulating gateway (Bifrost / LiteLLM) plus
> attribution-header suppression. This is the exact failure lfm2.5's structured
> `tool_calls` avoids — verify it with the `/api/show` capabilities + a tool-call
> smoke test before adopting any new WSL model for direct connect.

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
> (the `claude` alias). Make sure the model you point the
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

