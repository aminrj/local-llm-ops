MODELS_DIR := $(HOME)/models
COMPOSE     := docker compose -f compose/base.yml

# ── Help ─────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
help:
	@echo ""
	@echo "  local-llm-ops — your local LLM command centre"
	@echo ""
	@echo "  Setup"
	@echo "    make link-ollama             Symlink all Ollama blobs into ~/models/"
	@echo ""
	@echo "  Native llama.cpp binary (Qwen3.6+)"
	@echo "    make build-llamacpp          Build llama-server from source (CUDA)"
	@echo "    make update-llamacpp         Pull latest source and rebuild"
	@echo ""
	@echo "  Download models"
	@echo "    make download-qwen3.6        Download Qwen3.6-35B-A3B Q4_K_XL + mmproj"
	@echo ""
	@echo "  Register with Ollama (run once per model)"
	@echo "    make register-qwen3-35b      Register qwen3.5:35b-a3b alias"
	@echo "    make register-qwen3-8b       Register qwen3.5:9b alias"
	@echo ""
	@echo "  Run — Docker track (Qwen3.5 and older)"
	@echo "    make run-qwen3.5-35b-a3b     Qwen3.5 35B-A3B  [Docker]"
	@echo "    make run-qwen3-coder-30b     Qwen3-Coder 30B  [Docker, 32k ctx]"
	@echo "    make run-qwen3-coder-next    Qwen3-Coder-Next [Docker, partial offload]"
	@echo "    make run-gemma4-26b          Gemma4 26B       [Docker, 16k ctx]"
	@echo "    make run-gemma4-31b          Gemma4 31B       [Docker, 8k ctx]"
	@echo "    make run-qwen3-8b            Qwen3.5 9B       [Docker, quick test]"
	@echo ""
	@echo "  Run — Native track (Qwen3.6+)"
	@echo "    make run-qwen3.6-35b-a3b     Qwen3.6 35B-A3B  [native, 65k ctx]"
	@echo "    make wait                    Wait until llama.cpp is ready at :8081"
	@echo ""
	@echo "  Manage"
	@echo "    make stop                    Stop Docker containers and native llama-server"
	@echo "    make status                  Show running containers + registered ollama models"
	@echo "    make logs                    Tail llama.cpp server logs"
	@echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────
link-ollama:
	./scripts/link-from-ollama.sh

# ── Native llama.cpp binary ───────────────────────────────────────────────────
build-llamacpp:
	bash scripts/build-llamacpp.sh

update-llamacpp:
	git -C $(HOME)/llama.cpp pull && bash scripts/build-llamacpp.sh

# ── Download models ───────────────────────────────────────────────────────────
download-qwen3.6:
	bash scripts/download-qwen3.6.sh

# ── Register with Ollama ──────────────────────────────────────────────────────
register-qwen3-35b:
	ollama create qwen3-35b -f models/qwen3-35b.Modelfile

register-qwen3-8b:
	ollama create qwen3-8b -f models/qwen3-8b.Modelfile

# ── Run via llama.cpp ─────────────────────────────────────────────────────────
run-qwen3-coder-30b:
	$(COMPOSE) -f compose/qwen3-coder-30b.yml up -d
	@echo "llama.cpp running at http://localhost:8081"

run-qwen3.5-35b-a3b: run-qwen3-35b
run-qwen3-35b:
	$(COMPOSE) -f compose/qwen3.5-35b-a3b.yml up -d
	@echo "llama.cpp running at http://localhost:8081"

run-qwen3.6-35b-a3b:
	@bash scripts/run-qwen3.6-35b-a3b.sh &
	@echo "llama.cpp running at http://localhost:8081"

link-qwen3.6-35b-a3b:
	./scripts/link-from-ollama.sh qwen3.6 35b-a3b-q4_K_M

run-qwen3-coder-next:
	$(COMPOSE) -f compose/qwen3-coder-next.yml up -d
	@echo "llama.cpp running at http://localhost:8081 (partial CPU offload — slower)"

run-gemma4-26b:
	$(COMPOSE) -f compose/gemma4-26b.yml up -d
	@echo "llama.cpp running at http://localhost:8081"

run-gemma4-31b:
	$(COMPOSE) -f compose/gemma4-31b.yml up -d
	@echo "llama.cpp running at http://localhost:8081"

run-qwen3-8b:
	$(COMPOSE) -f compose/qwen3-8b.yml up -d
	@echo "llama.cpp running at http://localhost:8081"

# ── Manage ────────────────────────────────────────────────────────────────────
stop:
	-$(COMPOSE) down 2>/dev/null
	-pkill -f llama-server 2>/dev/null

wait:
	@until curl -s http://localhost:8081/health > /dev/null 2>&1; do \
		printf "."; sleep 3; \
	done && echo " READY"

status:
	@echo "=== llama.cpp ==="
	@docker ps --filter name=llama-server --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "=== Ollama models ==="
	@ollama list

logs:
	docker logs -f llama-server

.PHONY: help link-ollama \
	    build-llamacpp update-llamacpp download-qwen3.6 \
	    register-qwen3-35b register-qwen3-8b \
	    run-qwen3-coder-30b run-qwen3.5-35b-a3b run-qwen3-35b \
	    run-qwen3.6-35b-a3b link-qwen3.6-35b-a3b \
	    run-qwen3-coder-next run-gemma4-26b run-gemma4-31b run-qwen3-8b \
	    stop wait status logs
