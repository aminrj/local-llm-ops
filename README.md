# local-llm-ops

Personal infrastructure for running local LLMs on a single GPU machine.  
One GGUF file, two serving backends, one `make` command.

---

## The idea

Two tracks depending on model generation:

- **Docker track** — Qwen3.5 and older, via `docker compose`. Simple, no build step.
- **Native track** — Qwen3.6+, via a locally built `llama-server` binary. Required because the Docker image doesn't yet support Qwen3.6 architectures.

Both expose an OpenAI-compatible API at `http://localhost:8081/v1`.

---

## Prerequisites

| Tool | Install |
|---|---|
| [Docker](https://docs.docker.com/engine/install/) + [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) | for Docker track |
| [Ollama](https://ollama.com) | `curl -fsSL https://ollama.com/install.sh \| sh` |
| `hf` (HuggingFace CLI) | `pip install huggingface_hub` |
| CUDA toolkit + cmake | for native llama.cpp build |

---

## Quick start

### Docker track — Qwen3.5 and older

```bash
git clone https://github.com/yourname/local-llm-ops
cd local-llm-ops

# Start Qwen3.5 35B via Docker
make run-qwen3.5-35b-a3b
# API at http://localhost:8081/v1

make stop
```

### Native track — Qwen3.6+

```bash
# 1. Build the binary once (requires CUDA toolkit + cmake)
make build-llamacpp

# 2. Download the model (once)
make download-qwen3.6

# 3. Run
make run-qwen3.6-35b-a3b
# API at http://localhost:8081/v1

# Optional: wait until server is ready
make wait

# Stop
make stop
```

---

## When to use which backend

| Situation | Command | Why |
|---|---|---|
| Quick question, small task | `ollama run qwen3-8b` | Fast startup, low overhead |
| Long coding session (Qwen3.5) | `make run-qwen3.5-35b-a3b` | 65k context, KV cache, flash-attn |
| Long coding session (Qwen3.6) | `make run-qwen3.6-35b-a3b` | Native binary, latest model support |
| Trying a new model | `ollama run <model>` | Easy, no config needed |
| You need 32k+ context reliably | llama.cpp | Ollama silently caps context |
| Multiple parallel requests | llama.cpp | Set `--parallel` in compose/script |

---

## Repo structure

```
local-llm-ops/
├── Makefile                        # everything you need day-to-day
├── models/
│   ├── qwen3-35b.Modelfile         # Ollama model registration
│   └── qwen3-8b.Modelfile
├── compose/                        # Docker track (Qwen3.5 and older)
│   ├── base.yml                    # shared Docker settings (GPU, volume, port)
│   ├── qwen3.5-35b-a3b.yml
│   └── qwen3-8b.yml
└── scripts/
    ├── build-llamacpp.sh           # build native llama-server from source
    ├── run-qwen3.6-35b-a3b.sh      # native track launcher for Qwen3.6
    ├── download-qwen3.6.sh         # download Qwen3.6 GGUF + mmproj
    ├── download.sh                 # generic GGUF downloader
    └── register-ollama.sh          # register all Modelfiles at once
```

---

## All make targets

```
make help                    Show this list

# Native llama.cpp binary
make build-llamacpp          Build llama-server from ~/llama.cpp source (CUDA)
make update-llamacpp         Pull latest source and rebuild

# Download
make download-qwen3.6        Download Qwen3.6-35B Q4_K_XL GGUF + mmproj

# Ollama registration
make register-qwen3-35b      Create ollama model from local GGUF
make register-qwen3-8b

# Docker track (Qwen3.5 and older)
make run-qwen3.5-35b-a3b     Start llama.cpp server via Docker
make run-qwen3-coder-30b
make run-qwen3-8b
make run-gemma4-26b
make run-gemma4-31b

# Native track (Qwen3.6+)
make run-qwen3.6-35b-a3b     Start native llama-server (background)
make wait                    Poll http://localhost:8081/health until ready

# Manage
make stop                    Stop Docker containers + kill llama-server
make status                  Show Docker + Ollama status
make logs                    Tail llama.cpp server logs
```

---

## Connecting OpenCode (or any OpenAI-compatible client)

Define both backends in your OpenCode config:

```json
{
  "providers": {
    "ollama": {
      "apiBase": "http://localhost:11434/v1",
      "apiKey": "ollama"
    },
    "llamacpp": {
      "apiBase": "http://localhost:8080/v1",
      "apiKey": "not-needed"
    }
  }
}
```

Switch mid-session with `/model llamacpp/qwen3-35b` or `/model ollama/qwen3-8b`. No restart required.

The same `apiBase` works with any tool that supports OpenAI-compatible endpoints: [Continue.dev](https://continue.dev), [Open WebUI](https://github.com/open-webui/open-webui), `curl`, Python's `openai` package, etc.

---

## Adding a new model

When a new model drops, you add two files and one `make` target — nothing else changes.

**1. Create a Modelfile** (for Ollama):

```
# models/newmodel.Modelfile
FROM /home/amine/models/NewModel/newmodel.gguf

PARAMETER temperature 0.6
PARAMETER top_p 0.95
PARAMETER top_k 20
PARAMETER num_ctx 32768
```

**2. Create a compose override** (for llama.cpp):

```yaml
# compose/newmodel.yml
services:
  llama-server:
    command: >
      -m /models/NewModel/newmodel.gguf
      --port 8080 --host 0.0.0.0
      --ctx-size 32768
      -n 4096
      --n-gpu-layers 99
      --flash-attn
```

**3. Add targets to the Makefile**:

```makefile
download-newmodel:
    ./scripts/download.sh owner/repo "newmodel.gguf" $(MODELS_DIR)/NewModel

register-newmodel:
    ollama create newmodel -f models/newmodel.Modelfile

run-newmodel:
    $(COMPOSE) -f compose/newmodel.yml up -d
    @echo "llama.cpp running at http://localhost:8080"
```

**4. Download, register, run**:

```bash
make download-newmodel
make register-newmodel
make run-newmodel
```

---

## llama.cpp server flags explained

Key flags used in the compose files and what they do:

| Flag | What it does |
|---|---|
| `--ctx-size` | Total KV cache size (input + output). 65536 = 64k tokens |
| `-n` | Max tokens to generate per request |
| `--n-gpu-layers` | Layers offloaded to GPU. 99 = all (for models that fit) |
| `--flash-attn` | Flash Attention 2 — faster, lower VRAM. Always enable if supported |
| `--cache-type-k q8_0` | Quantize KV cache keys to 8-bit. Saves VRAM, negligible quality loss |
| `--cache-type-v q8_0` | Same for values |
| `--cache-ram` | RAM budget (MB) for CPU-side KV cache overflow |
| `--parallel` | Number of simultaneous inference slots |
| `--temp`, `--top-p`, `--top-k`, `--min-p` | Sampling defaults (overridable per request) |

The Qwen3 recommended sampling params are `temp=0.6, top_p=0.95, top_k=20, min_p=0.0`.  
For thinking/reasoning mode, use `temp=0.6` with the `<think>` prompt format.

---

## Using a gated model

For models that require HuggingFace authentication:

```bash
export HF_TOKEN=hf_yourtoken
make download-<model>
```

Or add it to a `.env` file (already gitignored):

```bash
echo "HF_TOKEN=hf_yourtoken" >> .env
```

Then `source .env` before running make.

---

## GPU memory reference

Rough VRAM requirements at these quantizations on a single GPU:

| Model | Quant | VRAM | Notes |
|---|---|---|---|
| Qwen3-8B | Q8_0 | ~10 GB | All layers on GPU |
| Qwen3.6-35B A3B | IQ4_NL | ~24 GB | MoE: only active experts loaded |
| Qwen3.6-35B A3B | Q8_0 | ~40 GB | Higher quality, needs A100/H100 |

KV cache adds on top: at 65k context, q8_0 KV costs ~2–4 GB depending on model dimensions.

---

## Troubleshooting

**`docker: Error response from daemon: could not select device driver "nvidia"`**  
→ NVIDIA Container Toolkit not installed or not configured. See [install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

**`ollama create` fails with "file not found"**  
→ The `FROM` path in the Modelfile must be an absolute path to the GGUF. Update it to match your `$HOME`.

**llama.cpp exits immediately (Docker)**  
→ Run `make logs` to see the error. Most common: wrong model path, VRAM OOM, or unsupported flag for the image version.

**Qwen3.6 fails to load in Docker**  
→ The Docker image doesn't support Qwen3.6 architecture yet. Use the native track: `make build-llamacpp` then `make run-qwen3.6-35b-a3b`.

**`make run-qwen3.6-35b-a3b` returns immediately with no server**  
→ The native script runs in the background. Check `ps aux | grep llama-server` or run `make wait` to poll until ready. Logs go to stdout of the background process; redirect if needed: `bash scripts/run-qwen3.6-35b-a3b.sh > /tmp/llama.log 2>&1 &`.

**Context gets silently truncated in Ollama**  
→ Ollama caps `num_ctx` at model creation time. If you need more than 32k reliably, use llama.cpp.
