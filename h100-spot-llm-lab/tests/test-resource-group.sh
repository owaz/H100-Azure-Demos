#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "${tmp_dir}/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AZ_CALLS"
if [ "$1 $2" = "vm list" ]; then
  printf '%s\n' \
    $'2026-10-11T10:00:00Z\tvm-older\trg-lab\tsoutheastasia' \
    $'2026-10-12T10:00:00Z\tvm-newer\trg-lab\tuksouth'
elif [ "$1 $2" = "group exists" ]; then
  printf '%s\n' false
elif [ "$1 $2" = "identity show" ]; then
  exit 1
elif [ "$1 $2" = "vm show" ]; then
  args=("$@")
  requested_vm_name=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "-n" ]; then
      requested_vm_name="${args[$((i + 1))]}"
      break
    fi
  done
  if [ -n "${EXISTING_VM_NAME:-}" ] && [ "$requested_vm_name" = "$EXISTING_VM_NAME" ]; then
    exit 0
  fi
  if [ -n "${EXISTING_VM_COUNT:-}" ] &&
      [[ "$requested_vm_name" =~ ^vm-h100-uks-([0-9]+)$ ]] &&
      [ "$((10#${BASH_REMATCH[1]}))" -le "$EXISTING_VM_COUNT" ]; then
    exit 0
  fi
  exit 1
fi
EOF
chmod +x "${tmp_dir}/az"

export PATH="${tmp_dir}:${PATH}"
export AZ_CALLS="${tmp_dir}/az-calls"
export SUBSCRIPTION="sub-test"
export RESOURCE_GROUP="rg-lab"

# shellcheck source=../scripts/lib/find-vm.sh
. scripts/lib/find-vm.sh
find_stack_vm
[ "$FOUND_VM" = "vm-newer" ]
[ "$FOUND_RESOURCE_GROUP" = "rg-lab" ]
[ "$FOUND_LOCATION" = "uksouth" ]
grep -Fq "vm list --subscription sub-test -g rg-lab" "$AZ_CALLS"

missing_output="${tmp_dir}/missing-output"
if env -u RESOURCE_GROUP RG=legacy SUBSCRIPTION=sub-test \
    LOCATION=southeastasia VM_SIZE=Standard_NC40ads_H100_v5 \
    infra/provision-spot-vm.sh </dev/null >"$missing_output" 2>&1; then
  echo "VM provisioner unexpectedly accepted a missing RESOURCE_GROUP" >&2
  exit 1
fi
grep -Fq "RESOURCE_GROUP is required in non-interactive mode" "$missing_output"

if env -u RESOURCE_GROUP MONITORING_RG=legacy SUBSCRIPTION=sub-test \
    LOCATION=southeastasia infra/provision-monitoring.sh \
    </dev/null >"$missing_output" 2>&1; then
  echo "monitoring provisioner unexpectedly accepted a missing RESOURCE_GROUP" >&2
  exit 1
fi
grep -Fq "RESOURCE_GROUP is required in non-interactive mode" "$missing_output"

>"$AZ_CALLS"
RESOURCE_GROUP=rg-partial LOCATION=southeastasia ZONE=2 \
  VM_SIZE=Standard_NC40ads_H100_v5 FORCE_NEW=1 DATE_SUFFIX=261012 \
  infra/provision-spot-vm.sh >/dev/null
grep -Fq "network nsg create -g rg-partial -n nsg-llm-h100-sea-z2-261012" "$AZ_CALLS"
grep -Fq "network public-ip create -g rg-partial -n pip-nat-llm-h100-sea-z2-261012" "$AZ_CALLS"
grep -Fq "network vnet create -g rg-partial -n vnet-llm-h100-sea-z2-261012" "$AZ_CALLS"
grep -Fq "vm create -g rg-partial -n vm-h100-sea-01" "$AZ_CALLS"

>"$AZ_CALLS"
EXISTING_VM_NAME=vm-h100-uks-01 RESOURCE_GROUP=rg-collision LOCATION=uksouth \
  ZONE=none VM_SIZE=Standard_NC40ads_H100_v5 FORCE_NEW=1 DATE_SUFFIX=261012 \
  infra/provision-spot-vm.sh >/dev/null
grep -Fq "vm show -g rg-collision -n vm-h100-uks-01 -o none" "$AZ_CALLS"
grep -Fq "vm create -g rg-collision -n vm-h100-uks-02" "$AZ_CALLS"

>"$AZ_CALLS"
EXISTING_VM_COUNT=99 RESOURCE_GROUP=rg-over-99 LOCATION=uksouth ZONE=none \
  VM_SIZE=Standard_NC40ads_H100_v5 FORCE_NEW=1 DATE_SUFFIX=261012 \
  infra/provision-spot-vm.sh >/dev/null
grep -Fq "vm create -g rg-over-99 -n vm-h100-uks-100" "$AZ_CALLS"

>"$AZ_CALLS"
RESOURCE_GROUP=rg-override LOCATION=southeastasia ZONE=none \
  VM_SIZE=Standard_NC40ads_H100_v5 FORCE_NEW=1 VM_NAME=vm-explicit \
  DATE_SUFFIX=261012 infra/provision-spot-vm.sh >/dev/null
grep -Fq "vm create -g rg-override -n vm-explicit" "$AZ_CALLS"
if grep -Fq "vm-h100-sea-" "$AZ_CALLS"; then
  echo "VM provisioner replaced an explicit VM_NAME" >&2
  exit 1
fi

if grep -ERn '(^|[^A-Z_])(RG|MONITORING_RG|IDENTITY_RG|ID_RG)($|[^A-Z_])' \
    scripts infra; then
  echo "legacy resource-group input remains in executable scripts" >&2
  exit 1
fi

grep -Fq 'vm list -g "$RESOURCE_GROUP"' infra/provision-monitoring.sh
grep -Fq 'RESOURCE_GROUP="$RESOURCE_GROUP"' infra/provision-monitoring.sh
grep -Fq 'find_rc=0' scripts/launch.sh
grep -Fq 'LAW_NAME="${LAW_NAME:-law-llm-telemetry-${LOCATION_KEY}}"' infra/provision-monitoring.sh

size_prompt_line="$(grep -n 'Choose the target VM size' scripts/launch.sh | cut -d: -f1)"
region_prompt_line="$(grep -n 'Azure region (for example southeastasia)' scripts/launch.sh | cut -d: -f1)"
resource_group_prompt_line="$(grep -n 'Azure resource group:' scripts/launch.sh | cut -d: -f1)"
[ "$size_prompt_line" -lt "$region_prompt_line" ]
[ "$region_prompt_line" -lt "$resource_group_prompt_line" ]
grep -Fq "Delete Azure resource group '" scripts/launch.sh
grep -Fq 'az group delete --subscription "$SUBSCRIPTION" -n "$RESOURCE_GROUP" --yes --no-wait' scripts/launch.sh
grep -Fq 'prompt_yes_no "Deploy a model now?" yes' scripts/launch.sh
grep -Fq 'DEPLOY_MODEL=0 scripts/deploy.sh sync' scripts/launch.sh
grep -Fq 'handle_deployment_failure 1' scripts/launch.sh

power_check_line="$(grep -n 'power_code="$(az vm get-instance-view' scripts/launch.sh | cut -d: -f1)"
cleanup_activation_line="$(grep -n 'deployment_in_progress=1' scripts/launch.sh | head -n 1 | cut -d: -f1)"
[ "$power_check_line" -lt "$cleanup_activation_line" ]

echo "resource group tests: PASS"
