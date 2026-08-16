LOG_DIR := $(HOME)/.local/share/llama-logs

.DEFAULT_GOAL := help
help:
	@echo ""
	@echo "  local-llm-ops — native llama.cpp command centre"
	@echo ""
	@echo "  Build"
	@echo "    make build-llamacpp          Build llama-server from source (CUDA, sm_86)"
	@echo "    make build-llamacpp-38       Build second checkout for Qwen3.8 (~/llama.cpp-38)"
	@echo "    make update-llamacpp         Pull latest source and rebuild"
	@echo ""
	@echo "  Download"
	@echo "    make download-qwen3.6        Qwen3.6-35B-A3B Q4_K_XL + mmproj"
	@echo "    make download-qwen3.6-mtp    Same quant, MTP draft head (A/B candidate)"
	@echo "    make download-qwen3.8        Qwen3.8-27B IQ4_XS + UD-Q3_K_XL + MTP head"
	@echo ""
	@echo "  Run (one at a time — 24 GB fits exactly one model)"
	@echo "    make run-qwen3.6-35b-a3b     35B-A3B  :8081  131k ctx, q4_0 KV   [codemode]"
	@echo "    make run-beellama            27B DFlash :8082 turbo KV           [beellama]"
	@echo "    make run-qwen3.8-27b         27B dense :8082  QUANT= CTX= SPEC=mtp"
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

download-qwen3.8:
	bash scripts/download-qwen3.8.sh

# Second checkout: upstream support for Qwen3.8 without touching the build the
# 35B-A3B daily driver runs on.
build-llamacpp-38:
	LLAMA_DIR=$(HOME)/llama.cpp-38 bash scripts/build-llamacpp.sh

# The run scripts detach the server themselves and block until /health answers,
# so no backgrounding or output redirection here.
run-qwen3.6-35b-a3b:
	bash scripts/run-qwen3.6-35b-a3b.sh

run-beellama:
	bash scripts/run-beellama-qwen3.6-27b.sh

run-qwen3.8-27b:
	bash scripts/run-qwen3.8-27b.sh

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

.PHONY: help build-llamacpp build-llamacpp-38 update-llamacpp download-qwen3.6 download-qwen3.6-mtp download-qwen3.8 \
        run-qwen3.6-35b-a3b run-beellama run-mtp run-qwen3.8-27b bench bench-ab \
        stop wait status logs logs-beellama
