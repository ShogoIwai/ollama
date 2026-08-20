# Local LLM Workflow — Ollama + Claude Code + Codex

`ollama/` provides a local LLM environment for Claude Code and Codex,
built on **Ollama**. The default local model is
**`qwen3.6:35b-a3b-mtp-q4_K_M`** (thinking-capable MoE, ~3B active), with its own
thin launcher (`start_ollama_qwen36_35b.sh`) sharing one core
(`_ollama_serve_common.sh`); additional models can be added with the procedure
below, each as one more 2-line launcher. Local models are served at the
shared core's **256K (262144)** context default (the qwen35moe family's native
window); see the [measured table](#models-and-memory-requirements) for the
model's VRAM/speed cost at 256K. The harness direct-connect picks the
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

- a `case`/`switch` arm in **both** `source_local.sh` and `source_local.csh`
  mapping the tag → a Codex profile name (see
  [cloud / local static switching](#cloud--local-static-switching)), and
- the matching overlay file `~/.codex/<profile>.config.toml` with
  `model = "<tag>"` and `model_provider = "ollama-local"` (see [Codex](#codex)).

This is optional for a first smoke test — auto-detection from the marker already
makes `source_local.sh` track the launched tag.

### 4. Restart the daemon on the new model

Only one daemon binds `:11434`, so stop the running launcher and start the new
one. The launcher records the tag in `~/.ollama_active_model`, which
`source_local.sh` then auto-detects.

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
  source ollama/source_local.sh            # tcsh: source ollama/source_local.csh
  claude                                 # drive a small edit; confirm it reaches disk
  codex                                  # confirm a tool call executes
  ```

A model that emits tool calls as plain-text JSON in `content` (e.g. small Gemma)
rather than a structured `tool_calls` block cannot drive direct connect — the
client cannot detect the call and "hallucinates" edits that never reach disk;
verify with `/api/show` capabilities (`tools`) + a tool-call smoke test. Note
speed (`tok/s`), resident VRAM, and whether tool calls land.

### 6. Adopt or drop

Decide against the measured numbers from step 5: does it fit 24 GB with usable
context, run fast enough, and (for direct connect) drive tool calls correctly? If
**no**, drop it — `ollama rm <tag>` reclaims the disk and delete the launcher;
nothing else was committed. If **yes**, continue to step 7.

### 7. Document it in the README

Record the adopted model so the next person does not re-derive it:

- add a row to [Models and memory requirements](#models-and-memory-requirements)
  with the **measured** VRAM / context / `tok/s`, not estimates;
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

If the model had a dedicated launcher / Codex profile, delete every artifact it
left in the tree so the README and switch logic stay truthful. A plain adopted
tag leaves only the launcher + profile scaffolding (steps 3 and 7 of *Adding a
new LLM*); a **derived** model (built with `ollama create`) also leaves its
`.modelfile` and any build/smoke-test script, plus stray comments referencing it:

- delete the launcher `start_ollama_<name>.sh`;
- for a derived model, delete its `<name>.modelfile` and any dedicated build
  script (e.g. `build_<name>.sh`);
- remove its `case`/`switch` arm from **both** `source_local.sh` and
  `source_local.csh`, and delete the overlay `~/.codex/<profile>.config.toml`;
- drop its row from [Models and memory requirements](#models-and-memory-requirements),
  [Directory Contents](#directory-contents), and the
  [Quick Start](#2-start-the-server) launcher list;
- grep the tree for the tag / launcher / profile name to catch any leftover
  cross-references or comments (e.g. in `source_local.*` or `ocr_to_md.sh`).

Leaving a launcher whose tag has been `rm`'d is harmless (the common core
lazy-pulls it back on next start), but it re-downloads the weights you just
freed — so remove the launcher unless you intend to re-pull.

### 4. Clear the active-model marker

If the tag you removed is the one recorded in `~/.ollama_active_model`, this step
is **required, not optional**: until the marker is rewritten, `source_local.sh`
resolves the `claude`/`codex` aliases to the now-absent model. Start another
launcher (which overwrites the marker) or delete the marker to fall back to the
`qwen3.6:35b-a3b-mtp-q4_K_M` default. (If the marker already points at a model you
kept — as after this cleanup — nothing to do.)

---

## Directory Contents

| File                                         | Role                                                                                                                                                                                                                                                                                                   |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `up_version.csh`                           | Reinstall Ollama to the latest release, stop/disable the systemd unit, and print the version (manual update helper)                                                                                                                                                                                    |
| `start_ollama_qwen36_35b.sh`               | Thin launcher for`qwen3.6:35b-a3b-mtp-q4_K_M` (default; Qwen3.6-35B-A3B MoE, ~3B active, thinking + vision; override `MODEL=qwen3.6:35b` for non-MTP)                                                                              |
| `start_ollama_ornith15_35b.sh`             | Thin launcher for`ornith-1.5:35b` (Ornith-1.5-35B-A3B MoE, ~3B active, vision + thinking + tools; arch `qwen35moe`, same family as the default). Measured **~97 tok/s @ 256K**, 11% CPU spill                                     |
| `_ollama_serve_common.sh`                  | Shared core sourced by the launchers (daemon start, readiness wait, lazy pull); records the launched model in`~/.ollama_active_model`. Default `OLLAMA_CONTEXT_LENGTH=262144` (256K)                                                                                                              |
| `ocr_to_md.sh`                             | Vision-as-preprocessing helper: OCR an image/PDF to Markdown with a small dedicated model (`glm-ocr`) so a **text-only** agentic model can consume it — see [Vision via OCR preprocessing](#vision-via-ocr-preprocessing). **Currently optional:** the adopted model is vision-capable, so this is only needed if a text-only model is re-added |
| `source_local.sh` / `.csh`               | LOCAL mode: export Claude Code`ANTHROPIC_*` + alias `claude`/`codex` to local                                                                                                                                                                                                                    |
| `source_cloud.sh` / `.csh`               | CLOUD mode: unset those env vars and`unalias claude`/`codex`                                                                                                                                                                                                                                       |

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
./start_ollama_ornith15_35b.sh       # ornith-1.5:35b (Ornith-1.5-35B-A3B; ~97 tok/s @ 256K, faster than the default)
```

Each launcher is a thin wrapper: it sets the `MODEL` tag and sources the shared
core `_ollama_serve_common.sh`. Adding a new model is one more 2-line launcher —
everything else (daemon start, readiness wait, lazy pull, foreground lifecycle)
lives once in the common file. The wrapper:

- exports `OLLAMA_HOST` (default `http://localhost:11434`) and
  `OLLAMA_CONTEXT_LENGTH` (default `262144` / 256K);
- if a daemon is already reachable, reports and exits 0 (does nothing);
- otherwise starts `ollama serve` in the background, waits for the API, pulls
  the selected `MODEL` if missing, then keeps the daemon in the foreground.

> Only one daemon binds `:11434`. To switch which model serves, stop the running
> launcher and start the other; `source_local.sh` then auto-detects the newly
> loaded model. Run both side by side only if you give each its own
> `OLLAMA_HOST` port.

> **Context length:** Ollama's auto-picked default is too small for agent use —
> as low as 4K when VRAM < 24GB, and even a 24GB RTX 3090 only defaults to
> ~32768. So the wrapper sets `OLLAMA_CONTEXT_LENGTH=262144` (256K, the qwen35moe
> family's native window; kept in sync with `CLAUDE_CODE_MAX_CONTEXT_TOKENS` in
> `source_local.sh` / `.csh`). **This applies only to the `serve` launched by
> this script** — a daemon started elsewhere (systemd) keeps its own setting.
> Check the loaded context and CPU/GPU split with `ollama ps`. A tag whose
> Modelfile pins its own `num_ctx` overrides this
> env; to serve less, pass `OLLAMA_CONTEXT_LENGTH=128000 ./start_ollama_<name>.sh`.
>
> **VRAM caveat:** on a 24 GB GPU this ~22 GB model cannot hold the full 256K KV
> cache in VRAM — at 256K it spills to CPU (~17%/83% split / **~49 tok/s**; the
> MTP multi-token-prediction draft head's extra compute compounds the slowdown).
> If `ollama ps` shows a CPU split you want to avoid, drop
> `OLLAMA_KV_CACHE_TYPE=q4_0` or lower `OLLAMA_CONTEXT_LENGTH`.

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
> 30B+ models keep a large context in 24GB — though at the 256K default the
> MTP build still spills some to CPU; see the caveat above); override
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
3090 24GB)** with the wrapper's `OLLAMA_KV_CACHE_TYPE=q8_0` + flash attention:
at the **256K** default `ollama ps` shows a **17%/83% CPU/GPU split** and
only **~49 tok/s** (23 GB). At 256K the ~22 GB weights plus the q8_0 KV cache
overflow VRAM, so part of the model spills to CPU; the MTP (multi-token-prediction)
draft head's extra compute likely compounds the slowdown here rather than helping.
The q8_0 KV cache is what keeps
it even this close to fitting a large context alongside the weights in 24 GB, and
the 3B-active MoE is what makes a 35B model run at all on this host. This is the
**default** local model. Its ~3B active
params are the structural ceiling on heavy long-document / multi-step reasoning;
lifting that on a 24 GB host would need a **dense** 27–32B (which runs all its
params per token, so far slower than this ~3B-active MoE).
`/api/show` reports capabilities `['completion','vision','tools','thinking']`, so
it is a candidate **direct-connect** agentic backend (`tools`) — a full agentic
tool-driving loop has not yet been exercised end-to-end here.

**Ornith-1.5-35B-A3B (`ornith-1.5:35b`, measured).** Sparse MoE, 35.5B total /
**~3B active**, vision-capable, arch `qwen35moe` (41 blocks) with a native
**256K** context, so the shared core's 262144 default applies unchanged. Ollama
publishes the 35B only at **q4_K_M**: 22 GB weights + a 903 MB BF16 clip
projector (~23 GB on disk). **Measured on this host (RTX 3090 24GB)** with the
wrapper's `OLLAMA_KV_CACHE_TYPE=q8_0` + flash attention, at the **256K**
default: `ollama ps` shows **26 GB resident / 11%/89% CPU/GPU split**
(23.3 GB of the 24 GB VRAM in use) and **~97 tok/s** generation
(~97-100 tok/s across two runs; ~210 tok/s prompt eval). Despite being slightly *larger* on disk than the
qwen3.6 MTP default, it runs **~2x faster** at the same 256K context (97 vs ~49 tok/s) with a *smaller* CPU spill (11% vs 17%) — evidence that the MTP
draft head, not the weight size, is what costs the default model its speed here.
`/api/show` reports capabilities `['tools','thinking','completion','vision']`,
and **Claude Code and Codex have both been driven against it via direct connect**
(`source_local.sh` ⇒ `--model ornith-1.5:35b` / `--profile
ollama-ornith15-35b`).

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

| GPU VRAM | Practical context        | Notes                                                                                                                                                                              |
| -------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| < 24 GB  | 4K (auto), raise w/ care | Ollama auto-limits to 4K; larger needs explicit override + RAM spill                                                                                                               |
| 24 GB    | up to 256K (with CPU spill) | **Measured** on RTX 3090 — see the table below (q8_0 KV cache; the ~22 GB Q4 default spills some KV to CPU at 256K) |
| 48 GB+   | 256K+ (estimate)         | Report-derived,**not measured** here; confirm with `ollama ps`                                                                                                             |

> The 24 GB row is measured on this host; other rows are estimates to be confirmed
> per environment via the `ollama ps` `CONTEXT` column and CPU/GPU split.

**Per-model measured values (RTX 3090, 24 GB).** `OLLAMA_KV_CACHE_TYPE=q8_0`;
SIZE / processor split from `ollama ps`, throughput from `/api/generate`
(`eval_count` ÷ `eval_duration`, 300-token generation, `think:false`), **lightly
loaded** (KV cache mostly empty — see caveat below), at the **256K** wrapper
default:

| Model                                            | Context | Processor          | VRAM (SIZE) | Throughput |
| ------------------------------------------------ | ------- | ------------------ | ----------- | ---------- |
| `qwen3.6:35b-a3b-mtp-q4_K_M` (default, MTP)    | 262144  | **17%/83% CPU/GPU** | 23 GB       | **~49 tok/s** |
| `ornith-1.5:35b` (Ornith-1.5-35B-A3B, non-MTP) | 262144  | **11%/89% CPU/GPU** | 26 GB       | **~97 tok/s** |

> **Takeaway:** at the 256K default the ~22 GB Q4 weights plus the q8_0 KV cache
> exceed 24 GB, so both models spill to CPU. `ornith-1.5:35b` is the *larger*
> download (22 GB weights + 903 MB projector) yet spills **less** (11% vs 17%) and
> runs **~2x faster** at the same context — so the default's slowdown is the MTP
> draft head's extra compute, not weight size; the draft head costs more than it
> saves here. If you need to avoid the spill, drop `OLLAMA_KV_CACHE_TYPE=q4_0` (halves KV VRAM) or lower
> `OLLAMA_CONTEXT_LENGTH`.

> The reported SIZE reflects a near-empty KV cache because Ollama allocates KV
> lazily — at warm-up little of the 256K is in use, so a task that fills toward the
> full window pushes more of the model off the GPU and slows further. Re-check
> `ollama ps` under load; if the split worsens, restart with
> `OLLAMA_KV_CACHE_TYPE=q4_0` (halves KV VRAM) or lower `OLLAMA_CONTEXT_LENGTH`.

---

## cloud / local static switching

Switching is done by sourcing one of two env files. There is no dynamic
routing. A freshly opened shell is already in cloud mode; `source_local.sh`
exports the Ollama overrides, and `source_cloud.sh` unsets them to return to cloud
within the same shell.

The env files toggle **Claude Code only** (`ANTHROPIC_*`). They deliberately
do **not** touch any `OPENAI_*` variable — Codex's cloud OpenAI client reads
those too, so exporting them would silently redirect Codex to the local server.

| File                           | Mode          | Effect                                                                                                                                                                                                                                                                                                                     |
| ------------------------------ | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_local.sh` / `.csh` | LOCAL(Ollama) | export`ANTHROPIC_BASE_URL=:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, `OLLAMA_HOST`, `DISABLE_COMPACT=1`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144` (see [Context window](#context-window-in-local-mode)); alias `claude`/`codex` to local (see [Aliases](#aliases-set-by-source_localsh)) |
| `source_cloud.sh` / `.csh` | CLOUD         | unset the above (tcsh`unsetenv`) and `unalias claude` / `codex`; re-set `ANTHROPIC_API_KEY` if you authenticate by key                                                                                                                                                                                             |

### Context window in LOCAL mode

Claude Code resolves its context window — and thus the auto-compact trigger —
from a **built-in per-model table keyed on the model name** (bundle fn `k87`):
`[1m]` tags and `opus-4-8`/`fable-5` etc. get 1M, and **everything it doesn't
recognize falls back to 200000**. The Ollama tags (`qwen3.6:*`)
are unknown, so Claude Code thinks it has 200K and **never auto-compacts before
Ollama's real window** (`OLLAMA_CONTEXT_LENGTH`, default 262144) silently truncates
the oldest tokens — the model quietly loses early context with no error.

There is **no clean way to keep auto-compact and fire it at the real window**: the
only override env, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, is honored **only when
`DISABLE_COMPACT` is set** (bundle fn `v87`). So `source_local.sh` makes the
deliberate trade-off:

- `DISABLE_COMPACT=1` — turns auto-compact off, and
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144` — makes the `/context` gauge and the
  "approaching limit" warning reflect the **real window** (kept equal to
  `OLLAMA_CONTEXT_LENGTH`; change both together). `source_local.sh` / `.csh` set
  this to 262144 (256K) to match the shared core default; an explicit pre-set
  value before sourcing still wins (e.g. `128000` if you launched a model with a
  smaller `OLLAMA_CONTEXT_LENGTH`).

Net effect: **you compact manually** (`/compact` or `/clear`) when the honest
gauge says you're near the limit, instead of being silently truncated. If you
lower the Ollama window, set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the new value
**before** sourcing. `source_cloud.sh` unsets both, so cloud mode is unaffected.

### Aliases set by `source_local.sh`

`source_local.sh` defines two shell aliases so plain `claude` / `codex` run in
local mode without typing flags; `source_cloud.sh` removes them again. The model
each alias selects is **no longer hard-coded** — it is **auto-detected from the
running launcher** and can still be overridden by two env vars you set **before**
sourcing:

| Env var (override before sourcing) | Default                                             | Controls                                         |
| ---------------------------------- | --------------------------------------------------- | ------------------------------------------------ |
| `LOCALLLM_MODEL`                 | auto (marker → else`qwen3.6:35b-a3b-mtp-q4_K_M`) | the model tag pinned by the`claude` alias      |
| `LOCALLLM_CODEX_PROFILE`         | derived from`LOCALLLM_MODEL`                      | the Codex profile selected by the`codex` alias |

**Auto-detection (marker file).** Each start script records the launched model
tag in `~/.ollama_active_model` (written by `_ollama_serve_common.sh` as soon as
`MODEL` is known, so it applies on every path including the already-running
early-exit). When `source_local.sh` runs and `LOCALLLM_MODEL` is unset, it reads
that marker — so sourcing automatically tracks whichever model you started, with
no manual edits. If the marker is missing it falls back to
`qwen3.6:35b-a3b-mtp-q4_K_M`. An
explicit `setenv`/`export LOCALLLM_MODEL` before sourcing always wins.

`LOCALLLM_CODEX_PROFILE`, when unset, is **derived from `LOCALLLM_MODEL`** via a
`switch` in `source_local.csh`:
`qwen3.6:*` ⇒ `ollama-qwen36-35b`, `ornith-1.5:*` ⇒ `ollama-ornith15-35b`, everything else ⇒
`ollama-local`. (Each model gets its own explicit case, so an unlisted variant
defaults to `ollama-local`.) Add one
`case` + a matching overlay file per new local model.
(`ollama ps` is *not* used for detection: it only lists models already loaded
into memory on demand, so it is empty right after `ollama serve` starts.)

```bash
# auto: start a model, then just source — both clients follow it
./start_ollama_qwen36_35b.sh               # writes marker = qwen3.6:35b-a3b-mtp-q4_K_M
source ollama/source_local.sh                 # tcsh: source ollama/source_local.csh
#   → claude --model qwen3.6:35b-a3b-mtp-q4_K_M, codex --profile ollama-qwen36-35b

# manual override still works (wins over the marker)
export LOCALLLM_MODEL=qwen3.6:35b          # tcsh: setenv LOCALLLM_MODEL qwen3.6:35b
source ollama/source_local.sh                 # claude alias → claude --model qwen3.6:35b
```

The two env files resolve the aliases at source time:

| Alias                                                                                        | Why                                                                                                                |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `claude` → `claude --model $LOCALLLM_MODEL`                                             | env already targets Ollama; the alias just pins the model name                                                     |
| `codex` → `codex --profile $LOCALLLM_CODEX_PROFILE -c mcp_servers.notion.enabled=false` | Codex shares no env (OPENAI_* stays unset), so the profile flag selects local; Notion MCP is disabled only locally |

`source_local.sh` also exports `LOCALLLM_MODEL` / `LOCALLLM_CODEX_PROFILE` so the
choice is visible to subprocesses; `source_cloud.sh` unsets both along with the
aliases, so `claude` / `codex` revert to their cloud defaults. (Alias
self-reference is safe — bash/csh do not re-expand the leading word
recursively.)

> **Note:** `LOCALLLM_MODEL` selects the model for the **harness direct-connect**
> (the `claude` alias). Make sure the model you point the
> alias at is actually the one the running launcher serves.

> **Direct connect:** `qwen3.6:35b-a3b-mtp-q4_K_M` reports the `tools` capability
> and is a candidate **direct-connect agentic backend for both Claude Code
> and Codex** on the 24 GB host: `./start_ollama_qwen36_35b.sh` then
> `source ollama/source_local.sh` (claude → `--model qwen3.6:35b-a3b-mtp-q4_K_M`, codex →
> `--profile ollama-qwen36-35b`).

### Claude Code

```bash
# local
source ollama/source_local.sh         # tcsh: source ollama/source_local.csh
claude                             # alias → claude --model $LOCALLLM_MODEL (default qwen3.6:35b-a3b-mtp-q4_K_M)
# (optional) alias to bypass model-name validation:
#   ollama cp qwen3.6:35b-a3b-mtp-q4_K_M claude-3-5-sonnet

# cloud
source ollama/source_cloud.sh         # tcsh: source ollama/source_cloud.csh
claude                             # alias cleared → cloud default
```

#### Sub-agents and model resolution

This section records **a single set of observations**, not documented product
behaviour. Claude Code's model resolution and fallback logic are not specified
publicly, so treat the results below as "what this version did on this setup",
and re-measure before relying on them.

**Setup.** Claude Code 2.1.222; Ollama serving `qwen3.6:35b-a3b-mtp-q4_K_M` as
the only chat model; measured 2026-08-06. A transparent logging proxy was placed
in front of the server and `ANTHROPIC_BASE_URL` pointed at it. The proxy parsed
`model` out of each `POST /v1/messages` body, logged it, and relayed request and
response unmodified (chunked, so streaming is preserved). In this version,
requests belonging to a sub-agent carried a `cc_is_subagent=` marker in the
system block; that marker is what distinguished them from the parent session's
own requests. Each condition below was run **once**, with the parent invoked as:

```bash
ANTHROPIC_BASE_URL=<proxy> ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY= \
  claude -p "<prompt asking for one Task-tool sub-agent that replies PONG>" \
    --model qwen3.6:35b-a3b-mtp-q4_K_M \
    --allowedTools Task --permission-mode bypassPermissions
```

For conditions 2 and 3 the sub-agent was declared with
`--agents '{"probe":{"description":"probe","prompt":"Reply with PONG and nothing
else.","model":"sonnet","tools":[]}}'` and the prompt referenced
`subagent_type=probe`.

| Condition | `model` in the sub-agent request | Observed outcome |
| --- | --- | --- |
| no `model` on the sub-agent, four env vars unset | `qwen3.6:35b-a3b-mtp-q4_K_M` | request completed; sub-agent returned an answer |
| `model: sonnet` in the agent definition, env vars unset | `claude-sonnet-5`, then `claude-haiku-4-5-20251001` | HTTP 404 for both |
| `model: sonnet`, four env vars set to the local tag | `qwen3.6:35b-a3b-mtp-q4_K_M` | request completed; sub-agent returned an answer |

Observations:

1. With no model specified for the sub-agent, the request carried the same tag
   the parent was started with, and the sub-agent produced its answer. No extra
   configuration was needed in this condition.
2. With `model: sonnet` in the agent definition, the request carried
   `claude-sonnet-5` and Ollama answered
   `404 {"type":"not_found_error","message":"model 'claude-sonnet-5' not
   found"}`. A second attempt carried `claude-haiku-4-5-20251001` and also 404'd.
   Only the `sonnet` alias and only the agent-definition form were measured; the
   Task tool's own `model` parameter, and the `opus` / `haiku` aliases, were not
   tested.
3. After both attempts failed, **the parent session did not stop.** It reported
   that the sub-agent was unavailable and then produced the answer itself, and
   the CLI exited normally. Whether this take-over happens is likely to depend on
   the parent model and the prompt, so it should not be assumed to be a
   guaranteed fallback path — but it means a failure of this kind can end in a
   normal-looking completion rather than an error, with work that was split
   across sub-agents landing back in the parent session.

Setting these four environment variables to the local tag made alias resolution
land on the local model in condition 3:

```bash
ANTHROPIC_DEFAULT_SONNET_MODEL   # sonnet alias
ANTHROPIC_DEFAULT_OPUS_MODEL     # opus alias
ANTHROPIC_DEFAULT_HAIKU_MODEL    # haiku alias
ANTHROPIC_SMALL_FAST_MODEL       # older name for the haiku slot
```

`source_local.sh` / `source_local.csh` set all four to `$LOCALLLM_MODEL`, and
`source_cloud.sh` / `source_cloud.csh` unset them again — leaving them set while
switching back to cloud would make the cloud endpoint receive a local Ollama tag
it does not have. Only the four together were tested; the individual
contribution of each variable was not measured.

##### Operational cautions (not measured)

The following follow from the observations above but were not themselves tested:

- Avoid setting `model` on Task tool calls or in agent definitions when running
  against a local backend.
- If a prompt or skill fans work out to sub-agents, consider stating that the
  parent must stop rather than take over when a sub-agent cannot be started.
  Whether such an instruction reliably prevents the take-over in observation 3
  was not verified.
- Before a run, check the four variables by name rather than dumping the
  environment (`env | grep ANTHROPIC` can print auth tokens):

  ```bash
  for v in ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
           ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL; do
    eval "printf '%s=%s\n' \"$v\" \"\${$v:-<unset>}\""
  done
  ```

### Codex

`source_local.sh` aliases `codex` →
`codex --profile $LOCALLLM_CODEX_PROFILE -c mcp_servers.notion.enabled=false`;
`source_cloud.sh` clears it so `codex` is cloud again. The `-c` override disables
the OAuth Notion MCP only for local LLM runs, avoiding repeated Notion
re-authentication while leaving the normal cloud `codex` command on the global
Notion MCP setting. You can still invoke either explicitly
(`codex --profile ollama-local -c mcp_servers.notion.enabled=false` / `codex`)
regardless of which file is sourced. By default `LOCALLLM_CODEX_PROFILE` is
**auto-derived from the detected `LOCALLLM_MODEL`** (see the auto-detection note above):
`qwen3.6:*` ⇒ `ollama-qwen36-35b`, `ornith-1.5:*` ⇒ `ollama-ornith15-35b`, otherwise ⇒ `ollama-local` (one
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
# ~/.codex/ollama-local.config.toml  (fallback profile; points at the default model)
model = "qwen3.6:35b-a3b-mtp-q4_K_M"
model_provider = "ollama-local"
model_context_window = 262144
model_auto_compact_token_limit = 240000
```

Add one overlay file per local model you want a `codex --profile` for; they all
reuse the single shared `ollama-local` provider:

```toml
# ~/.codex/ollama-qwen36-35b.config.toml
model = "qwen3.6:35b-a3b-mtp-q4_K_M"
model_provider = "ollama-local"
model_context_window = 262144
model_auto_compact_token_limit = 240000
```

`model_context_window` tells Codex the local model's real usable window, and
`model_auto_compact_token_limit` makes Codex compact before the transcript can
run into Ollama's server-side limit. Keep `model_context_window` equal to
`OLLAMA_CONTEXT_LENGTH`; keep the compact limit lower than that so there is
headroom for the next prompt, tool results, and model output. The 256K profile
uses **240K** as the first-pass trigger for a **256K** Ollama daemon.

Add one overlay file per additional local model you adopt, reusing the same
`ollama-local` provider (only the `model` line differs).

```bash
codex --profile ollama-local                 # fallback profile → default qwen3.6:35b-a3b-mtp-q4_K_M
codex --profile ollama-qwen36-35b            # local qwen3.6:35b-a3b (loads ollama-qwen36-35b.config.toml)
codex --profile ollama-ornith15-35b          # local ornith-1.5:35b   (loads ollama-ornith15-35b.config.toml)
codex                                        # cloud (default profile)
```

---

## Vision via OCR preprocessing

> **Currently optional — the adopted model is vision-capable.** The default model
> (`qwen3.6:35b-a3b-mtp-q4_K_M`) reports `vision`, so it reads images /
> PDF pages directly and this OCR-preprocessing hop is **not required**. This
> section is retained for reference and for the case where a **text-only** model
> (e.g. a future Ornith-style agentic-coding build) is re-added.

A text-only agentic model (no `vision` capability) cannot read images or PDFs.
The way to give it "eyes" is to run a **small dedicated OCR model** (`glm-ocr`,
Z.ai; `glm-ocr:bf16` loads at ~7 GB / 100 % GPU here, `glm-ocr:q8_0` is
smaller; text+image, layout/table/formula aware) over the input and write
Markdown to `<input>.md`. The OCR result is cached as a `.md` file next to the
input — it can then be fed to any agentic model via direct connect.

```
[PDF / image]  ──ocr_to_md.sh──▶  [<input>.md]  ──▶  text-only model (direct connect)
   input          (glm-ocr)         cached text        consumes as text
```

> **Co-resident with the agentic model — confirmed working.** The original
> assumption was that a ~22 GB text model plus `glm-ocr` would not fit on 24 GB,
> but in practice `ollama/ocr_to_md.sh` runs successfully while a ~22 GB text
> model is already loaded in the daemon. Both models reside simultaneously and the
> OCR step completes without displacing the text model — so you can run OCR → text
> inference in one sitting with no launcher swap. The preprocessing flow below
> remains the recommended approach for PDFs (sequential page-by-page OCR), but
> there is **no need to stop the text launcher first**.

> **glm-ocr call convention (important, verified here).** glm-ocr only behaves
> with its **exact predefined prompt** (`Text Recognition:`, also
> `Formula Recognition:` / `Table Recognition:`) and **greedy decoding**
> (`temperature 0`); the script sends these. A free-form prompt makes its
> renderer/parser degenerate. Even correctly called, this Ollama build (0.31.1)
> emits the clean transcription and then **echoes it inside a ``markdown fence**, which on sparse pages runs away into endless `` lines — so `ocr_to_md.sh`
> **post-processes**: it keeps the leading transcription, cuts at the first code
> fence, and stops on a repeated-line runaway. On real documents the result is
> clean; a near-empty page may leave a few duplicate lines (bounded, not
> infinite).

### Usage

```bash
# 1. Pull the OCR model once (manual operator step, like any new tag)
ollama pull glm-ocr:bf16                # or glm-ocr:q8_0 for lower VRAM

# 2. Start a text-only agentic model (no need to stop it — OCR runs alongside)
./start_ollama_<text-only-model>.sh     # only needed if the loaded model lacks `vision`

# 3. OCR an image or PDF to Markdown (writes <input>.md next to the input)
./ocr_to_md.sh spec.pdf                 # -> spec.pdf.md
./ocr_to_md.sh diagram.png notes.md     # explicit output path
./ocr_to_md.sh --force spec.pdf         # regenerate even if spec.pdf.md exists

# 4. Feed the cached Markdown to the agentic model (already loaded)
source ollama/source_local.sh           # tcsh: source ollama/source_local.csh
claude                                   # feed it spec.pdf.md
```

`ocr_to_md.sh` rasterizes PDFs page by page with `pdftoppm`, OCR's each via
`/api/generate`, and concatenates into one Markdown file with `---` page
separators. Existing `<input>.md` is **skipped** unless `--force` is given, so
OCR'd documents are cached and reused.

Env overrides (same style as the launchers): `OCR_MODEL` (default
`glm-ocr:bf16`; `glm-ocr:q8_0` for lower VRAM, or e.g. `qwen2.5vl:3b-q4_K_M`
for stronger table/layout at ~2× the VRAM), `OCR_DPI` (default `200`; raise to
`300` for dense figures), `OCR_PROMPT` (default `Text Recognition:` — keep it a
glm-ocr predefined prompt), `OCR_NUM_PREDICT` (default `8192` output-token cap),
`OLLAMA_HOST`.

PDFs are rasterized per page with `pdftoppm` (Ollama's vision endpoint takes
images only), OCR'd page by page via `/api/generate`, and concatenated into one
Markdown file with `---` page separators. Existing `<input>.md` is **skipped**
unless `--force` is given, so OCR'd documents are cached and reused.

Env overrides (same style as the launchers): `OCR_MODEL` (default
`glm-ocr:bf16`; `glm-ocr:q8_0` for lower VRAM, or e.g. `qwen2.5vl:3b-q4_K_M`
for stronger table/layout at ~2× the VRAM), `OCR_DPI` (default `200`; raise to
`300` for dense figures), `OCR_PROMPT` (default `Text Recognition:` — keep it a
glm-ocr predefined prompt), `OCR_NUM_PREDICT` (default `8192` output-token cap),
`OLLAMA_HOST`.
