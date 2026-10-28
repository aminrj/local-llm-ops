# local-llm-ops

Personal infrastructure for running local LLMs on a single RTX 3090.
One GPU, 24 GB, four server configs, one `make` command.

---

## The idea

Everything runs as a natively built `llama-server` binary. There is no Docker
track any more — it was removed in `53e4f1e` because the images lagged behind
Qwen3.6 architecture support.

Three binaries are in play:

- **`~/llama.cpp`** — pinned upstream build. Runs the 35B-A3B MoE daily driver.
- **`~/llama.cpp-38`** — current upstream. Runs Qwen3.8-27B, which needs an
  architecture the pinned build predates. Separate checkout so that pulling
  upstream cannot regress the daily driver.
- **`~/beellama.cpp`** — fork. Runs Qwen3.6-27B for its TurboQuant
  (`turbo4` / `turbo3_tcq`) KV cache types. It was also the only source of
  DFlash speculative decoding; **that is upstream now** as
  `--spec-type draft-dflash`, so the fork is only needed for the KV types.
  Its HEAD is from 2026-05-09 and it is superseded by the Qwen3.8 setup.

All servers expose an OpenAI-compatible API.

---

## Hardware this is tuned for

| | |
|---|---|
| GPU | RTX 3090, 24 GB, compute capability 8.6 (`sm_86`) |
| Host | 12 cores, 27 GB RAM |
| Display | attached to the same GPU — budget for it |

`sm_86` is pinned in `build-llamacpp.sh` via `-DCMAKE_CUDA_ARCHITECTURES=86`.
Change it if you move to other hardware; it exists to cut build time, not for
correctness.

---

## Prerequisites

| Tool | Install |
|---|---|
| CUDA toolkit + cmake | for the native builds |
| `hf` (HuggingFace CLI) | `pip install -U huggingface_hub` |

---

## Quick start

```bash
make build-llamacpp      # once, requires CUDA toolkit + cmake
make download-qwen3.6    # once, ~22 GB
make run-qwen3.6-35b-a3b # blocks until /health answers, then reports VRAM
make stop
```

For the Qwen3.8 dense 27B, which needs the second checkout:

```bash
make build-llamacpp-38   # once, clones ~/llama.cpp-38 and builds it
make download-qwen3.8    # once, ~31 GB
llm 38                   # or: make run-qwen3.8-27b
```

---

## The servers

**24 GB fits exactly one of these at a time.** The run scripts refuse to start
on top of a live server rather than letting the second one die on the leftover
allocation.

| Alias | Port | Model | Notes |
|---|---|---|---|
| `codemode` | 8081 | Qwen3.6-35B-A3B UD-Q4_K_XL | MoE, 8-of-256 experts. Daily driver. |
| `qwen38` | 8082 | Qwen3.8-27B IQ4_XS + MTP | Dense. `~/llama.cpp-38`, 192k ctx. |
| `beellama` | 8082 | Qwen3.6-27B Q5_K_S + DFlash | Dense. BeeLlama fork, turbo KV. Superseded. |
| `make run-mtp` | 8083 | Qwen3.6-35B-A3B MTP | A/B candidate only, not a daily driver. |
| `codeoff` | — | — | Kills all of them, waits for VRAM to release. |

Two llama.cpp checkouts are in play now:

- **`~/llama.cpp`** — pinned build the 35B-A3B daily driver runs on.
- **`~/llama.cpp-38`** — current upstream, for Qwen3.8. Kept separate so that
  pulling upstream cannot regress the daily driver. Build it with
  `make build-llamacpp-38`.

Logs go to `~/.local/share/llama-logs/{codemode,beellama,codemode-mtp,qwen38}.log`.

Every tunable is an environment variable, so you can A/B without editing files:

```bash
CTX=98304 UBATCH=1024 codemode
CACHE_RAM=0 beellama                    # revert to the previous beellama behaviour
QUANT=UD-Q3_K_XL CTX=131072 qwen38      # the 3-bit fallback
SPEC=none qwen38                        # measure what MTP is actually buying
EFFORT=xhigh qwen38                     # longer thinking traces (was the default)
llm 38 low                              # same knob, positional
```

`llm 38` also takes the effort as a positional argument, validated *before*
`codeoff` runs so a typo cannot cost you a live server.

---

## Tuning notes

Everything here is measured on this box, not inherited from a blog post.

### VRAM budget

The 3090 has 24576 MiB and a display attached. Measured full-load steady state
is around 24150 MiB — roughly **400 MiB of headroom**, which is where the
intermittent `CUDA error: unknown error` crashes come from. Six of them across
21 server starts. Aim for 700+ MiB free.

KV cache is smaller than it looks. From the GGUF metadata — 40 layers,
2 KV heads, K and V length 256 — that is 40960 values per token:

| Config | KV at 131072 ctx |
|---|---|
| `q4_0` (4.5 bits/value) | 2.81 GiB |
| `turbo3` (3.25 bits/value) | 2.03 GiB |

So going from 120064 to 131072 context costs only **242 MiB**, and the most
TurboQuant could ever save here is **800 MiB**. That is worth knowing before
you go chasing KV quantization: on this model the KV is not the expensive part.

The cheaper win is `--no-mmproj-offload`, which keeps the vision projector on
the CPU. The server logs its worst case at **1130 MiB** of VRAM. Vision still
works, image processing is just slower — and if you are using this for coding,
you are not sending images.

### The `-ub` sweep

Prompt eval is the bottleneck for agentic coding, which re-ingests large
contexts constantly. Decode barely moves with `-ub`; prompt eval moves a lot.
Measured with `scripts/sweep.sh`, all at `--ctx-size 131072` unless noted:

| config | VRAM free | pp @16k | pp @48k | pp @96k | tg @96k |
|---|---|---|---|---|---|
| `-ub 512` | 1654 MiB | 3042 | 2838 | 2441 | 70.8 |
| **`-ub 1024`** | **1161 MiB** | **3672** | **3285** | **2798** | **69.5** |
| `-ub 2048` | 476 MiB | 3980 | 3702 | 3065 | 70.1 |
| `-ub 1024`, ctx 98304 | 1442 MiB | 3558 | 3366 | 2813 | 70.9 |

`-ub 1024` is the default: **+15–21% prompt eval for no decode cost**, with
1161 MiB of headroom. `-ub 2048` buys another ~9% but leaves 476 MiB, which is
the regime that produced the `CUDA error: unknown error` crashes — not a trade
worth making on a card that also drives a display.

Dropping context to 98304 frees 281 MiB and makes prompt eval slightly
*worse*. There is no reason to run below 131072 on this box.

### Why no speculative decoding on the 35B-A3B

Every draft variant benchmarks net-negative on Ampere + A3B. A [19-config
benchmark on this exact GPU and model][spec] measured 135.7 tok/s baseline
against 118–131 tok/s for every speculative config, with a bimodal tail down
to 59 tok/s on reasoning prompts *despite* 100% draft acceptance.

The cause is expert saturation: verifying K drafted tokens loads the union of
their expert sets across K positions, so you pay more memory traffic than the
skipped forward passes save. The saturation threshold is ~94 tokens; useful
draft sizes are 5–32.

MTP was worth measuring separately, since its draft head shares the trunk
instead of running a separate model. **Measured: it does not fit.** The MTP
context costs 749 MiB on top of larger weights, and draft acceptance was good
(0.71 token, 88% draft) but irrelevant:

| | VRAM free | tg @1k | tg @16k |
|---|---|---|---|
| baseline, ctx 131072 | 1161 MiB | 124.8 | 112.7 |
| MTP, ctx 131072 | 360 MiB | 145.2 | 2.5 (thrashing) |
| MTP, ctx 98304 | 574 MiB | 146.1 | server died |

+17% decode at 1k context, then it falls over. At 98304 the server crashed
outright with `CUDA error: device not ready` partway through the 16k row.
Making MTP fit means giving up context this box demonstrably runs out of, for
a speedup that only exists at depths it never works at. `run-mtp` is kept for
re-testing on a larger card, not as a daily driver.

### Why DFlash on the 27B

Opposite story on the dense model: DFlash [benchmarks 2.5–3.75×][dflash] with
no measurable accuracy cost. Dense models have no expert-routing penalty, so
speculation pays off exactly where it fails for the MoE.

### Qwen3.8-27B: MTP is a large win, unlike on the MoE

Qwen3.8-27B reports `general.architecture = qwen35`, so current upstream loads
it — there is no `qwen38` arch. The GGUF metadata is what makes the VRAM budget
tractable:

```
qwen35.block_count              = 65     (64 layers + 1 nextn/MTP layer)
qwen35.attention.head_count_kv  = 4
qwen35.attention.key_length     = 256
qwen35.attention.value_length   = 256
qwen35.full_attention_interval  = 4      <-- hybrid
qwen35.nextn_predict_layers     = 1
qwen35.ssm.*                    = ...    <-- SSM layers, constant state
```

**It is a hybrid.** Only every 4th layer is full attention; the rest carry
constant-size SSM state that does not grow with context. So KV is
16 × 4 × (256+256) = 32768 values/token, about **18 KiB/token at `q4_0`** —
not the ~73 KiB/token a naive 65-layer dense calculation gives. Budget from the
metadata, not from the layer count.

The MTP head **ships inside the unsloth quants**. With spec off the server logs
`blk.64.nextn.* -- unused tensor ... ignoring`, which is how you can tell. No
separate draft file is needed; passing ggml-org's standalone
`mtp-Qwen3.8-27B-Q4_0.gguf` would waste 1.6 GiB.

Measured, IQ4_XS at `--ctx-size 131072`, `-ub 1024`:

| config | tg @1k | tg @16k | tg @48k | tg @96k | accept @48k |
|---|---|---|---|---|---|
| spec off | 41.4 | 38.0 | 31.5 | 24.9 | — |
| `draft-mtp` n-max 2 | 76.5 | 68.6 | 51.3 | 44.4 | 0.702 |
| **`draft-mtp` n-max 3** | 67.3 | **76.2** | **54.0** | **49.8** | 0.667 |
| `draft-mtp` n-max 4 | 86.9 | 76.4 | 49.7 | 46.6 | 0.461 |
| `draft-mtp` n-max 6 | 83.2 | 79.5 | 43.8 | 47.2 | 0.404 |

**+63–85% decode**, against the +33% the public recipes claim for this card.
Prompt eval pays 5–7% at depth for it.

`n-max 3` is the default. The widely repeated "n-max 2 for 24 GB cards" is
wrong here: 2 loses at every depth past 1k. Larger drafts win at 1k and lose at
depth as acceptance collapses (0.67 → 0.40 at 48k), and 1k is not where this
box spends its time.

This is the exact opposite of the 35B-A3B result above, for the reason given
there — dense models have no expert-routing penalty, so speculation pays.

### Context ceiling, measured

Native context is 262144. What actually fits, IQ4_XS + MTP:

| `--ctx-size` | VRAM free | verdict |
|---|---|---|
| 131072 | 4106 MiB | fits easily |
| **196608** | **2340 MiB** | **default** |
| 262144 | 422 MiB | loads, then crashes — see VRAM budget above |

The MTP draft context scales with `--ctx-size` too, so the real cost is about
28 KiB/token rather than the 18 KiB/token the KV geometry alone implies. 192k
leaves more headroom than `codemode` runs with (1161 MiB).

Throughput at the 192k default, measured out to 160k of actual prompt:

| prompt | pp tok/s | tg tok/s | accept |
|---|---|---|---|
| 1k | 615 | 64.5 | 0.714 |
| 16k | 1240 | 61.9 | 0.618 |
| 48k | 1085 | 52.9 | 0.615 |
| 96k | 897 | 47.5 | 0.688 |
| 160k | 725 | 39.2 | 0.682 |

It still generates at ~39 tok/s with 145k tokens of context in the slot, which
is the number worth quoting — not the 1k figure.

One caveat on reading these: draft acceptance varies run to run (0.62 vs 0.83
at 16k across two runs of nominally similar configs), and decode tracks
acceptance closely. Treat differences under ~10% between spec configs as noise
unless the acceptance column moves with them.

### `--cache-ram` is not optional

`--cache-idle-slots` requires both `--kv-unified` and a non-zero
`--cache-ram`. With `--cache-ram 0` the server cannot park an idle slot's KV
in host RAM, so switching between two projects reprocesses the whole context
— at 1233 tok/s that is well over a minute per switch. The host has 19 GB free.

8192 turned out to be too small for the dense 27B. Three times in `qwen38.log`:

```
prompt state size  9826.674 MiB exceeds cache size limit 8192.000 MiB, skipping
prompt state size 14439.517 MiB exceeds cache size limit 8192.000 MiB, skipping
prompt state size 16696.064 MiB exceeds cache size limit 8192.000 MiB, skipping
```

Every skip is a full re-prefill on the way back, and this model prefills at
~216 tok/s at depth, not 1233 — minutes, not seconds. `run-qwen3.8-27b.sh` now
sets 12288. The 35B has no skips in its log and stays at 8192.

### Flags that do nothing

`--defrag-thold` is marked `(DEPRECATED)` in the current binary. It was
removed from both run scripts.

[spec]: https://github.com/thc1006/qwen3.6-speculative-decoding-rtx3090
[dflash]: https://github.com/lukaLLM/DFlash_Qwen3.6_27B_LlamaCPP

---

## Benchmarking

`scripts/benchmark.sh` measures short prompts. That is not where this machine
spends its time, so `scripts/bench-ctx.py` measures at 1k / 16k / 48k / 96k
context and reads llama.cpp's own timings.

```bash
make bench PORT=8081 LABEL=baseline   # one server
make bench-ab                         # baseline vs MTP, sequentially
```

`bench-ab` stops whatever is running, benchmarks each config in turn, and
leaves the GPU free. Results land in `results/` as JSON. Restart your daily
driver with `codemode` afterwards.

---

## Repo structure

```
local-llm-ops/
├── Makefile
├── agent/                              # Caddyfile (mTLS :8743) + systemd user units
├── windows/setup.ps1                   # firewall, stay-awake, WSL at logon, wake-on-LAN prep
├── tests/test_arbiter.py               # the arbiter's policy, as tests
├── results/                            # benchmark output
└── scripts/
    ├── build-llamacpp.sh               # build upstream llama-server (CUDA, sm_86)
    ├── download-qwen3.6.sh             # 35B-A3B GGUF + mmproj
    ├── download-qwen3.6-mtp.sh         # same quant, MTP draft head
    ├── download-qwen3.8.sh             # 27B IQ4_XS + UD-Q3_K_XL + mmproj
    ├── download.sh                     # generic GGUF downloader
    ├── run-qwen3.6-35b-a3b.sh          # :8081  codemode
    ├── run-qwen3.6-35b-a3b-mtp.sh      # :8083  A/B candidate
    ├── run-beellama-qwen3.6-27b.sh     # :8082  beellama
    ├── run-qwen3.8-27b.sh              # :8082  dense 27B, upstream + MTP
    ├── run-agent.sh                    # :8090  assistant profile (127.0.0.1, 2 slots, API key)
    ├── arbiter.py                      # who has the GPU: you or the assistant
    ├── agent-setup.sh                  # caddy + user units for agent mode
    ├── llm.sh                          # switch model in one command, status, desk/agent
    ├── codeoff.sh                      # stop everything, wait for VRAM
    ├── _wait-ready.sh                  # poll /health, report VRAM headroom
    ├── bench-ctx.py                    # throughput vs context depth
    └── benchmark.sh                    # short-prompt benchmark
```

---

## Connecting a client

Any OpenAI-compatible tool works. The port picks the model:

```json
{
  "providers": {
    "llamacpp": {
      "apiBase": "http://localhost:8081/v1",
      "apiKey": "not-needed"
    }
  }
}
```

**The port is the whole configuration, so a client pointed at the wrong one
fails silently.** `~/.config/opencode/config.json` had a single `llamacpp`
provider on 8081 for a long time, which meant the 27B on 8082 was unreachable
from opencode — it looked like the model was broken when in fact nothing ever
sent it a request. `beellama.log` showed a clean load, the right chat template,
and then fifteen hours of `all slots are idle` with zero `/v1/` hits, against
4098 request lines in `codemode.log`.

If a model seems dead, count requests in its log before blaming the model:

```bash
grep -c "launch_slot_" ~/.local/share/llama-logs/<server>.log
```

`launch_slot_` is the portable marker — it appears in every build here. Current
upstream does not log `request: POST` at default verbosity, so counting that
alone will tell you a busy server is idle.

opencode now has a second provider, `llamacpp-27b`, on 8082. The model name in
the client must match the server's `--alias`.

Two clients, two separate registries — **adding a model means editing both**:

| Client | File | Key detail |
|---|---|---|
| opencode | `clients/opencode/config.json` (linked) | `provider.<id>.models.<model>`; verify with `opencode models` |
| pi | `~/.pi/agent/models.json` | `providers.<id>.models[].id` must equal the `--alias` |

Provider ids now agree across opencode, pi and `llm.sh`:

| port | server `--alias` | opencode / pi provider |
|---|---|---|
| 8081 | `qwen3.6-35b-a3b` | `llamacpp` / `llama-cpp` |
| 8082 | `qwen3.8-27b` | `llamacpp-27b` |
| 8082 | (DFlash build, no alias) | `beellama` |
| 8083 | `qwen3.6-35b-a3b-mtp` | `llamacpp-mtp` |

opencode uses `llamacpp` where pi uses `llama-cpp` for 8081 — a pre-existing
difference, left alone because renaming a provider invalidates saved sessions
in both clients.

Both are read at startup, so a client already running when you edit the config
will not show the new model until you restart it.

opencode's config is no longer just *described* here — it is tracked under
`clients/opencode/` and symlinked into place:

```bash
clients/link.sh           # link into ~/.config/opencode
clients/link.sh --check   # report without changing anything
```

Only the four config files are linked; `skills/` and `node_modules/` stay out
of the repo. pi's `models.json` and `settings.json` are version-controlled in
the `~/.pi` repo (`pi-agent-setup-repo`), which tracks the live files in
place. Note that `pi-agent-config` also carries copies of both — two repos for
one pair of files is how they drifted apart; `~/.pi` is the one that cannot go
stale.

The opencode provider block, under `provider`:

```json
"llamacpp-27b": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "llama.cpp (dense 27B, :8082)",
  "options": { "baseURL": "http://127.0.0.1:8082/v1" },
  "models": {
    "qwen3.8-27b": {
      "name": "Qwen3.8-27B IQ4_XS (196k)",
      "limit": { "context": 196608, "input": 184000, "output": 16384 }
    }
  }
}
```

The DFlash build lives under its own `beellama` provider, matching the id pi
already uses and the one `llm.sh` prints. It is the same port — only one of
the two can be up at a time.

See [Making opencode compact before the server errors](#making-opencode-compact-before-the-server-errors)
for where the `limit` numbers come from. They are not cosmetic.

pi, under `providers`:

```json
"llamacpp-27b": {
  "baseUrl": "http://127.0.0.1:8082/v1",
  "api": "openai-completions",
  "apiKey": "none",
  "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": true },
  "models": [{
    "id": "qwen3.8-27b",
    "name": "Qwen3.8 27B IQ4_XS + MTP",
    "reasoning": true,
    "input": ["text", "image"],
    "contextWindow": 196608,
    "maxTokens": 32768,
    "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
  }]
}
```

`supportsReasoningEffort` is `true` because it was checked, not assumed: the
same prompt at `low` produced 270 characters of reasoning and at `xhigh` 1040,
with the same final answer.

### Reasoning effort defaults to medium

The chat template's own default is `xhigh`, and that — not the model — is most
of why the dense 27B felt slow next to the MoE. Per-turn, from the logs:

| | Qwen3.8-27B (xhigh) | Qwen3.6-35B-A3B |
|---|---|---|
| wall seconds/turn, p50 | 13.2 | 4.0 |
| p90 | 68.0 | 20.7 |
| generated tokens/turn, p50 | 385 | 192 |
| mean | 897 | 484 |

3.3x slower end to end, while decode is only ~1.3x slower (42 vs 54 tok/s at
depth). The gap is tokens emitted, not tokens per second: at `xhigh` the dense
model writes about twice as much per turn, nearly all of it reasoning trace.

`run-qwen3.8-27b.sh` therefore defaults `EFFORT` to `medium`. Override per
launch with `llm 38 <level>` or `EFFORT=<level> llm 38`.

This is deliberately **not** set client-side. `--reasoning-effort` sets the
server default and llama.cpp still honours a per-request `reasoning_effort`
field, so putting a level in the opencode or pi config would silently override
whatever `llm 38` was started with. Leaving the clients quiet keeps the launch
command the single place that decides.

It applies to the 27B alone: only the `~/llama.cpp-38` build has the flag. The
pinned build that serves the 35B and the MTP candidate has no
`--reasoning-effort` at all, which is why `llm code` and `llm mtp` reject an
argument instead of pretending to accept one.

### Making opencode compact before the server errors

`--no-context-shift` means overflow is a hard error, not a silent slide. This
already happened twice in `qwen38.log`:

```
E srv send_error: request (197289 tokens) exceeds the available context size (196608 tokens)
E srv send_error: request (196620 tokens) exceeds the available context size (196608 tokens)
```

The deepest completion in that log sits at `n_tokens = 196607` — one token
under the wall. The client has to compact first, and opencode only does that
if it is told the truth about the window.

Read out of the opencode binary, the usable window is:

```
usable = limit.input ? (limit.input - compaction.reserved)
                     : (limit.context - maxOutputTokens)
```

Two traps in that one line:

- **`compaction.reserved` is ignored unless `limit.input` is set.** A config
  with `reserved` and no `limit.input` silently does nothing.
- **`preserve_recent_tokens` defaults to `min(15000, max(2000, usable/4))`**,
  so it caps at 15000 no matter how large the window. On a 160k window that
  summarises everything but the last 15k — which is what "it forgot the whole
  session" actually was.

`limit.output` is sent to the server as `max_tokens`, so it is a real cap, not
a declaration. Measured over 2750 turns in `qwen38.log`: p95 = 5076 generated
tokens, p99 = 8294, **max ever = 9755**. Reserving 32768 for output was
costing ~16k of usable window for nothing. 16384 is 1.7x the observed ceiling;
`-n 32768` stays as a server-side backstop.

Global block:

```json
"compaction": { "auto": true, "reserved": 24000, "preserve_recent_tokens": 48000 }
```

Per model, sized so the worst case in flight clears `--ctx-size` with ~10% to
spare:

| opencode model | `--ctx-size` | trigger | worst in flight | headroom |
|---|---|---|---|---|
| `llamacpp-27b/qwen3.8-27b` | 196608 | 160,000 | 176,384 | 20,224 |
| `llamacpp/qwen3.6-35b-a3b` | 131072 | 100,000 | 116,384 | 14,688 |
| `llamacpp-mtp/qwen3.6-35b-a3b-mtp` | 131072 | 100,000 | 116,384 | 14,688 |
| `beellama/qwen3.6-27b-dflash` | 122800 | 92,000 | 108,384 | 14,416 |

trigger = `limit.input - reserved`; worst = trigger + `limit.output`.

Ollama models deliberately carry **no** `limit.input`: a 24000 global reserve
against a 32768 window would trigger compaction at 2000 tokens. Without it the
fallback applies and they trigger at 24576. That leaves no nominal headroom,
which is only acceptable because ollama shifts context instead of erroring.

### The same fix for pi

pi's trigger, from `core/compaction/compaction.js`:

```
shouldCompact:  contextTokens > contextWindow - reserveTokens
DEFAULT:        reserveTokens 16384, keepRecentTokens 20000
```

Simpler than opencode's, and it was overflowing for the same reason. On
defaults with `maxTokens: 32768`:

```
trigger          196608 - 16384 = 180,224
worst in flight  180,224 + 32,768 = 212,992   >  196,608
```

`reserveTokens` has to cover the output plus headroom, and it is global, so
one value serves every model. With `maxTokens` cut to 16384:

| pi model | contextWindow | trigger | worst | headroom |
|---|---|---|---|---|
| `llamacpp-27b/qwen3.8-27b` | 196608 | 159,744 | 176,128 | 20,480 |
| `llama-cpp/qwen3.6-35b-a3b` | 131072 | 94,208 | 110,592 | 20,480 |
| `llamacpp-mtp/qwen3.6-35b-a3b-mtp` | 131072 | 94,208 | 110,592 | 20,480 |
| `beellama/qwen3.6-27b-dflash` | 122800 | 85,936 | 102,320 | 20,480 |

In `~/.pi/agent/settings.json`:

```json
"compaction": { "enabled": true, "reserveTokens": 36864, "keepRecentTokens": 48000 }
```

**`autoCompaction` and `compactionThreshold` were dead keys.** pi 0.84 reads
`settings.compaction.{enabled,reserveTokens,keepRecentTokens}` and nothing
else, so the `compactionThreshold: 0.85` that had been sitting in that file
never did anything. Removed.

A global reserve is why the phantom entries had to go: `qwen2.5-coder-7b` was
registered at `contextWindow: 16384`, and `16384 - 36864` is negative, which
makes `shouldCompact` true on every check. Neither that GGUF nor
`qwen3-coder-30b` is on disk any more, so both are gone from the registry and
from `favorites`.

### Why the 35B cannot have a bigger window

Its KV is cheap — 40 layers, `full_attention_interval: 4` so only 10 carry a
cache, 2 KV heads, 256/256 K and V. At q4_0 that is 5.6 KiB/token, against
18 KiB/token for the dense 27B (16 of 64 layers, 4 KV heads). 131072 costs
0.70 GiB; the native 262144 would cost 1.41 GiB.

It still does not fit, because the model is weight-bound, not KV-bound:

```
Qwen3.6-35B-A3B UD-Q4_K_XL weights   20.82 GiB
free VRAM at server start            22.75 GiB
left for KV + compute buffers         1.93 GiB
```

At 131072 that leaves ~1.2 GiB for compute buffers. At 262144 it leaves ~0.5
GiB, which is the same regime that produces `CUDA error: unknown error` on a
card driving a display. The `n_ctx_seq (131072) < n_ctx_train (262144)` warning
llama.cpp prints on every start is cosmetic at this quant. A smaller quant
(IQ4_XS or Q3_K_XL) would free 3-4 GiB and make the question worth revisiting.

### Switching models

```bash
llm 38        # Qwen3.8-27B    :8082   llamacpp-27b/qwen3.8-27b
llm code      # Qwen3.6-35B    :8081   llamacpp/qwen3.6-35b-a3b
llm bee       # Qwen3.6-27B    :8082   beellama/qwen3.6-27b-dflash
llm off
llm status    # what is serving, on which port, and VRAM left
```

`llm` stops whatever is running first, because 24 GB fits one model. Every
alias now routes through it — `qwen38` is `llm 38`, `codeoff` is `llm off`,
`llms` is `llm status`.

The `run-*.sh` scripts are deliberately not aliased. Called directly they
refuse to start while another server holds the GPU, and that guard is worth
keeping: an accidental `qwen38` should not silently kill a live session, which
on this box means re-prefilling 150k tokens at ~216 tok/s. Stop-then-start is
an intent you express by name, through `llm`; the scripts themselves stay
loud and safe for benchmarks and cold starts.

Client-side you still have to pick the matching model, since the port decides
which one is actually there.

Servers bind `0.0.0.0` with no API key, so anything on your network can reach
them. That is fine behind WSL2's NAT. With mirrored networking (which this box
uses for Tailscale) the Hyper-V firewall decides instead: `windows/setup.ps1`
reports whether 8081-8083 are reachable from the house network, and
`-Apply -BlockInbound` closes them. The agent server binds `127.0.0.1` only.

---

## Agent mode: lending the GPU to the personal assistant

The homelab's personal assistant (Hermes, designed in
`homelab-foundation/docs/assistant.md`) uses the same Qwen3.8-27B as `llm 38`,
but only when you are not using the card. Three pieces, all user-level:

| Piece | What it does |
|---|---|
| `scripts/run-agent.sh` | The agent profile of `run-qwen3.8-27b.sh`: `127.0.0.1:8090`, `--parallel 2`, alias `qwen3.8-27b-agent`, API key, effort `low` by default, log `agent.log`. |
| `scripts/arbiter.py` (`llm-arbiter` unit) | Decides who has the GPU. Starts the agent server only after the card has been free for 10 minutes (2 when the assistant is waiting), stops it when ComfyUI starts or a hold is set. HTTP on `127.0.0.1:8091`. |
| `agent/Caddyfile` (`llm-agent-proxy` unit) | `:8743` with mutual TLS: only the assistant VMs, holding a client certificate from the assistant's private CA, get in. `/v1/*` goes to the model, `/arbiter/*` to the arbiter. |

**Your work always wins, mostly for free.** `llm 38`, `llm code`, `llm bee`,
`llm mtp` and `llm off` run `codeoff` first, and `codeoff` stops every
`llama-server`, the agent's included. The run scripts' guard then refuses to
start anything while another server holds the GPU, and the arbiter's quiet window
keeps the agent from slipping into the few seconds of a model switch.

```bash
llm desk 4     # keep the GPU for yourself for 4 hours (stops the agent's model)
llm agent      # lift the hold; the agent loads its model now if nothing of yours runs
llm status     # adds :8090 and the arbiter's state
```

Things the arbiter cannot see from WSL: GPU programs on the Windows side
(ComfyUI for Windows, games). While the agent server is down it treats VRAM use
above `VRAM_BUSY_MIB` as "someone else has the card"; while it is up, run
`llm desk` before starting a Windows GPU program.

Setup, in order (both check first and change nothing without the flag):

```bash
# in homelab-foundation: CA, server and client certificates, API key
make assistant-pki ARGS=--yes
# here: caddy, the two user units, lingering
make agent-setup ARGS=--yes
# Windows side, elevated PowerShell: :8743 from OPNsense only, stay awake, WSL at logon
powershell.exe -ExecutionPolicy Bypass -File windows\setup.ps1 -Apply
```

`windows/setup.ps1 -Apply -Wol` prepares wake-on-LAN over the powerline adapter
later (IP unbound from the Ethernet adapter so Wi-Fi stays the only network, magic
packet on, Fast Startup off) and prints the MAC for homelab-foundation.

---

## Server flags in use

| Flag | What it does |
|---|---|
| `--ctx-size` | Total KV cache size, input + output |
| `-n` | Max tokens generated per request |
| `--n-gpu-layers 99` | Offload everything to GPU |
| `--flash-attn on` | Required for the fused attention path |
| `--cache-type-k/v` | KV quantization. `q4_0` upstream, `turbo4`/`turbo3_tcq` on the fork |
| `--cache-ram` | Host RAM for idle-slot KV. `0` disables it and `--cache-idle-slots` with it |
| `--kv-unified` | Single shared KV cache; prerequisite for idle-slot caching |
| `--no-mmproj-offload` | Vision projector stays on CPU, frees ~1.1 GiB VRAM |
| `--no-context-shift` | Fail loudly on overflow instead of silently dropping history |
| `--parallel` | Simultaneous inference slots |
| `-b` / `-ub` | Batch and micro-batch. `-ub` drives prompt-eval throughput |
| `--spec-type` | Speculative decoding strategy. `none` for MoE, `draft-mtp` for Qwen3.8 |
| `--spec-draft-n-max` | Tokens drafted per step. 3 on Qwen3.8 here; binary default is 3 |
| `--reasoning-effort` | `minimal`…`max`, passed to the chat template. `default` keeps the template's own |
| `--reasoning-preserve` | Keep thinking across turns. The server tells you when the template supports it |

Qwen3 recommended sampling: `temp=0.6, top_p=0.95, top_k=20, min_p=0.0`.

---

## Troubleshooting

**`CUDA error: unknown error`, usually mid-session**
→ VRAM exhaustion. You are within a few hundred MiB of the limit and the
display driver asked for memory. Lower `CTX` or `UBATCH`, or confirm
`--no-mmproj-offload` is set. `make status` shows current usage.

**`request (N tokens) exceeds the available context size`**
→ The client sent more than `--ctx-size`. With `--no-context-shift` this is a
hard error by design. Raise `CTX` if you have the VRAM, or cap context
client-side.

**Server starts, then dies ~30s later**
→ The run scripts poll `/health` and dump the last 20 log lines on failure,
so the reason should be on screen. Otherwise: `make logs`.

**`ERROR: another llama-server is running`**
→ Working as intended. 24 GB fits one model. Run `codeoff` first.

**`hf: command not found`**
→ `pip install -U huggingface_hub`. The old `huggingface-cli` name is gone.

**`CMake Error: No CMAKE_CUDA_COMPILER could be found`**
→ `nvcc` lives at `/usr/local/cuda/bin/nvcc` and is on nobody's `PATH` — not
in `.bashrc`, not in a non-interactive shell. cmake finds the CUDA *toolkit*
and then fails on the compiler, which reads like a missing install but is not.
`build-llamacpp.sh` now locates it and exports `CUDACXX` itself.

**A model that looks broken but loads fine**
→ Count requests in its log before touching the server. See *Connecting a
client* — the usual cause is a client pointed at the wrong port.

**A health check that hangs instead of failing**
→ On this box a TCP connection to a *closed* port is dropped rather than
refused, so `curl` waits for its own timeout (`rc=28`) instead of returning
immediately. Any probe of a port that might not be listening needs `-m`:

```bash
curl -sf -m 2 "http://127.0.0.1:$port/health"
```

`llm.sh` does this. It is worth remembering before writing any new script that
polls a port.
