LOG_FILE := /tmp/llama-server.log

.DEFAULT_GOAL := help
help:
	@echo ""
	@echo "  local-llm-ops — native llama.cpp command centre"
	@echo ""
	@echo "  Build"
	@echo "    make build-llamacpp          Build llama-server from source (CUDA)"
	@echo "    make update-llamacpp         Pull latest source and rebuild"
	@echo ""
	@echo "  Download"
	@echo "    make download-qwen3.6        Download Qwen3.6-35B-A3B Q4_K_XL + mmproj"
	@echo ""
	@echo "  Run"
	@echo "    make run-qwen3.6-35b-a3b     Qwen3.6 35B-A3B [native, 131k ctx, q4_0 KV]"
	@echo "    make wait                    Wait until llama-server is ready at :8081"
	@echo ""
	@echo "  Manage"
	@echo "    make stop                    Kill running llama-server"
	@echo "    make status                  Show llama-server process"
	@echo "    make logs                    Tail llama-server logs"
	@echo ""

build-llamacpp:
	bash scripts/build-llamacpp.sh

update-llamacpp:
	git -C $(HOME)/llama.cpp pull && bash scripts/build-llamacpp.sh

download-qwen3.6:
	bash scripts/download-qwen3.6.sh

run-qwen3.6-35b-a3b:
	@bash scripts/run-qwen3.6-35b-a3b.sh > $(LOG_FILE) 2>&1 &
	@echo "llama-server starting — logs: $(LOG_FILE)"

stop:
	-pkill -f llama-server 2>/dev/null || true

wait:
	@until curl -s http://localhost:8081/health > /dev/null 2>&1; do \
		printf "."; sleep 3; \
	done && echo " READY"

status:
	@pgrep -la llama-server || echo "llama-server not running"

logs:
	@tail -f $(LOG_FILE)

.PHONY: help build-llamacpp update-llamacpp download-qwen3.6 \
        run-qwen3.6-35b-a3b stop wait status logs
