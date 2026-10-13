#!/bin/bash
# Capability-aware smoke test, run on the VM:
#   scripts/vm-run.sh tests/runtime/smoke-test.sh
set -u
cd /opt/llm-self-hosting || exit 1

GW=http://127.0.0.1:4000
MODEL_ID="$(sed -n 's/^MODEL_ID=//p' .env | tail -n 1)"
VM_SIZE="$(sed -n 's/^MODEL_VM_SIZE=//p' .env | tail -n 1)"
if ! PROFILE="$(python3 scripts/model_profile.py resolve "$MODEL_ID" "$VM_SIZE")"; then
  echo "FAIL cannot resolve ${MODEL_ID:-<unset>} for ${VM_SIZE:-<unset>}"
  exit 1
fi
MODEL_REVISION="$(printf '%s' "$PROFILE" | jq -r '.model.revision')"
HAS_REASONING="$(printf '%s' "$PROFILE" | jq -r '.model.capabilities.reasoning')"
HAS_TOOLS="$(printf '%s' "$PROFILE" | jq -r '.model.capabilities.tools')"
CHAT_KWARGS="$(printf '%s' "$PROFILE" | jq -c '.model.smoke.chat_template_kwargs')"
fail=0

check() {
  if [ "$2" = "$3" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (got: $2, want: $3)"
    fail=1
  fi
}

post_chat() {
  curl -sS "$GW/v1/chat/completions" -H 'Content-Type: application/json' -d "$1"
}

echo "model=${MODEL_ID} revision=${MODEL_REVISION} vm_size=${VM_SIZE}"
echo "--- vLLM startup facts"
docker logs llm-model 2>&1 |
  grep -E -o 'GPU KV cache size: [0-9,]+ tokens|Maximum concurrency for [0-9,]+ tokens per request: [0-9.]+x|Model loading took [0-9.]+ GiB' |
  sort -u

echo "--- checks"
check "vLLM /health" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8096/health)" 200
check "gateway /v1/models" "$(curl -s -o /dev/null -w '%{http_code}' "$GW/v1/models")" 200
check "gateway /metrics/" "$(curl -s -o /dev/null -w '%{http_code}' "$GW/metrics/")" 200

if [ "$HAS_REASONING" = true ]; then
  chat_payload="$(jq -cn --argjson kwargs "$CHAT_KWARGS" '{
    model:"local-llm",
    max_tokens:64,
    temperature:0,
    reasoning_effort:"low",
    messages:[{role:"user",content:"Reply with exactly: PONG"}],
    chat_template_kwargs:$kwargs
  }')"
else
  chat_payload="$(jq -cn --argjson kwargs "$CHAT_KWARGS" '{
    model:"local-llm",
    max_tokens:64,
    temperature:0,
    messages:[{role:"user",content:"Reply with exactly: PONG"}],
    chat_template_kwargs:$kwargs
  }')"
fi
chat="$(post_chat "$chat_payload")"
if [ "$(printf '%s' "$chat" | jq -r '.error // empty')" ]; then
  echo "FAIL basic chat: $(printf '%s' "$chat" | jq -c '.error' | cut -c1-300)"
  fail=1
else
  answer="$(printf '%s' "$chat" | jq -r '.choices[0].message.content // empty' | tr -d '[:space:]')"
  check "basic chat output" "$answer" PONG
fi

if [ "$HAS_REASONING" = true ]; then
  reasoning_payload="$(jq -cn '{
    model:"local-llm",
    max_tokens:256,
    temperature:0.2,
    reasoning_effort:"low",
    messages:[{role:"user",content:"What is 17 times 6? Give only the final number."}]
  }')"
  reasoning="$(post_chat "$reasoning_payload")"
  if [ "$(printf '%s' "$reasoning" | jq -r '.error // empty')" ]; then
    echo "FAIL reasoning request: $(printf '%s' "$reasoning" | jq -c '.error' | cut -c1-300)"
    fail=1
  else
    echo "PASS reasoning-capable request"
  fi
else
  echo "SKIP reasoning request (not declared by catalog)"
fi

if [ "$HAS_TOOLS" = true ]; then
  tool_payload="$(jq -cn --argjson kwargs "$CHAT_KWARGS" '{
    model:"local-llm",
    max_tokens:512,
    temperature:0,
    chat_template_kwargs:$kwargs,
    messages:[{role:"user",content:"Read the file /etc/hostname using the tool."}],
    tools:[{type:"function",function:{
      name:"read_file",
      description:"Read a file",
      parameters:{type:"object",properties:{path:{type:"string"}},required:["path"]}
    }}],
    tool_choice:"required"
  }')"
  tool="$(post_chat "$tool_payload")"
  check "tool call name" "$(printf '%s' "$tool" | jq -r '.choices[0].message.tool_calls[0].function.name // empty')" read_file
  echo "tool args: $(printf '%s' "$tool" | jq -c -r '.choices[0].message.tool_calls[0].function.arguments // {}' | cut -c1-120)"
  if [ "$(printf '%s' "$tool" | jq -r '.error // empty')" ]; then
    echo "tool error: $(printf '%s' "$tool" | jq -c .error | cut -c1-300)"
  fi
else
  echo "SKIP tool request (not declared by catalog)"
fi

echo "--- decode speed (512 tokens, single stream)"
decode_payload="$(jq -cn --argjson kwargs "$CHAT_KWARGS" '{
  model:"local-llm",
  max_tokens:512,
  temperature:0,
  ignore_eos:true,
  chat_template_kwargs:$kwargs,
  messages:[{role:"user",content:"Write a detailed explanation of how TCP congestion control works."}]
}')"
start="$(date +%s.%N)"
generated="$(post_chat "$decode_payload")"
end="$(date +%s.%N)"
tokens="$(printf '%s' "$generated" | jq -r '.usage.completion_tokens // 0')"
if [ "$tokens" -gt 0 ]; then
  echo "completion_tokens=$tokens wall=$(echo "$end - $start" | bc | cut -c1-6)s tok/s=$(echo "scale=2; $tokens / ($end - $start)" | bc)"
else
  echo "FAIL decode request: $(printf '%s' "$generated" | jq -c '.error // .' | cut -c1-300)"
  fail=1
fi
docker logs --since 2m llm-model 2>&1 |
  grep -E -o 'Mean acceptance length: [0-9.]+|Avg Draft acceptance rate: [0-9.]+%' |
  tail -2

nvidia-smi --query-gpu=memory.used,memory.total,power.draw --format=csv,noheader

if docker inspect llm-otel-collector >/dev/null 2>&1; then
  echo "--- telemetry (compose.observability.yaml)"
  check "otel-collector health" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:13133/)" 200
  errors="$(docker logs --since 10m llm-otel-collector 2>&1 | grep -c -E '"(error|warn)"|\berror\b' || true)"
  echo "collector error/warn lines in last 10m: $errors"
  docker logs --since 10m llm-otel-collector 2>&1 | grep -E -i 'error|warn' | tail -3 | cut -c1-300
fi

if [ "$fail" = 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME CHECKS FAILED"
exit 1
