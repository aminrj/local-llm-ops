#!/bin/bash
BACKEND=${1:-ollama}
MODEL=${2:-qwen3.5:35b-a3b-q4_K_M}

OLLAMA_URL="http://localhost:11434/v1"
LLAMACPP_URL="http://localhost:8080/v1"
URL=$([ "$BACKEND" = "ollama" ] && echo $OLLAMA_URL || echo $LLAMACPP_URL)

PROMPTS=(
  "short:Write a fibonacci function in Rust"
  "medium:Implement a thread-safe LRU cache in Rust with a capacity limit using Arc and Mutex"
  "long:Design and implement a JWT authentication middleware that works across Rust, TypeScript and Python services including token refresh and role-based access control"
)

echo "=== Benchmark: $BACKEND / $MODEL ==="
echo "Time: $(date)"
echo ""

# Warmup request -- not measured, just primes the model
echo "Warming up..."
curl -s "$URL/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5,\"stream\":false}" > /dev/null
sleep 2

for entry in "${PROMPTS[@]}"; do
  label="${entry%%:*}"
  prompt="${entry#*:}"
  echo "--- $label prompt ---"
  START=$(date +%s%N)
  RESPONSE=$(curl -s "$URL/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":512,\"stream\":false,\"temperature\":0.6,\"top_p\":0.95,\"top_k\":20}")
  END=$(date +%s%N)
  ELAPSED=$(( (END - START) / 1000000 ))
  COMPLETION_TOKENS=$(echo $RESPONSE | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}).get('completion_tokens',0))" 2>/dev/null)
  PROMPT_TOKENS=$(echo $RESPONSE | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens',0))" 2>/dev/null)
  TOKS_PER_SEC=$(python3 -c "print(round($COMPLETION_TOKENS/($ELAPSED/1000),1))" 2>/dev/null)
  echo "  Prompt tokens:     $PROMPT_TOKENS"
  echo "  Completion tokens: $COMPLETION_TOKENS"
  echo "  Time:              ${ELAPSED}ms"
  echo "  Speed:             ${TOKS_PER_SEC} tok/s"
  echo ""
  sleep 3  # let VRAM settle between runs
done

echo "--- VRAM ---"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
