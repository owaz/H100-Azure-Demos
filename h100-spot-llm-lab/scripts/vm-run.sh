#!/usr/bin/env bash
# Run a local script or an inline command on the VM as root via
# `az vm run-command invoke`. The VM has no inbound network path; this goes
# through the Azure control plane. Only the last ~4 KB of output comes back.
#
#   scripts/vm-run.sh scripts/bootstrap-host.sh       # run a local script file
#   scripts/vm-run.sh -c 'docker compose ps'          # run an inline command
#
# Target: VM_NAME when set, or the newest tagged stack VM in RESOURCE_GROUP.
set -euo pipefail
export MSYS_NO_PATHCONV=1

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
echo "[vm-run] ${VM_NAME} (${RESOURCE_GROUP})" >&2

if [[ "${1:-}" == "-c" ]]; then
  shift
  SCRIPT="$*"
  FILE=""
else
  FILE="${1:?usage: vm-run.sh <script-file> | -c '<command>'}"
  SCRIPT=""
fi

# Azure reports whether the Run Command extension ran, not whether the guest
# script succeeded. Wrap the script and recover its real exit status from a
# sentinel in the extension output.
WRAPPED_SCRIPT="$(mktemp)"
trap 'rm -f "$WRAPPED_SCRIPT"' EXIT
{
  printf '%s\n' '#!/usr/bin/env bash' 'set +e' '('
  if [ -n "$FILE" ]; then
    cat "$FILE"
  else
    printf '%s\n' "$SCRIPT"
  fi
  printf '%s\n' ')' 'vm_run_rc=$?'
  printf '%s\n' "printf '\n__VM_RUN_EXIT_CODE__=%s\n' \"\$vm_run_rc\""
  printf '%s\n' 'exit "$vm_run_rc"'
} > "$WRAPPED_SCRIPT"

# Windows az.cmd can't resolve Git Bash paths such as /tmp/...
AZ_SCRIPT="$WRAPPED_SCRIPT"
command -v cygpath >/dev/null && AZ_SCRIPT="$(cygpath -w "$AZ_SCRIPT")"

az_status=0
message="$(az vm run-command invoke --subscription "$SUBSCRIPTION" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --command-id RunShellScript --scripts "@${AZ_SCRIPT}" \
  --query 'value[0].message' -o tsv)" || az_status=$?
message="$(printf '%s' "$message" | tr -d '\r')"
[ -n "$message" ] && printf '%s\n' "$message" | sed '/^__VM_RUN_EXIT_CODE__=[0-9][0-9]*$/d'
[ "$az_status" = 0 ] || exit "$az_status"

remote_status="$(printf '%s\n' "$message" |
  sed -n 's/^__VM_RUN_EXIT_CODE__=\([0-9][0-9]*\)$/\1/p' |
  tail -n 1)"
if [ -z "$remote_status" ]; then
  echo "ERROR: Azure Run Command returned no remote exit status" >&2
  exit 1
fi
exit "$remote_status"
