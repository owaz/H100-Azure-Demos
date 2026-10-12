#!/usr/bin/env bash
# Sync this repo's working tree to /opt/llm-self-hosting on the VM through
# `az vm run-command` (the VM has no inbound path and needs no Git access),
# then optionally start the stack.
#
#   scripts/deploy.sh          # sync files only
#   scripts/deploy.sh up       # sync, then `docker compose up -d` in the background
#   DEPLOY_MODEL=0 scripts/deploy.sh sync   # sync with no selected/running model
#   COMPOSE_FILES="-f compose.yaml" scripts/deploy.sh up   # model + gateway only
#
# By default `up` starts compose.yaml plus the telemetry overlay. The ngrok
# overlay is added automatically when both NGROK_AUTHTOKEN and NGROK_URL are
# set in .env. COMPOSE_FILES overrides the automatic selection.
#
# Tracked and untracked-but-not-ignored files are sent as the payload.
# Secrets: put them in this machine's .env (gitignored; same keys as
# .env.example). Only its non-empty KEY=value lines are sent, and
# scripts/merge-env.sh merges them into the VM's .env. Keys left empty locally
# keep their VM values. The secrets pass through the run-command script; the VM-side
# copy of that script is truncated after use.
#
# MODEL_ID selects a checked-in config/models.json entry. The actual VM size
# must have a matching profile or deployment stops before syncing.
#
# TELEMETRY_UAMI_CLIENT_ID is looked up from the ingestion identity attached to
# the VM (id-llm-ingest-<region>, attached by infra/provision-spot-vm.sh) and
# overrides any local value: the identities are region-locked, so only the
# attached one can authenticate.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
ACTION="${1:-sync}"
case "$ACTION" in sync|up) ;; *) echo "usage: deploy.sh [sync|up]" >&2; exit 2 ;; esac
DEPLOY_MODEL="${DEPLOY_MODEL:-1}"
case "$DEPLOY_MODEL" in
  0|1) ;;
  *) echo "ERROR: DEPLOY_MODEL must be 0 or 1" >&2; exit 2 ;;
esac
if [ "$ACTION" = up ] && [ "$DEPLOY_MODEL" = 0 ]; then
  echo "ERROR: DEPLOY_MODEL=0 supports sync only; model services cannot start without a model" >&2
  exit 2
fi
REMOTE_DIR="/opt/llm-self-hosting"
COMPOSE_FILES_B64="$(printf '%s' "${COMPOSE_FILES:-}" | base64 -w0)"

PAYLOAD="$(git ls-files -z --cached --others --exclude-standard \
  | tar --null -T - -czf - | base64 -w0)"
echo "payload: $(( ${#PAYLOAD} / 1024 )) KiB (base64)"

# Resolve the VM once here; scripts/vm-run.sh uses RESOURCE_GROUP + VM_NAME.
SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id -o tsv | tr -d '[:space:]')}"   # default: the az CLI's current subscription
: "${RESOURCE_GROUP:?set RESOURCE_GROUP to the lab resource group}"
if [ -z "${VM_NAME:-}" ]; then
  # shellcheck source=lib/find-vm.sh
  . scripts/lib/find-vm.sh
  rc=0; find_stack_vm || rc=$?
  if [ "$rc" = 1 ]; then echo "no stack VM found in resource group ${RESOURCE_GROUP}; run infra/provision-spot-vm.sh" >&2; exit 1; fi
  [ "$rc" = 0 ] || exit 1
  VM_NAME="$FOUND_VM"
fi
export SUBSCRIPTION RESOURCE_GROUP VM_NAME

VM_SIZE="$(az vm show --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --query hardwareProfile.vmSize -o tsv | tr -d '\r')"
case "$VM_SIZE" in
  Standard_NC40ads_H100_v5|Standard_NC80adis_H100_v5) ;;
  *)
  echo "ERROR: unsupported VM size '${VM_SIZE}' for ${VM_NAME}; expected Standard_NC40ads_H100_v5 or Standard_NC80adis_H100_v5" >&2
  exit 2
  ;;
esac

ENV_LINES=""
if [ -f .env ]; then
  ENV_LINES="$(tr -d '\r' < .env | grep -E '^[A-Za-z_][A-Za-z0-9_]*=.+' || true)"
fi
ENV_MODEL_ID="$(printf '%s\n' "$ENV_LINES" | sed -n 's/^MODEL_ID=//p' | tail -n 1)"
echo "VM size: ${VM_SIZE}"

ENV_LINES="$(printf '%s\n' "$ENV_LINES" | grep -v \
  -e '^MODEL_ID=' \
  -e '^MODEL_VM_SIZE=' \
  -e '^MODEL_REPO=' \
  -e '^MODEL_REVISION=' \
  -e '^MODEL_DIR=' \
  -e '^LLM_MODEL=' \
  -e '^QWEN38_27B_' \
  -e '^$' || true)"
if [ "$DEPLOY_MODEL" = 1 ]; then
  MODEL_ID="${MODEL_ID:-${ENV_MODEL_ID:-qwen3.8-27b-fp8}}"
  if ! PROFILE_JSON="$(python3 scripts/model_profile.py resolve "$MODEL_ID" "$VM_SIZE")"; then
    echo "ERROR: MODEL_ID '${MODEL_ID}' cannot be deployed on ${VM_SIZE}" >&2
    exit 2
  fi
  PROFILE_STATUS="$(printf '%s' "$PROFILE_JSON" | jq -r '.profile.status')"
  PROFILE_TP="$(printf '%s' "$PROFILE_JSON" | jq -r '.profile.tensor_parallel_size')"
  PROFILE_REPO="$(printf '%s' "$PROFILE_JSON" | jq -r '.model.repo')"
  PROFILE_REVISION="$(printf '%s' "$PROFILE_JSON" | jq -r '.model.revision')"
  echo "Model: ${MODEL_ID} (${PROFILE_STATUS}, tensor parallel ${PROFILE_TP})"
  echo "Checkpoint: ${PROFILE_REPO}@${PROFILE_REVISION}"
  if [ "$PROFILE_STATUS" = candidate ]; then
    echo "WARNING: this exact model/VM profile is a candidate and has not yet been hardware-validated" >&2
  fi
  ENV_LINES="${ENV_LINES:+$ENV_LINES$'\n'}MODEL_ID=${MODEL_ID}"
  ENV_LINES="${ENV_LINES}"$'\n'"MODEL_VM_SIZE=${VM_SIZE}"
else
  echo "Model: none (sync only)"
fi
NGROK_MODE=disabled
MONITORING_MODE=disabled
if [ "$ACTION" = up ] && [ -z "${COMPOSE_FILES:-}" ]; then
  NGROK_AUTHTOKEN_VALUE="$(printf '%s\n' "$ENV_LINES" | sed -n 's/^NGROK_AUTHTOKEN=//p' | tail -n 1)"
  NGROK_URL_VALUE="$(printf '%s\n' "$ENV_LINES" | sed -n 's/^NGROK_URL=//p' | tail -n 1)"
  if [ -n "$NGROK_AUTHTOKEN_VALUE" ] && [ -n "$NGROK_URL_VALUE" ]; then
    NGROK_MODE=enabled
  elif [ -n "$NGROK_AUTHTOKEN_VALUE" ] || [ -n "$NGROK_URL_VALUE" ]; then
    echo "ERROR: ngrok is partially configured; set both NGROK_AUTHTOKEN and NGROK_URL in .env, or leave both empty" >&2
    exit 2
  fi
fi

if [ "$ACTION" = up ] && [ -z "${COMPOSE_FILES:-}" ]; then
  telemetry_destinations=0
  for key in AZMON_APPLICATION_ID AZMON_TRACES_ENDPOINT AZMON_LOGS_ENDPOINT AZMON_METRICS_ENDPOINT; do
    value="$(printf '%s\n' "$ENV_LINES" | sed -n "s/^${key}=//p" | tail -n 1)"
    if [ -n "$value" ] && [[ "$value" != *"<"* ]] && [ "$value" != 00000000-0000-0000-0000-000000000000 ]; then
      telemetry_destinations=$((telemetry_destinations + 1))
    fi
  done
  case "$telemetry_destinations" in
    0) MONITORING_MODE=disabled ;;
    4) MONITORING_MODE=enabled ;;
    *)
      echo "ERROR: telemetry is partially configured; provision monitoring or use COMPOSE_FILES=\"-f compose.yaml\"" >&2
      exit 2
      ;;
  esac
fi

if [ "$ACTION" = up ] && { [ "$MONITORING_MODE" = enabled ] || [[ "${COMPOSE_FILES:-}" == *compose.observability.yaml* ]]; }; then
  # The ingestion identity attached to the VM decides the collector's client ID.
  INGEST_ID="$(az vm show --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "keys(identity.userAssignedIdentities || \`{}\`)[?contains(@, '/id-llm-ingest-')] | [0]" \
    -o tsv | tr -d '\r')"
  if [ -z "$INGEST_ID" ]; then
    echo "ERROR: monitoring was selected but no id-llm-ingest-* identity is attached to ${VM_NAME}" >&2
    exit 2
  fi
  UAMI_CLIENT_ID="$(az identity show --ids "$INGEST_ID" --query clientId -o tsv | tr -d '\r')"
  echo "ingestion identity: ${INGEST_ID##*/} (client ID ${UAMI_CLIENT_ID})"
  ENV_LINES="$(printf '%s\n' "$ENV_LINES" | grep -v -e '^TELEMETRY_UAMI_CLIENT_ID=' -e '^$' || true)"
  ENV_LINES="${ENV_LINES:+$ENV_LINES$'\n'}TELEMETRY_UAMI_CLIENT_ID=${UAMI_CLIENT_ID}"
fi

ENV_B64=""
if [ -n "$ENV_LINES" ]; then
  ENV_B64="$(printf '%s' "$ENV_LINES" | base64 -w0)"
  echo "env keys sent: $(printf '%s\n' "$ENV_LINES" | cut -d= -f1 | tr '\n' ' ')"
fi

REMOTE_SCRIPT="$(cat <<EOF
#!/bin/bash
set -euo pipefail
mkdir -p $REMOTE_DIR && cd $REMOTE_DIR
echo '$PAYLOAD' | base64 -d | tar -xzf - --no-same-owner
echo '$ENV_B64' | base64 -d | bash scripts/merge-env.sh
sed -i \
  -e '/^MODEL_REPO=/d' \
  -e '/^MODEL_REVISION=/d' \
  -e '/^MODEL_DIR=/d' \
  -e '/^LLM_MODEL=/d' \
  -e '/^QWEN38_27B_/d' \
  .env
if [ "$DEPLOY_MODEL" = "0" ]; then
  sed -i -e '/^MODEL_ID=/d' -e '/^MODEL_VM_SIZE=/d' .env
  docker rm -f llm-model-download llm-model llm-litellm llm-ngrok \
    llm-otel-collector llm-dcgm-exporter >/dev/null 2>&1 || true
  echo "model services stopped; stack files are synced without a selected model"
fi
mkdir -p /data/models /data/vllm-cache
echo "synced to $REMOTE_DIR"
if [ "$ACTION" = "up" ]; then
  compose_files="\$(echo '$COMPOSE_FILES_B64' | base64 -d)"
  if [ -n "\$compose_files" ]; then
    read -r -a compose_args <<< "\$compose_files"
    echo "compose files: \$compose_files (explicit override)"
  else
    compose_args=(-f compose.yaml)
    if [ "$MONITORING_MODE" = enabled ]; then
      compose_args+=(-f compose.observability.yaml)
      echo "monitoring enabled"
    else
      echo "monitoring disabled: telemetry values are not provisioned"
      docker rm -f llm-otel-collector llm-dcgm-exporter >/dev/null 2>&1 || true
    fi
    if [ "$NGROK_MODE" = enabled ]; then
      compose_args+=(-f compose.ngrok.yaml)
      echo "ngrok enabled"
    else
      echo "ngrok disabled: both NGROK_AUTHTOKEN and NGROK_URL must be set in the workstation .env"
      docker rm -f llm-ngrok >/dev/null 2>&1 || true
    fi
    printf 'compose files:'
    printf ' %s' "\${compose_args[@]}"
    printf '\n'
  fi
  # Detach through systemd: image pulls and the model download can take far
  # longer than run-command allows. Progress: /var/log/llm-compose-up.log
  # On a fresh VM compose once declared the model unhealthy during its first
  # load and gave up, leaving dependent services created but never started,
  # although the model went healthy minutes later. A second up waits for it
  # and starts them, so retry up to twice.
  systemctl reset-failed llm-compose-up 2>/dev/null || true
  docker rm -f qwen3.8-27b >/dev/null 2>&1 || true
  systemd-run --unit=llm-compose-up --collect --working-directory=$REMOTE_DIR \
    bash -c "up() { docker compose \"\\\$@\" up -d --remove-orphans >> /var/log/llm-compose-up.log 2>&1; }; \
      up \"\\\$@\" || { echo '== compose up failed; retrying in 60 s' >> /var/log/llm-compose-up.log; sleep 60; up \"\\\$@\"; } \
                    || { echo '== compose up failed; retrying in 60 s' >> /var/log/llm-compose-up.log; sleep 60; up \"\\\$@\"; }" \
    _ "\${compose_args[@]}"
  echo "started llm-compose-up; follow with: scripts/vm-run.sh -c 'tail -n 30 /var/log/llm-compose-up.log'"
fi
# This script may carry secrets; do not leave it in the waagent download dir.
# (\$0 is escaped so it expands on the VM, not in this heredoc.)
truncate -s 0 "\$0" 2>/dev/null || true
EOF
)"

# Pass the script as a file: on Windows `az` is a .cmd wrapper limited to an
# ~8 KB command line.
TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT
printf '%s\n' "$REMOTE_SCRIPT" > "$TMP_SCRIPT"
scripts/vm-run.sh "$TMP_SCRIPT"
