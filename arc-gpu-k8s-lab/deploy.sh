#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
LOCATION="${LOCATION:-}"
VM_NAME="${VM_NAME:-vm-arc-gpu-h100}"
VM_SIZE="${VM_SIZE:-Standard_NC40ads_H100_v5}"
ZONE="${ZONE:-none}"
PROJECT=arc-gpu-k8s-lab
K3S_VERSION=v1.35.9+k3s1
GPU_OPERATOR_VERSION=v26.7.2
HELM_VERSION=v3.20.0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: RESOURCE_GROUP=<dedicated-group> [LOCATION=<region>] bash $0 {up|verify|status|stop}"
  echo "up creates billable Azure resources; LOCATION is required for up."
}
case "$ACTION" in up|verify|status|stop) ;; *) usage; exit 2 ;; esac
[[ "$RESOURCE_GROUP" =~ ^[a-zA-Z0-9_-]{1,80}$ ]] || die "Set RESOURCE_GROUP to a dedicated lab group (letters, digits, _ or -)."
[[ "$VM_NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,50}$ ]] || die "Invalid VM_NAME."
case "$VM_SIZE" in
  Standard_NC40ads_H100_v5) EXPECTED_GPUS=1 ;;
  Standard_NC80adis_H100_v5) EXPECTED_GPUS=2 ;;
  *) die "VM_SIZE must be Standard_NC40ads_H100_v5 or Standard_NC80adis_H100_v5." ;;
esac
case "$ZONE" in none|1|2|3) ;; *) die "ZONE must be none, 1, 2 or 3." ;; esac
if [ "$ACTION" = up ]; then
  [[ "$LOCATION" =~ ^[a-z0-9]+$ ]] || die "Set LOCATION to an Azure region."
fi
for cmd in az jq tar base64; do
  command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done
SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id --output tsv)}"
[ -n "$SUBSCRIPTION" ] || die "Azure CLI did not return a subscription ID."
az() { command az "$@" --subscription "$SUBSCRIPTION"; }
az account show --output none

assert_group() {
  local group
  group="$(az group show --name "$RESOURCE_GROUP" --output json)"
  [ "$(jq -r '.tags.project // ""' <<< "$group")" = "$PROJECT" ] ||
    die "Refusing to use resource group $RESOURCE_GROUP: it is not tagged project=$PROJECT."
}
assert_vm() {
  local vm
  vm="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --output json)"
  [ "$(jq -r '.tags.project // ""' <<< "$vm")" = "$PROJECT" ] ||
    die "Refusing to use VM $VM_NAME: it is not tagged project=$PROJECT."
  [ "$(jq -r '.hardwareProfile.vmSize' <<< "$vm")" = "$VM_SIZE" ] ||
    die "Existing VM size differs from VM_SIZE; set VM_SIZE to its actual size."
  [ "$(jq -r '.priority' <<< "$vm")" = Spot ] ||
    die "Existing VM is not a Spot VM."
}

if [ "$ACTION" = up ]; then
  group_exists="$(az group exists --name "$RESOURCE_GROUP" --output tsv)"
  case "$group_exists" in
    true) assert_group ;;
    false)
      az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
        --tags project="$PROJECT" --output none ;;
    *) die "Unexpected response when checking resource group existence." ;;
  esac
  vms="$(az vm list --resource-group "$RESOURCE_GROUP" --output json)"
  if jq -e --arg name "$VM_NAME" 'any(.[]; .name == $name)' <<< "$vms" >/dev/null; then
    assert_vm
    existing_location="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query location --output tsv)"
    [ "$existing_location" = "$LOCATION" ] || die "Existing VM is in $existing_location, not $LOCATION."
    echo "Reusing this lab's VM $VM_NAME; starting it if needed."
    az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --output none
  else
    [ "$(jq 'length' <<< "$vms")" = 0 ] ||
      die "Dedicated lab group already contains another VM; refusing to add one."
    command -v ssh-keygen >/dev/null || die "Required command not found: ssh-keygen"
    echo "Creating a NEW private $VM_SIZE Spot VM in $LOCATION. Capacity and price are not guaranteed."
    nsg="${VM_NAME}-nsg"
    vnet="${VM_NAME}-vnet"
    nat="${VM_NAME}-nat"
    pip="${VM_NAME}-egress"
    az network nsg create -g "$RESOURCE_GROUP" -n "$nsg" -l "$LOCATION" --tags project="$PROJECT" -o none
    az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$nsg" -n deny-internet-inbound \
      --priority 100 --direction Inbound --access Deny --protocol '*' \
      --source-address-prefixes Internet --destination-address-prefixes '*' \
      --source-port-ranges '*' --destination-port-ranges '*' -o none
    az network public-ip create -g "$RESOURCE_GROUP" -n "$pip" -l "$LOCATION" \
      --sku Standard --allocation-method Static --tags project="$PROJECT" -o none
    az network nat gateway create -g "$RESOURCE_GROUP" -n "$nat" -l "$LOCATION" \
      --public-ip-addresses "$pip" --tags project="$PROJECT" -o none
    az network vnet create -g "$RESOURCE_GROUP" -n "$vnet" -l "$LOCATION" \
      --address-prefixes 10.70.0.0/16 --tags project="$PROJECT" -o none
    az network vnet subnet create -g "$RESOURCE_GROUP" --vnet-name "$vnet" -n gpu \
      --address-prefixes 10.70.1.0/24 --network-security-group "$nsg" \
      --nat-gateway "$nat" --default-outbound-access false -o none
    key_dir="$(mktemp -d)"
    cleanup_key() { rm -f "$key_dir/id_ed25519" "$key_dir/id_ed25519.pub"; rmdir "$key_dir"; }
    trap cleanup_key EXIT
    ssh-keygen -q -t ed25519 -N '' -f "$key_dir/id_ed25519"
    az_with_zone() {
      if [ "$ZONE" = none ]; then az "$@"; else az "$@" --zone "$ZONE"; fi
    }
    az_with_zone vm create -g "$RESOURCE_GROUP" -n "$VM_NAME" -l "$LOCATION" \
      --size "$VM_SIZE" --image Canonical:ubuntu-24_04-lts:server:latest \
      --security-type TrustedLaunch --enable-secure-boot false --enable-vtpm true \
      --priority Spot --eviction-policy Deallocate --max-price -1 \
      --vnet-name "$vnet" --subnet gpu --nsg "" --public-ip-address "" \
      --admin-username azureuser --authentication-type ssh \
      --ssh-key-values "$key_dir/id_ed25519.pub" \
      --os-disk-size-gb 256 --storage-sku Premium_LRS \
      --tags project="$PROJECT" role=gpu-kubernetes -o none
    cleanup_key
    trap - EXIT
    assert_vm
  fi
else
  assert_group
  assert_vm
fi

case "$ACTION" in
  status)
    az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
      --query '{name:name,statuses:instanceView.statuses}' -o json
    exit ;;
  stop)
    az vm deallocate -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none
    echo "VM deallocated. Managed disk, NAT gateway, and public IP charges continue."
    exit ;;
esac

work="$(mktemp -d)"
cleanup() { rm -f "$work/request.sh" "$work/result.json"; rmdir "$work"; }
trap cleanup EXIT
payload="$(COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$LAB_DIR" scripts manifests | base64 | tr -d '\r\n')"
{
  printf '#!/bin/sh\nbash <<'\''ARC_GPU_GUEST'\''\nset -euo pipefail\n'
  printf 'trap '\''rc=$?; printf "\\nARC_GPU_EXIT=%%s\\n" "$rc"; exit "$rc"'\'' EXIT\n'
  printf 'install -d -m 700 /opt/arc-gpu-k8s-lab\n'
  printf "printf '%%s' '%s' | base64 -d | tar -xzf - --no-same-owner -C /opt/arc-gpu-k8s-lab\n" "$payload"
  printf 'export K3S_VERSION=%q GPU_OPERATOR_VERSION=%q HELM_VERSION=%q EXPECTED_GPUS=%q\n' \
    "$K3S_VERSION" "$GPU_OPERATOR_VERSION" "$HELM_VERSION" "$EXPECTED_GPUS"
  if [ "$ACTION" = up ]; then
    printf 'bash /opt/arc-gpu-k8s-lab/scripts/bootstrap.sh\n'
  else
    printf 'bash /opt/arc-gpu-k8s-lab/scripts/verify.sh\n'
  fi
  printf 'ARC_GPU_GUEST\n'
} > "$work/request.sh"
echo "Running $ACTION via Azure Run Command; bootstrap may take 20–40 minutes."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "$(< "$work/request.sh")" --output json > "$work/result.json"
jq -r '.value[].message' "$work/result.json"
rc="$(jq -r '.value[].message' "$work/result.json" | tr -d '\r' |
  sed -n 's/^ARC_GPU_EXIT=\([0-9][0-9]*\)$/\1/p' | tail -n 1)"
[ -n "$rc" ] || die "Guest exit marker missing. Run Command success alone does not prove guest success."
[ "$rc" = 0 ] || die "Guest $ACTION failed (exit $rc). Inspect the output and /var/log/arc-gpu-k8s-lab.log."
echo "GPU lab $ACTION completed successfully."
