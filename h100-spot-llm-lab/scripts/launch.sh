#!/usr/bin/env bash
# Interactive end-to-end launcher: choose hardware and a compatible catalog
# model, provision or reuse a VM, bootstrap it, and deploy the stack.
set -euo pipefail
cd "$(dirname "$0")/.."

for command_name in az jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: ${command_name} is required" >&2
    exit 1
  }
done
[ -t 0 ] || {
  echo "ERROR: scripts/launch.sh is interactive; use the existing infra and deploy scripts for automation" >&2
  exit 2
}
python3 scripts/model_profile.py validate >/dev/null

prompt_choice() {
  local prompt="$1"
  local maximum="$2"
  local default="${3:-}"
  local answer
  while true; do
    if [ -n "$default" ]; then
      read -r -p "${prompt} [${default}]: " answer
      answer="${answer:-$default}"
    else
      read -r -p "${prompt}: " answer
    fi
    case "$answer" in
      ''|*[!0-9]*) ;;
      *) [ "$answer" -ge 1 ] && [ "$answer" -le "$maximum" ] && {
        printf '%s\n' "$answer"
        return
      } ;;
    esac
    echo "Enter a number from 1 to ${maximum}." >&2
  done
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
  local answer suffix
  if [ "$default" = yes ]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  while true; do
    read -r -p "${prompt} ${suffix} " answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Enter yes or no." >&2 ;;
    esac
  done
}

deployment_in_progress=0
handle_deployment_failure() {
  local status=$?
  trap - ERR
  set +e
  if [ "$deployment_in_progress" = 1 ]; then
    echo >&2
    echo "ERROR: deployment failed (exit status ${status})." >&2
    echo "Deleting the resource group removes every resource it contains." >&2
    if prompt_yes_no "Delete Azure resource group '${RESOURCE_GROUP}'?" no; then
      echo "==> Requesting deletion of ${RESOURCE_GROUP}"
      if az group delete --subscription "$SUBSCRIPTION" -n "$RESOURCE_GROUP" --yes --no-wait; then
        echo "Resource group deletion requested."
      else
        echo "ERROR: failed to request deletion of resource group ${RESOURCE_GROUP}" >&2
      fi
    fi
  fi
  exit "$status"
}
trap handle_deployment_failure ERR

echo "H100 model lab launcher"
echo "  1) Standard_NC40ads_H100_v5  (1 x H100 NVL, 94 GB)"
echo "  2) Standard_NC80adis_H100_v5 (2 x H100 NVL, 188 GB total)"
sku_choice="$(prompt_choice "Choose the target VM size" 2 1)"
case "$sku_choice" in
  1) REQUESTED_VM_SIZE=Standard_NC40ads_H100_v5 ;;
  2) REQUESTED_VM_SIZE=Standard_NC80adis_H100_v5 ;;
esac
EFFECTIVE_VM_SIZE="$REQUESTED_VM_SIZE"

read -r -p "Azure region (for example southeastasia): " LOCATION
[ -n "$LOCATION" ] || { echo "ERROR: region is required" >&2; exit 2; }
SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id -o tsv | tr -d '[:space:]')}"
read -r -p "Azure resource group: " RESOURCE_GROUP
[ -n "$RESOURCE_GROUP" ] || { echo "ERROR: resource group is required" >&2; exit 2; }
export SUBSCRIPTION RESOURCE_GROUP
# shellcheck source=lib/find-vm.sh
. scripts/lib/find-vm.sh
reuse_existing=0
find_rc=1
if [ "$(az group exists --subscription "$SUBSCRIPTION" -n "$RESOURCE_GROUP" -o tsv)" = true ]; then
  find_rc=0
  find_stack_vm || find_rc=$?
fi
case "$find_rc" in
  0)
    existing_size="$(az vm show --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$FOUND_VM" \
      --query hardwareProfile.vmSize -o tsv | tr -d '\r')"
    existing_power="$(az vm get-instance-view --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$FOUND_VM" \
      --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv | tr -d '\r')"
    echo
    echo "Existing lab VM: ${FOUND_VM} (${existing_size}, ${FOUND_LOCATION}, ${existing_power})"
    if [ "$existing_size" = "$REQUESTED_VM_SIZE" ]; then
      if prompt_yes_no "Reuse this VM?" yes; then
        reuse_existing=1
      fi
    else
      echo "Its size differs from the requested ${REQUESTED_VM_SIZE}."
      echo "  1) Reuse it and choose from models compatible with ${existing_size}"
      echo "  2) Create a new ${REQUESTED_VM_SIZE} VM"
      reuse_choice="$(prompt_choice "Choose reuse behavior" 2 2)"
      if [ "$reuse_choice" = 1 ]; then
        reuse_existing=1
        EFFECTIVE_VM_SIZE="$existing_size"
      fi
    fi
    ;;
  1) ;;
  *) echo "ERROR: cannot safely discover existing lab VMs" >&2; exit 1 ;;
esac

deploy_model=0
enable_monitoring=0
enable_ngrok=0
if prompt_yes_no "Deploy a model now?" yes; then
  deploy_model=1

  echo
  echo "Models compatible with ${EFFECTIVE_VM_SIZE}:"
  model_ids=()
  model_statuses=()
  model_sizes=()
  index=0
  while IFS=$'\t' read -r model_id display_name status download_size description; do
    index=$((index + 1))
    model_ids+=("$model_id")
    model_statuses+=("$status")
    model_sizes+=("$download_size")
    printf '  %d) %s [%s, ~%s GB]\n     %s\n' \
      "$index" "$display_name" "$status" "$download_size" "$description"
  done < <(python3 scripts/model_profile.py list "$EFFECTIVE_VM_SIZE" --tsv)
  [ "$index" -gt 0 ] || {
    echo "ERROR: no catalog models support ${EFFECTIVE_VM_SIZE}" >&2
    exit 2
  }
  model_choice="$(prompt_choice "Choose a model" "$index" 1)"
  MODEL_ID="${model_ids[$((model_choice - 1))]}"
  MODEL_STATUS="${model_statuses[$((model_choice - 1))]}"
  MODEL_SIZE_GB="${model_sizes[$((model_choice - 1))]}"
  MODEL_JSON="$(python3 scripts/model_profile.py resolve "$MODEL_ID" "$EFFECTIVE_VM_SIZE")"
  MODEL_REPO="$(printf '%s' "$MODEL_JSON" | jq -r '.model.repo')"
  MODEL_REVISION="$(printf '%s' "$MODEL_JSON" | jq -r '.model.revision')"

  echo
  echo "Selection:"
  echo "  VM:         ${EFFECTIVE_VM_SIZE}"
  echo "  Model:      ${MODEL_ID}"
  echo "  Checkpoint: ${MODEL_REPO}@${MODEL_REVISION}"
  echo "  Download:   approximately ${MODEL_SIZE_GB} GB"
  echo "  Profile:    ${MODEL_STATUS}"
  if [ "$MODEL_STATUS" = candidate ]; then
    echo "  Warning: this exact model/VM profile has not yet passed the lab's hardware smoke test."
    prompt_yes_no "Continue with this candidate profile?" no || exit 0
  fi
  printf 'MODEL_ID=%s\n' "$MODEL_ID" | bash scripts/merge-env.sh

  prompt_yes_no "Provision Azure Monitor observability resources?" no && enable_monitoring=1
  if prompt_yes_no "Enable the ngrok public tunnel?" no; then
    enable_ngrok=1
    ngrok_token="$(sed -n 's/^NGROK_AUTHTOKEN=//p' .env 2>/dev/null | tail -n 1)"
    ngrok_url="$(sed -n 's/^NGROK_URL=//p' .env 2>/dev/null | tail -n 1)"
    if [ -z "$ngrok_token" ] || [ -z "$ngrok_url" ]; then
      echo "ERROR: set both NGROK_AUTHTOKEN and NGROK_URL in .env before enabling ngrok" >&2
      exit 2
    fi
  fi
else
  echo
  echo "No model will be selected or started."
  echo "The VM will be bootstrapped and the vLLM/LiteLLM stack will be synced only."
fi

if [ "$reuse_existing" = 1 ]; then
  deployment_in_progress=1
  VM_NAME="$FOUND_VM"
  LOCATION="$FOUND_LOCATION"
  export VM_NAME LOCATION
  actual_size="$(az vm show --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query hardwareProfile.vmSize -o tsv | tr -d '\r')"
  [ "$actual_size" = "$EFFECTIVE_VM_SIZE" ] || {
    echo "ERROR: ${VM_NAME} changed size during selection (${actual_size})" >&2
    exit 2
  }
  power_code="$(az vm get-instance-view --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv | tr -d '\r')"
  if [ "$power_code" != PowerState/running ]; then
    echo "==> Starting ${VM_NAME}"
    az vm start --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none
  fi
else
  read -r -p "Availability zone [none]: " ZONE
  ZONE="${ZONE:-none}"
  case "$ZONE" in 1|2|3|none) ;; *) echo "ERROR: zone must be 1, 2, 3, or none" >&2; exit 2 ;; esac
  export LOCATION ZONE
  echo
  echo "A new Spot VM and its network resources will be created in ${LOCATION}."
  prompt_yes_no "Create the billable Azure resources now?" no || exit 0
  deployment_in_progress=1
  VM_SIZE="$REQUESTED_VM_SIZE" FORCE_NEW=1 DATE_SUFFIX="$(date +%y%m%d-%H%M%S)" \
    infra/provision-spot-vm.sh
  find_rc=0
  find_stack_vm || find_rc=$?
  [ "$find_rc" = 0 ] || { echo "ERROR: the newly provisioned VM cannot be discovered" >&2; exit 1; }
  VM_NAME="$FOUND_VM"
  LOCATION="$FOUND_LOCATION"
  export VM_NAME LOCATION
fi

if [ "$enable_monitoring" = 1 ]; then
  LOCATION="$LOCATION" infra/provision-monitoring.sh
fi

echo "==> Bootstrapping ${VM_NAME}"
scripts/vm-run.sh scripts/bootstrap-host.sh
echo "==> Persistent model disk"
scripts/vm-run.sh -c 'df -h /data'

if [ "$deploy_model" = 0 ]; then
  DEPLOY_MODEL=0 scripts/deploy.sh sync
  deployment_in_progress=0
  echo
  echo "Core deployment complete on ${VM_NAME} (${EFFECTIVE_VM_SIZE})."
  echo "The host is ready and the application stack is synced, but no model services are running."
  exit 0
fi

compose_files="-f compose.yaml"
[ "$enable_monitoring" = 1 ] && compose_files="${compose_files} -f compose.observability.yaml"
[ "$enable_ngrok" = 1 ] && compose_files="${compose_files} -f compose.ngrok.yaml"
export MODEL_ID
COMPOSE_FILES="$compose_files" scripts/deploy.sh up

echo "==> Waiting for the model and gateway to become healthy"
scripts/vm-run.sh -c '
  set -e
  deadline=$((SECONDS + 2400))
  while [ "$SECONDS" -lt "$deadline" ]; do
    model_status="$(docker inspect --format "{{.State.Health.Status}}" llm-model 2>/dev/null || true)"
    gateway_status="$(docker inspect --format "{{.State.Health.Status}}" llm-litellm 2>/dev/null || true)"
    echo "model=${model_status:-not-created} gateway=${gateway_status:-not-created}"
    [ "$model_status" = healthy ] && [ "$gateway_status" = healthy ] && exit 0
    sleep 30
  done
  echo "ERROR: stack did not become healthy within 40 minutes" >&2
  exit 1
'
scripts/vm-run.sh scripts/vm-status.sh
scripts/vm-run.sh scripts/smoke-test.sh
deployment_in_progress=0

echo
echo "Deployment complete: ${MODEL_ID} on ${VM_NAME} (${EFFECTIVE_VM_SIZE})."
if [ "$enable_ngrok" = 1 ]; then
  echo "Public endpoint: $(sed -n 's/^NGROK_URL=//p' .env | tail -n 1)"
else
  echo "The gateway is private on the VM. Use scripts/vm-run.sh for administration."
fi
