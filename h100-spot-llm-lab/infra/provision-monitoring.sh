#!/usr/bin/env bash
# Provision the Azure resources used by compose.observability.yaml.
#
# The script is idempotent and supports either deployment order:
#   RESOURCE_GROUP=rg-llm-lab LOCATION=southeastasia infra/provision-monitoring.sh
#   RESOURCE_GROUP=rg-llm-lab LOCATION=southeastasia ZONE=none infra/provision-spot-vm.sh
#
# Or provision the VM first; this script then attaches the regional ingestion
# identity to every tagged stack VM in LOCATION.
#
# Set WRITE_ENV=0 to print the resolved values without modifying .env.
set -euo pipefail
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/monitoring-otlp.json"

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id -o tsv | tr -d '[:space:]')}"
LOCATION="${LOCATION:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
WRITE_ENV="${WRITE_ENV:-1}"
ATTACH_VMS="${ATTACH_VMS:-1}"
ENV_FILE="${ENV_FILE:-${ROOT}/.env}"
TAGS=(project=llm-self-hosting purpose=otlp-ingestion)

az_sub() {
  command az "$@" --subscription "$SUBSCRIPTION"
}

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

case "$WRITE_ENV" in 0|1) ;; *) echo "WRITE_ENV must be 0 or 1" >&2; exit 2 ;; esac
case "$ATTACH_VMS" in 0|1) ;; *) echo "ATTACH_VMS must be 0 or 1" >&2; exit 2 ;; esac
[ -f "$TEMPLATE" ] || { echo "monitoring template not found: ${TEMPLATE}" >&2; exit 1; }
resolve_resource_group

if [ -z "$LOCATION" ]; then
  # shellcheck source=../scripts/lib/find-vm.sh
  . "${ROOT}/scripts/lib/find-vm.sh"
  rc=1
  if [ "$(az_sub group exists -n "$RESOURCE_GROUP" -o tsv)" = true ]; then
    find_stack_vm || rc=$?
  fi
  case "$rc" in
    0)
      LOCATION="$FOUND_LOCATION"
      echo "==> LOCATION not set; using ${LOCATION} from ${FOUND_VM}"
      ;;
    1)
      echo "usage: LOCATION=<azure-region> $0" >&2
      echo "       LOCATION may be omitted only when a tagged stack VM already exists" >&2
      exit 2
      ;;
    *)
      echo "==> Aborting: cannot discover a stack VM location" >&2
      exit 1
      ;;
  esac
fi

LOCATION_KEY="$(printf '%s' "$LOCATION" | tr '[:upper:]' '[:lower:]')"
LAW_NAME="${LAW_NAME:-law-llm-telemetry-${LOCATION_KEY}}"
AMW_NAME="${AMW_NAME:-amw-llm-telemetry-${LOCATION_KEY}}"
APP_INSIGHTS_NAME="${APP_INSIGHTS_NAME:-appi-llm-telemetry-${LOCATION_KEY}}"
DCE_NAME="${DCE_NAME:-dce-llm-telemetry-${LOCATION_KEY}}"
DCR_NAME="${DCR_NAME:-dcr-llm-telemetry-${LOCATION_KEY}}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-deploy-llm-monitoring-${LOCATION_KEY}}"

echo "==> Subscription ${SUBSCRIPTION}"
echo "==> Resource group ${RESOURCE_GROUP} (${LOCATION})"

for provider in Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor Microsoft.ManagedIdentity; do
  state="$(az_sub provider show -n "$provider" --query registrationState -o tsv)"
  if [ "$state" != Registered ]; then
    echo "==> Registering ${provider}"
    az_sub provider register -n "$provider" --wait
  fi
done

az_sub group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags "${TAGS[@]}" -o none

check_location() {
  local label="$1"
  local actual="$2"
  if [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != \
       "$(printf '%s' "$LOCATION" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: ${label} already exists in ${actual}, expected ${LOCATION}" >&2
    echo "Use different resource names or a different RESOURCE_GROUP." >&2
    exit 1
  fi
}

if az_sub monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$LAW_NAME" -o none 2>/dev/null; then
  check_location "$LAW_NAME" "$(az_sub monitor log-analytics workspace show \
    -g "$RESOURCE_GROUP" -n "$LAW_NAME" --query location -o tsv)"
  echo "==> Reusing Log Analytics workspace ${LAW_NAME}"
else
  echo "==> Creating Log Analytics workspace ${LAW_NAME}"
  az_sub monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$LAW_NAME" \
    -l "$LOCATION" --tags "${TAGS[@]}" -o none
fi
LAW_ID="$(az_sub monitor log-analytics workspace show -g "$RESOURCE_GROUP" \
  -n "$LAW_NAME" --query id -o tsv | tr -d '\r')"

if az_sub monitor account show -g "$RESOURCE_GROUP" -n "$AMW_NAME" -o none 2>/dev/null; then
  check_location "$AMW_NAME" "$(az_sub monitor account show \
    -g "$RESOURCE_GROUP" -n "$AMW_NAME" --query location -o tsv)"
  echo "==> Reusing Azure Monitor workspace ${AMW_NAME}"
else
  echo "==> Creating Azure Monitor workspace ${AMW_NAME}"
  az_sub monitor account create -g "$RESOURCE_GROUP" -n "$AMW_NAME" \
    -l "$LOCATION" --tags "${TAGS[@]}" -o none
fi
AMW_ID="$(az_sub monitor account show -g "$RESOURCE_GROUP" \
  -n "$AMW_NAME" --query id -o tsv | tr -d '\r')"

if existing_app_location="$(az_sub resource show -g "$RESOURCE_GROUP" \
    -n "$APP_INSIGHTS_NAME" --resource-type Microsoft.Insights/components \
    --api-version 2020-02-02 --query location -o tsv 2>/dev/null)"; then
  check_location "$APP_INSIGHTS_NAME" "$existing_app_location"
fi
if existing_dce_location="$(az_sub resource show -g "$RESOURCE_GROUP" \
    -n "$DCE_NAME" --resource-type Microsoft.Insights/dataCollectionEndpoints \
    --api-version 2024-03-11 --query location -o tsv 2>/dev/null)"; then
  check_location "$DCE_NAME" "$existing_dce_location"
fi
if existing_dcr_location="$(az_sub resource show -g "$RESOURCE_GROUP" \
    -n "$DCR_NAME" --resource-type Microsoft.Insights/dataCollectionRules \
    --api-version 2024-03-11 --query location -o tsv 2>/dev/null)"; then
  check_location "$DCR_NAME" "$existing_dcr_location"
fi

echo "==> Deploying Application Insights and OTLP routing"
OUTPUTS="$(az_sub deployment group create -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
  --template-file "$TEMPLATE" \
  --parameters location="$LOCATION" applicationInsightsName="$APP_INSIGHTS_NAME" \
    dataCollectionEndpointName="$DCE_NAME" dataCollectionRuleName="$DCR_NAME" \
    logAnalyticsWorkspaceResourceId="$LAW_ID" azureMonitorWorkspaceResourceId="$AMW_ID" \
  --query properties.outputs -o json)"

output() {
  printf '%s' "$OUTPUTS" | command jq -r --arg key "$1" '.[$key].value'
}

APP_INSIGHTS_ID="$(output applicationInsightsResourceId)"
AZMON_APPLICATION_ID="$(output applicationInsightsApplicationId)"
DCR_ID="$(output dataCollectionRuleResourceId)"
DCR_IMMUTABLE_ID="$(output dataCollectionRuleImmutableId)"
LOGS_INGESTION="$(output logsIngestionEndpoint)"
METRICS_INGESTION="$(output metricsIngestionEndpoint)"

echo "==> Creating regional ingestion identity and DCR role assignment"
SUBSCRIPTION="$SUBSCRIPTION" RESOURCE_GROUP="$RESOURCE_GROUP" DCR_ID="$DCR_ID" \
  REGIONS="$LOCATION" "${SCRIPT_DIR}/telemetry-identities.sh"
IDENTITY_NAME="id-llm-ingest-${LOCATION}"
IDENTITY_ID="$(az_sub identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" \
  --query id -o tsv | tr -d '\r')"
IDENTITY_CLIENT_ID="$(az_sub identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" \
  --query clientId -o tsv | tr -d '\r')"

if [ "$ATTACH_VMS" = 1 ]; then
  vm_rows="$(az_sub vm list -g "$RESOURCE_GROUP" \
    --query "[?tags.project=='llm-self-hosting' && tags.role=='llm-h100' && location=='${LOCATION}'].[resourceGroup,name]" \
    -o tsv | tr -d '\r')"
  if [ -n "$vm_rows" ]; then
    while IFS=$'\t' read -r vm_rg vm_name; do
      [ -n "$vm_name" ] || continue
      echo "==> Attaching ${IDENTITY_NAME} to ${vm_name}"
      az_sub vm identity assign -g "$vm_rg" -n "$vm_name" \
        --identities "$IDENTITY_ID" -o none
    done <<< "$vm_rows"
  else
    echo "==> No tagged H100 VM in ${RESOURCE_GROUP} and ${LOCATION}; provision the VM in this resource group"
  fi
fi

AZMON_TRACES_ENDPOINT="${LOGS_INGESTION}/dataCollectionRules/${DCR_IMMUTABLE_ID}/streams/Microsoft-OTLP-Traces/otlp/v1/traces"
AZMON_LOGS_ENDPOINT="${LOGS_INGESTION}/dataCollectionRules/${DCR_IMMUTABLE_ID}/streams/Microsoft-OTLP-Logs/otlp/v1/logs"
AZMON_METRICS_ENDPOINT="${METRICS_INGESTION}/dataCollectionRules/${DCR_IMMUTABLE_ID}/streams/Custom-Metrics-Otel/otlp/v1/metrics"

ENV_VALUES="$(cat <<EOF
TELEMETRY_UAMI_CLIENT_ID=${IDENTITY_CLIENT_ID}
AZMON_APPLICATION_ID=${AZMON_APPLICATION_ID}
AZMON_TRACES_ENDPOINT=${AZMON_TRACES_ENDPOINT}
AZMON_LOGS_ENDPOINT=${AZMON_LOGS_ENDPOINT}
AZMON_METRICS_ENDPOINT=${AZMON_METRICS_ENDPOINT}
EOF
)"

if [ "$WRITE_ENV" = 1 ]; then
  if [ ! -f "$ENV_FILE" ]; then
    cp "${ROOT}/.env.example" "$ENV_FILE"
  fi
  overrides="$(mktemp)"
  updated="$(mktemp)"
  cleanup() { rm -f "$overrides" "$updated"; }
  trap cleanup EXIT
  printf '%s\n' "$ENV_VALUES" > "$overrides"
  awk -F= '
    NR == FNR { values[$1] = $0; order[++count] = $1; next }
    ($1 in values) { print values[$1]; written[$1] = 1; next }
    { print }
    END {
      for (i = 1; i <= count; i++) {
        if (!(order[i] in written)) print values[order[i]]
      }
    }
  ' "$overrides" "$ENV_FILE" > "$updated"
  mv "$updated" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "==> Updated ${ENV_FILE}"
fi

echo "==> Monitoring configuration"
printf '%s\n' "$ENV_VALUES"
echo "APPLICATION_INSIGHTS_RESOURCE_ID=${APP_INSIGHTS_ID}"
echo "AZURE_MONITOR_WORKSPACE_RESOURCE_ID=${AMW_ID}"
echo "DATA_COLLECTION_RULE_RESOURCE_ID=${DCR_ID}"
