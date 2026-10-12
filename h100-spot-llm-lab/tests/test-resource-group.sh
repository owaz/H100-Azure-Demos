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
elif [ "$1 $2" = "identity show" ] || [ "$1 $2" = "vm show" ]; then
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

echo "resource group tests: PASS"
