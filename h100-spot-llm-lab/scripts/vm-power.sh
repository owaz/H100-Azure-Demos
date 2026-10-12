#!/usr/bin/env bash
# Start, stop or show the stack VM.
#
#   scripts/vm-power.sh status   # power state
#   scripts/vm-power.sh start    # start; the llm-compose-up unit brings the stack up on boot
#   scripts/vm-power.sh stop     # deallocate (az vm stop alone keeps billing for the GPU)
#
# After a start, vLLM needs about 5 minutes to reload weights from the cold
# disk; poll with scripts/vm-run.sh scripts/vm-status.sh.
#
# Target: VM_NAME when set, or the newest tagged stack VM in RESOURCE_GROUP.
set -euo pipefail
export MSYS_NO_PATHCONV=1

ACTION="${1:-}"
case "$ACTION" in
  start|stop|status) ;;
  *) echo "usage: vm-power.sh start|stop|status" >&2; exit 2 ;;
esac

SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id -o tsv | tr -d '[:space:]')}"   # default: the az CLI's current subscription
: "${RESOURCE_GROUP:?set RESOURCE_GROUP to the lab resource group}"
if [ -z "${VM_NAME:-}" ]; then
  # shellcheck source=lib/find-vm.sh
  . "$(dirname "$0")/lib/find-vm.sh"
  rc=0; find_stack_vm || rc=$?
  if [ "$rc" = 1 ]; then echo "no stack VM found in resource group ${RESOURCE_GROUP}; run infra/provision-spot-vm.sh" >&2; exit 1; fi
  [ "$rc" = 0 ] || exit 1
  VM_NAME="$FOUND_VM"
fi

power_state() {
  az vm get-instance-view --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv | tr -d '\r'
}

state="$(power_state)"
echo "[vm-power] ${VM_NAME} (${RESOURCE_GROUP}): ${state#PowerState/}"

case "$ACTION" in
  start)
    if [ "$state" = "PowerState/running" ]; then exit 0; fi
    echo "==> Starting (Spot start can fail if the region has no capacity)"
    az vm start --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none
    echo "==> $(power_state | sed 's|PowerState/||'). Stack comes up on boot; check with scripts/vm-run.sh scripts/vm-status.sh"
    ;;
  stop)
    if [ "$state" = "PowerState/deallocated" ]; then exit 0; fi
    echo "==> Deallocating"
    az vm deallocate --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none
    echo "==> $(power_state | sed 's|PowerState/||')"
    ;;
esac
