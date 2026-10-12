#!/usr/bin/env bash
# Provision a private Spot H100 VM for the self-hosted LLM stack.
#
# - No public IP on the VM. The NSG denies all inbound traffic from the
#   internet.
# - Outbound internet access (Docker, Hugging Face, ngrok, telemetry) goes
#   through a NAT gateway. New VNets no longer get implicit default outbound
#   access.
# - Spot priority with eviction policy Deallocate. Spot draws on the regional
#   low-priority vCPU quota, not the NCadsH100v5 family quota, which is often 0
#   in a new subscription. NC40 needs 40 low-priority vCPUs; NC80 needs 80.
# - Administration runs through `az vm run-command` (scripts/vm-run.sh), so no
#   SSH ingress is required.
#
# Reuse first: the script looks for an existing stack VM (tags
# project=llm-self-hosting role=llm-h100) in the subscription. If one exists,
# it reuses it (starting it if deallocated) and creates nothing. Only if none
# exists does it create a new VM in RESOURCE_GROUP, named with the region,
# placement and today's date, e.g. vm-llm-h100-uks-z2-261005 for uksouth zone 2
# on 2026-10-05. The VM name uses a short region code (region_short below).
# Pick the region and optional zone with infra/spot-regions.sh.
#
#   RESOURCE_GROUP=rg-llm-lab LOCATION=southeastasia ZONE=2 infra/provision-spot-vm.sh
#   RESOURCE_GROUP=rg-llm-lab LOCATION=southeastasia ZONE=none infra/provision-spot-vm.sh
#   RESOURCE_GROUP=rg-llm-lab VM_SIZE=Standard_NC80adis_H100_v5 LOCATION=... infra/provision-spot-vm.sh
#   RESOURCE_GROUP=rg-llm-lab FORCE_NEW=1 LOCATION=... ZONE=... infra/provision-spot-vm.sh
#   RESOURCE_GROUP=rg-llm-lab VM_NAME=... infra/provision-spot-vm.sh
#
# If the regional ingestion identity id-llm-ingest-<region> already exists in
# RESOURCE_GROUP, it is attached to the VM automatically.
#
# Safe to re-run: the network steps are idempotent, and the VM step is
# skipped if the VM already exists.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # keep Git Bash on Windows from rewriting /subscriptions/... args

SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id -o tsv | tr -d '[:space:]')}"   # default: the az CLI's current subscription
LOCATION="${LOCATION:-}"
ZONE="${ZONE:-none}"
PREFIX="${PREFIX:-llm-h100}"
DATE_SUFFIX="${DATE_SUFFIX:-$(date +%y%m%d)}"   # yymmdd, e.g. 261009
FORCE_NEW="${FORCE_NEW:-0}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
VM_SIZE="${VM_SIZE:-}"
IMAGE="${IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
OS_DISK_GB="${OS_DISK_GB:-128}"
DATA_DISK_GB="${DATA_DISK_GB:-512}"
VNET_CIDR="${VNET_CIDR:-10.60.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.60.1.0/24}"

# shellcheck source=../scripts/lib/find-vm.sh
. "$(dirname "$0")/../scripts/lib/find-vm.sh"
# shellcheck source=../scripts/lib/vm-size.sh
. "$(dirname "$0")/../scripts/lib/vm-size.sh"
TAGS=(project="$STACK_TAG_PROJECT" role="$STACK_TAG_ROLE" created="$(date +%F)")

az() { command az "$@" --subscription "$SUBSCRIPTION"; }

resolve_resource_group() {
  if [ -n "$RESOURCE_GROUP" ]; then
    return
  fi
  if [ ! -t 0 ]; then
    echo "RESOURCE_GROUP is required in non-interactive mode" >&2
    exit 2
  fi
  read -r -p "Azure resource group: " RESOURCE_GROUP
  [ -n "$RESOURCE_GROUP" ] || {
    echo "resource group is required" >&2
    exit 2
  }
}

validate_vm_size() {
  if ! vm_size_is_supported "$VM_SIZE"; then
    echo "invalid VM_SIZE '${VM_SIZE}': expected Standard_NC40ads_H100_v5 or Standard_NC80adis_H100_v5" >&2
    exit 2
  fi
}

select_vm_size() {
  if [ -n "$VM_SIZE" ]; then
    validate_vm_size
    return
  fi
  if [ ! -t 0 ]; then
    echo "VM_SIZE is required in non-interactive mode: set it to Standard_NC40ads_H100_v5 or Standard_NC80adis_H100_v5" >&2
    exit 2
  fi
  echo "Choose the H100 Spot VM size:" >&2
  echo "  1) Standard_NC40ads_H100_v5  (1 x H100 NVL, 40 low-priority vCPUs)" >&2
  echo "  2) Standard_NC80adis_H100_v5 (2 x H100 NVL, 80 low-priority vCPUs)" >&2
  read -r -p "Selection [1-2]: " choice
  case "$choice" in
    1) VM_SIZE=Standard_NC40ads_H100_v5 ;;
    2) VM_SIZE=Standard_NC80adis_H100_v5 ;;
    *) echo "invalid selection '${choice}': expected 1 or 2" >&2; exit 2 ;;
  esac
}

# Reject an explicit unsupported override before making any Azure changes.
if [ -n "$VM_SIZE" ]; then
  validate_vm_size
fi
resolve_resource_group

REUSE=0
if [ -z "${VM_NAME:-}" ] && [ "$FORCE_NEW" != 1 ] &&
    [ "$(az group exists -n "$RESOURCE_GROUP" -o tsv)" = true ]; then
  rc=0
  find_stack_vm || rc=$?
  case "$rc" in
    0) REUSE=1; VM_NAME="$FOUND_VM"; LOCATION="$FOUND_LOCATION" ;;
    1) ;;  # none exists: create today's below
    *) echo "==> Aborting: can't tell whether a stack VM exists" >&2; exit 1 ;;
  esac
fi
if [ "$REUSE" != 1 ] && [ -z "$LOCATION" ]; then
  echo "usage: LOCATION=<region> [ZONE=<1|2|3|none>] $0   (pick a zone with infra/spot-regions.sh, or use none for regional placement)" >&2
  exit 2
fi
case "$ZONE" in
  1|2|3)
    PLACEMENT="z${ZONE}"
    ;;
  none)
    PLACEMENT="regional"
    ;;
  *)
    echo "invalid ZONE '${ZONE}': expected 1, 2, 3, or none" >&2
    exit 2
    ;;
esac
az_with_placement() {
  if [ "$ZONE" = none ]; then
    az "$@"
  else
    az "$@" --zone "$ZONE"
  fi
}
# Short region code for the VM name (Azure CAF abbreviations); a region not
# listed here keeps its full name.
region_short() {
  case "$1" in
    uksouth) echo uks ;;            southcentralus) echo scus ;;
    westus3) echo wus3 ;;           westus2) echo wus2 ;;
    westus) echo wus ;;             eastus) echo eus ;;
    eastus2) echo eus2 ;;           centralus) echo cus ;;
    canadacentral) echo cnc ;;      northeurope) echo ne ;;
    westeurope) echo we ;;          swedencentral) echo sdc ;;
    germanywestcentral) echo gwc ;; spaincentral) echo spc ;;
    switzerlandnorth) echo szn ;;   uaenorth) echo uaen ;;
    southeastasia) echo sea ;;      japaneast) echo jpe ;;
    koreacentral) echo krc ;;       australiaeast) echo ae ;;
    centralindia) echo inc ;;       malaysiawest) echo myw ;;
    indonesiacentral) echo idc ;;
    *) echo "$1" ;;
  esac
}
VM_NAME="${VM_NAME:-vm-${PREFIX}-$(region_short "$LOCATION")-${PLACEMENT}-${DATE_SUFFIX}}"
INFRA_SUFFIX="${PREFIX}-$(region_short "$LOCATION")-${PLACEMENT}-${DATE_SUFFIX}"
VNET="${VNET:-vnet-${INFRA_SUFFIX}}"
SUBNET="${SUBNET:-snet-${INFRA_SUFFIX}}"
NSG="${NSG:-nsg-${INFRA_SUFFIX}}"
NAT="${NAT:-nat-${INFRA_SUFFIX}}"
NAT_PIP="${NAT_PIP:-pip-nat-${INFRA_SUFFIX}}"

if [ "$REUSE" != 1 ] && ! az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none 2>/dev/null; then
  select_vm_size
fi

# The regional identity has isolationScope=Regional, so its name follows
# LOCATION and it must live with the rest of the lab in RESOURCE_GROUP.
INGEST_IDENTITY_ID="${INGEST_IDENTITY_ID:-}"
if [ -z "$INGEST_IDENTITY_ID" ]; then
  candidate_identity="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-llm-ingest-${LOCATION}"
  if command az identity show --ids "$candidate_identity" --subscription "$SUBSCRIPTION" -o none 2>/dev/null; then
    INGEST_IDENTITY_ID="$candidate_identity"
  fi
fi

if [ "$REUSE" = 1 ]; then
  echo "==> Reusing existing VM ${VM_NAME} in ${RESOURCE_GROUP} (${LOCATION}); nothing new is created"
  power="$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv | tr -d '[:space:]')"
  echo "    power state: ${power#PowerState/}"
  if [ "$power" != "PowerState/running" ]; then
    echo "==> Starting ${VM_NAME} (Spot start can fail if the region has no capacity)"
    az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none
  fi
else
# No existing stack VM: create the shared resource group and a dated VM.

echo "==> Resource group ${RESOURCE_GROUP} (${LOCATION})"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags "${TAGS[@]}" -o none

echo "==> NSG ${NSG} (default rules only: deny inbound from the internet)"
az network nsg create -g "$RESOURCE_GROUP" -n "$NSG" -l "$LOCATION" --tags "${TAGS[@]}" -o none

echo "==> NAT gateway ${NAT} for outbound-only internet access"
az_with_placement network public-ip create -g "$RESOURCE_GROUP" -n "$NAT_PIP" -l "$LOCATION" \
  --sku Standard --allocation-method Static --tags "${TAGS[@]}" -o none
az_with_placement network nat gateway create -g "$RESOURCE_GROUP" -n "$NAT" -l "$LOCATION" \
  --public-ip-addresses "$NAT_PIP" --idle-timeout 10 \
  --tags "${TAGS[@]}" -o none

echo "==> VNet ${VNET} / subnet ${SUBNET}"
az network vnet create -g "$RESOURCE_GROUP" -n "$VNET" -l "$LOCATION" \
  --address-prefixes "$VNET_CIDR" --tags "${TAGS[@]}" -o none
az network vnet subnet create -g "$RESOURCE_GROUP" --vnet-name "$VNET" -n "$SUBNET" \
  --address-prefixes "$SUBNET_CIDR" \
  --network-security-group "$NSG" --nat-gateway "$NAT" \
  --default-outbound-access false -o none

IDENTITIES=('[system]')
if [ -n "$INGEST_IDENTITY_ID" ] && command az identity show --ids "$INGEST_IDENTITY_ID" -o none 2>/dev/null; then
  IDENTITIES+=("$INGEST_IDENTITY_ID")
else
  echo "==> WARNING: no ingestion identity for ${LOCATION} in ${RESOURCE_GROUP}; provision monitoring to enable telemetry"
fi

if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none 2>/dev/null; then
  echo "==> VM ${VM_NAME} already exists; skipping create"
else
  echo "==> Spot VM ${VM_NAME} (${VM_SIZE}, ${PLACEMENT}), no public IP"
  # Trusted Launch with Secure Boot off: Secure Boot rejects unsigned
  # out-of-tree NVIDIA kernel modules. Security type "Standard" needs the
  # Microsoft.Compute/UseStandardSecurityType feature registered on the
  # subscription.
  az_with_placement vm create -g "$RESOURCE_GROUP" -n "$VM_NAME" -l "$LOCATION" \
    --size "$VM_SIZE" --image "$IMAGE" \
    --security-type TrustedLaunch --enable-secure-boot false --enable-vtpm true \
    --priority Spot --eviction-policy Deallocate --max-price -1 \
    --vnet-name "$VNET" --subnet "$SUBNET" \
    --public-ip-address "" --nsg "" \
    --admin-username "$ADMIN_USER" --generate-ssh-keys \
    --assign-identity "${IDENTITIES[@]}" \
    --os-disk-size-gb "$OS_DISK_GB" --storage-sku Premium_LRS \
    --data-disk-sizes-gb "$DATA_DISK_GB" --data-disk-caching ReadOnly \
    --tags "${TAGS[@]}" -o table
fi
fi  # REUSE

# No auto-shutdown schedule: a Spot VM runs until it is evicted or you stop
# it with scripts/vm-power.sh stop (deallocate, so the GPU stops billing).

echo "==> Remote check through run-command (no network path to the VM needed)"
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
  --scripts 'hostname; uname -r; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT; lspci | grep -i nvidia; curl -s -m 10 https://ifconfig.me; echo' \
  --query 'value[0].message' -o tsv

echo "==> Done. VM private IP:"
az vm list-ip-addresses -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --query '[0].virtualMachine.network.{private:privateIpAddresses[0], public:publicIpAddresses[0].ipAddress}' -o table
