LOG_DIR := $(HOME)/.local/share/llama-logs

.DEFAULT_GOAL := help
help:
	@echo ""
	@echo "  local-llm-ops — native llama.cpp command centre"
	@echo ""
	@echo "  Build"
	@echo "    make build-llamacpp          Build llama-server from source (CUDA, sm_86)"
	@echo "    make update-llamacpp         Pull latest source and rebuild"
	@echo ""
	@echo "  Download"
	@echo "    make download-qwen3.6        Qwen3.6-35B-A3B Q4_K_XL + mmproj"
	@echo "    make download-qwen3.6-mtp    Same quant, MTP draft head (A/B candidate)"
	@echo ""
	@echo "  Run (one at a time — 24 GB fits exactly one model)"
	@echo "    make run-qwen3.6-35b-a3b     35B-A3B  :8081  131k ctx, q4_0 KV   [codemode]"
	@echo "    make run-beellama            27B DFlash :8082 turbo KV           [beellama]"
	@echo "    make run-mtp                 35B-A3B MTP :8083 131k ctx          [A/B only]"
	@echo ""
	@echo "  Measure"
	@echo "    make bench-ab                Baseline vs MTP, sequentially"
	@echo "    make bench PORT=8081 LABEL=x Benchmark one server at 1k/16k/48k/96k ctx"
	@echo ""
	@echo "  Manage"
	@echo "    make stop                    Kill servers, wait for VRAM to release"
	@echo "    make status                  Show running server + VRAM"
	@echo "    make logs                    Tail codemode log"
	@echo "    make logs-beellama           Tail beellama log"
	@echo ""

build-llamacpp:
	bash scripts/build-llamacpp.sh

update-llamacpp:
	git -C $(HOME)/llama.cpp pull && bash scripts/build-llamacpp.sh

download-qwen3.6:
	bash scripts/download-qwen3.6.sh

download-qwen3.6-mtp:
	bash scripts/download-qwen3.6-mtp.sh

# The run scripts detach the server themselves and block until /health answers,
# so no backgrounding or output redirection here.
run-qwen3.6-35b-a3b:
	bash scripts/run-qwen3.6-35b-a3b.sh

run-beellama:
	bash scripts/run-beellama-qwen3.6-27b.sh

run-mtp:
	bash scripts/run-qwen3.6-35b-a3b-mtp.sh

PORT ?= 8081
LABEL ?= adhoc
bench:
	python3 scripts/bench-ctx.py --port $(PORT) --label $(LABEL)

# Sequential by necessity: both configs are ~22 GB and the GPU holds one.
bench-ab:
	bash scripts/codeoff.sh
	bash scripts/run-qwen3.6-35b-a3b.sh
	python3 scripts/bench-ctx.py --port 8081 --label baseline
	bash scripts/codeoff.sh
	bash scripts/run-qwen3.6-35b-a3b-mtp.sh
	python3 scripts/bench-ctx.py --port 8083 --label mtp
	bash scripts/codeoff.sh
	@echo ""
	@echo "Results in results/. Restart your daily driver with: codemode"

stop:
	bash scripts/codeoff.sh

wait:
	@until curl -sf http://localhost:8081/health > /dev/null 2>&1; do \
		printf "."; sleep 3; \
	done && echo " READY"

status:
	@pgrep -la llama-server || echo "llama-server not running"
	@nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader || true

logs:
	@tail -f $(LOG_DIR)/codemode.log

logs-beellama:
	@tail -f $(LOG_DIR)/beellama.log

.PHONY: help build-llamacpp update-llamacpp download-qwen3.6 download-qwen3.6-mtp \
        run-qwen3.6-35b-a3b run-beellama run-mtp bench bench-ab \
        stop wait status logs logs-beellama
