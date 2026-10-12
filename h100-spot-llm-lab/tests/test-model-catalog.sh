#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NC40=Standard_NC40ads_H100_v5
NC80=Standard_NC80adis_H100_v5

python3 scripts/model_profile.py validate >/dev/null

nc40_ids="$(python3 scripts/model_profile.py list "$NC40" | jq -r '.[].id' | sort)"
nc80_ids="$(python3 scripts/model_profile.py list "$NC80" | jq -r '.[].id' | sort)"
[ "$(printf '%s\n' "$nc40_ids" | sed '/^$/d' | wc -l | tr -d ' ')" = 6 ]
[ "$(printf '%s\n' "$nc80_ids" | sed '/^$/d' | wc -l | tr -d ' ')" = 8 ]
comm -23 <(printf '%s\n' "$nc40_ids") <(printf '%s\n' "$nc80_ids") | grep . && {
  echo "NC80 must include every NC40 model" >&2
  exit 1
}
printf '%s\n' "$nc80_ids" | grep -qx qwen2.5-72b-instruct
printf '%s\n' "$nc80_ids" | grep -qx qwen3-next-80b-a3b-instruct
! printf '%s\n' "$nc40_ids" | grep -qx qwen2.5-72b-instruct

python3 scripts/model_profile.py resolve qwen3.8-27b-fp8 "$NC40" |
  jq -e '.profile.status == "validated" and .profile.tensor_parallel_size == 1' >/dev/null
if python3 scripts/model_profile.py resolve qwen2.5-72b-instruct "$NC40" >/dev/null 2>&1; then
  echo "incompatible NC40 profile unexpectedly resolved" >&2
  exit 1
fi

MODEL_CATALOG="$PWD/config/models.json" \
MODEL_ID=qwen3.8-27b-fp8 \
MODEL_VM_SIZE="$NC80" \
MODEL_COMMAND_ONLY=1 \
  python3 scripts/serve_model.py |
  jq -e '
    index("--tensor-parallel-size") as $tp |
    index("--served-model-name") as $name |
    .[$tp + 1] == "2" and .[$name + 1] == "qwen3.8-27b-fp8"
  ' >/dev/null

MODEL_CATALOG="$PWD/config/models.json" \
MODEL_ID=gpt-oss-120b \
MODEL_COMMAND_ONLY=1 \
  python3 scripts/download_model.py |
  jq -e '
    index("openai/gpt-oss-120b") != null and
    index("model-*.safetensors") != null and
    index("original/*") == null and
    index("metal/*") == null
  ' >/dev/null

tmp_catalog="$(mktemp)"
trap 'rm -f "$tmp_catalog"' EXIT
jq '.models += [.models[0]]' config/models.json > "$tmp_catalog"
if python3 scripts/model_profile.py --catalog "$tmp_catalog" validate >/dev/null 2>&1; then
  echo "duplicate model id unexpectedly validated" >&2
  exit 1
fi
jq '.models[0].access = "gated"' config/models.json > "$tmp_catalog"
if python3 scripts/model_profile.py --catalog "$tmp_catalog" validate >/dev/null 2>&1; then
  echo "gated model unexpectedly validated" >&2
  exit 1
fi
jq '.models[0].vm_profiles.Standard_NC40ads_H100_v5.vllm_args += ["--model", "override"]' \
  config/models.json > "$tmp_catalog"
if python3 scripts/model_profile.py --catalog "$tmp_catalog" validate >/dev/null 2>&1; then
  echo "managed vLLM argument override unexpectedly validated" >&2
  exit 1
fi

for file in scripts/*.sh scripts/lib/*.sh infra/*.sh tests/*.sh; do
  bash -n "$file"
done
python3 -m py_compile scripts/model_profile.py scripts/download_model.py scripts/serve_model.py scripts/realtext.py

if command -v docker >/dev/null 2>&1; then
  MODEL_VM_SIZE="$NC40" docker compose -f compose.yaml config -q
  MODEL_VM_SIZE="$NC40" \
    TELEMETRY_UAMI_CLIENT_ID=test \
    AZMON_APPLICATION_ID=test \
    AZMON_TRACES_ENDPOINT=https://example.test/traces \
    AZMON_LOGS_ENDPOINT=https://example.test/logs \
    AZMON_METRICS_ENDPOINT=https://example.test/metrics \
    docker compose -f compose.yaml -f compose.observability.yaml config -q
fi

if printf '' | scripts/launch.sh >/dev/null 2>&1; then
  echo "interactive launcher unexpectedly accepted noninteractive stdin" >&2
  exit 1
fi

echo "model catalog tests: PASS"
