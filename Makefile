MODELS_DIR := $(HOME)/models
COMPOSE     := docker compose -f compose/base.yml

# ── Help ─────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
help:
	@echo ""
	@echo "  local-llm-ops — your local LLM command centre"
	@echo ""
	@echo "  Download"
	@echo "    make download-qwen3-35b      Pull Qwen3.6-35B IQ4_NL GGUF from HuggingFace"
	@echo "    make download-qwen3-8b       Pull Qwen3-8B Q8_0 GGUF from HuggingFace"
	@echo ""
	@echo "  Register with Ollama (run once per model)"
	@echo "    make register-qwen3-35b"
	@echo "    make register-qwen3-8b"
	@echo ""
	@echo "  Run via llama.cpp (long sessions, full control)"
	@echo "    make run-qwen3-35b"
	@echo "    make run-qwen3-8b"
	@echo ""
	@echo "  Manage"
	@echo "    make stop                    Stop any running llama.cpp container"
	@echo "    make status                  Show running containers + registered ollama models"
	@echo "    make logs                    Tail llama.cpp server logs"
	@echo ""

# ── Download ──────────────────────────────────────────────────────────────────
download-qwen3-35b:
	./scripts/download.sh unsloth/Qwen3.6-35B-A3B-GGUF \
	  "Qwen3.6-35B-A3B-UD-IQ4_NL.gguf" \
	  $(MODELS_DIR)/Qwen3.6-35B-A3B

download-qwen3-8b:
	./scripts/download.sh unsloth/Qwen3-8B-GGUF \
	  "Qwen3-8B-UD-Q8_0.gguf" \
	  $(MODELS_DIR)/Qwen3-8B

# ── Register with Ollama ──────────────────────────────────────────────────────
register-qwen3-35b:
	ollama create qwen3-35b -f models/qwen3-35b.Modelfile

register-qwen3-8b:
	ollama create qwen3-8b -f models/qwen3-8b.Modelfile

# ── Run via llama.cpp ─────────────────────────────────────────────────────────
run-qwen3-35b:
	$(COMPOSE) -f compose/qwen3-35b.yml up -d
	@echo "llama.cpp running at http://localhost:8080"

run-qwen3-8b:
	$(COMPOSE) -f compose/qwen3-8b.yml up -d
	@echo "llama.cpp running at http://localhost:8080"

# ── Manage ────────────────────────────────────────────────────────────────────
stop:
	$(COMPOSE) down

status:
	@echo "=== llama.cpp ==="
	@docker ps --filter name=llama-server --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "=== Ollama models ==="
	@ollama list

logs:
	docker logs -f llama-server

.PHONY: help \
        download-qwen3-35b download-qwen3-8b \
        register-qwen3-35b register-qwen3-8b \
        run-qwen3-35b run-qwen3-8b \
        stop status logs
