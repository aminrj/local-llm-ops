# local-llm-ops

Personal infrastructure for running local LLMs on a single RTX 3090.
One GPU, 24 GB, three server configs, one `make` command.

---

## The idea

Everything runs as a natively built `llama-server` binary. There is no Docker
track any more — it was removed in `53e4f1e` because the images lagged behind
Qwen3.6 architecture support.

Two binaries are in play:

- **`~/llama.cpp`** — upstream. Runs the 35B-A3B MoE daily driver.
- **`~/beellama.cpp`** — fork. Runs the dense 27B, for its DFlash speculative
  decoding and TurboQuant (`turbo4` / `turbo3_tcq`) KV cache types, neither of
  which is upstream yet.

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

---

## The servers

**24 GB fits exactly one of these at a time.** The run scripts refuse to start
on top of a live server rather than letting the second one die on the leftover
allocation.

| Alias | Port | Model | Notes |
|---|---|---|---|
| `codemode` | 8081 | Qwen3.6-35B-A3B UD-Q4_K_XL | MoE, 8-of-256 experts. Daily driver. |
| `beellama` | 8082 | Qwen3.6-27B Q5_K_S + DFlash | Dense. BeeLlama fork, turbo KV. |
| `make run-mtp` | 8083 | Qwen3.6-35B-A3B MTP | A/B candidate only, not a daily driver. |
| `codeoff` | — | — | Kills all of them, waits for VRAM to release. |

Logs go to `~/.local/share/llama-logs/{codemode,beellama,codemode-mtp}.log`.

Every tunable is an environment variable, so you can A/B without editing files:

```bash
CTX=98304 UBATCH=1024 codemode
CACHE_RAM=0 beellama       # revert to the previous beellama behaviour
```

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

### `--cache-ram` is not optional

`--cache-idle-slots` requires both `--kv-unified` and a non-zero
`--cache-ram`. With `--cache-ram 0` the server cannot park an idle slot's KV
in host RAM, so switching between two projects reprocesses the whole context
— at 1233 tok/s that is well over a minute per switch. The host has 19 GB free.
Both run scripts set `--cache-ram 8192`.

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
├── results/                            # benchmark output
└── scripts/
    ├── build-llamacpp.sh               # build upstream llama-server (CUDA, sm_86)
    ├── download-qwen3.6.sh             # 35B-A3B GGUF + mmproj
    ├── download-qwen3.6-mtp.sh         # same quant, MTP draft head
    ├── download.sh                     # generic GGUF downloader
    ├── run-qwen3.6-35b-a3b.sh          # :8081  codemode
    ├── run-qwen3.6-35b-a3b-mtp.sh      # :8083  A/B candidate
    ├── run-beellama-qwen3.6-27b.sh     # :8082  beellama
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

Servers bind `0.0.0.0` with no API key, so anything on your network can reach
them. That is fine behind WSL2's NAT; think twice on a shared network.

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
| `--spec-type` | Speculative decoding strategy. `none` for MoE, `draft-mtp`/`dflash` to test |

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
