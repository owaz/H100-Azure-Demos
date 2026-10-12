# Qwen3.8-27B on an H100 Azure Spot VM

Sample code for the blog post *Qwen3.8-27B on a $2 H100 Azure Spot VM: does it pay off?*

It serves [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B-FP8) (official FP8 checkpoint) from one
`Standard_NC40ads_H100_v5` VM (1x H100 NVL, 94 GB) on
[Azure Spot Virtual Machines](https://learn.microsoft.com/azure/virtual-machines/spot-vms), with Docker Compose:

```text
client
  -> ngrok public URL (IP allow-list)
    -> LiteLLM gateway  127.0.0.1:4000   alias "local-llm", OTel traces, Prometheus metrics
      -> vLLM           127.0.0.1:8096   Qwen3.8-27B FP8, MTP speculative decoding, prefix caching

OpenTelemetry Collector -> Application Insights (traces, logs) + Azure Monitor workspace (metrics)
                        -> Grafana dashboard (observability/grafana/h100-llm.json)
```

The VM has no public IP. Outbound traffic goes through a NAT gateway, and you administer the VM through
`az vm run-command`, so it needs no SSH ingress.

**Grafana dashboard:** [`observability/grafana/h100-llm.json`](observability/grafana/h100-llm.json), ready to
import (see [Dashboard](#dashboard)).

## Cost and eviction

In October 2026 the Linux Spot price of `Standard_NC40ads_H100_v5` ranged from $1.29 to $3.28 per hour
across the regions in the lowest eviction-rate bucket (0-5%), and the regions we ran in were $1.55-$1.84.
Spot prices change; check [Azure pricing](https://azure.microsoft.com/pricing/details/virtual-machines/linux/)
and `infra/spot-regions.sh` before you start.

A Spot VM can be evicted at any time. Over about 40 hours of running in five regions, our VM was evicted
seven times, between one minute and 8.5 hours after it started. The eviction policy here is Deallocate, so the
model stays on the data disk and `scripts/vm-power.sh start` brings the stack back when capacity returns.
For steady serving, use regular (non-Spot) capacity: request `Standard NCadsH100v5 Family` quota and drop
the `--priority Spot` flags in `infra/provision-spot-vm.sh`.

## Prerequisites

- Azure CLI and `jq`, logged in (`az login`), in Bash (Linux, macOS, WSL or Git Bash on Windows).
- At least 40 low-priority (Spot) vCPUs of quota in the region you pick.
- Optional: an [ngrok](https://ngrok.com) account with an authtoken and a reserved domain for a public URL.
  The deployment enables ngrok only when both `NGROK_AUTHTOKEN` and `NGROK_URL` are set in the
  workstation `.env`.
- For telemetry provisioning, permission to create resources and role assignments in the subscription
  (Owner, or Contributor plus User Access Administrator). To skip telemetry, deploy with
  `COMPOSE_FILES="-f compose.yaml"`.

## Run it

```bash
cp .env.example .env            # optionally fill in both NGROK_* values
# when using ngrok, edit config/ngrok-traffic-policy.yaml with the allowed client IPs

infra/spot-regions.sh southeastasia uksouth germanywestcentral   # eviction rate, price, placement score

# Recommended: create monitoring first. This fills the five telemetry values
# in .env and creates a region-locked ingestion identity.
LOCATION=southeastasia infra/provision-monitoring.sh

LOCATION=southeastasia ZONE=2 IDENTITY_RG=rg-llm-telemetry infra/provision-spot-vm.sh
scripts/vm-run.sh scripts/bootstrap-host.sh   # data disk, NVIDIA driver, Docker, container toolkit (~4 min)
scripts/deploy.sh up                          # copy this folder to the VM and start the stack (~20 min first time)
scripts/vm-run.sh scripts/vm-status.sh        # containers, model download, GPU memory
scripts/vm-run.sh scripts/smoke-test.sh       # health, chat, tool call, single-stream decode speed
```

The reverse order also works: provision the VM without `IDENTITY_RG`, then run
`LOCATION=<vm-region> infra/provision-monitoring.sh`. The monitoring script
finds tagged stack VMs in that region and attaches the identity. It is safe to
rerun: existing resources, role assignments and identity attachments are
reused.

If Azure returns `OverconstrainedZonalAllocationRequest`, retry without the
availability-zone constraint:

```bash
LOCATION=southeastasia ZONE=none IDENTITY_RG=rg-llm-telemetry infra/provision-spot-vm.sh
```

`ZONE=none` creates a regional VM and omits the zone from the VM, NAT gateway,
and NAT public IP. It improves the allocator's options but does not guarantee
scarce H100 Spot capacity. If regional placement also fails, try another region
reported by `infra/spot-regions.sh`, or use regular capacity after obtaining
`Standard NCadsH100v5 Family` quota. A failed attempt's resource group is not
reused because it contains no tagged stack VM; delete it separately when it is
no longer needed.

When both ngrok values are configured, call the model through its URL from an
allow-listed client:

```bash
curl https://<your-domain>.ngrok-free.dev/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"local-llm","messages":[{"role":"user","content":"Hello"}]}'
```

Day to day:

```bash
scripts/vm-power.sh stop|start|status         # deallocate / start (the stack restarts on boot)
scripts/vm-run.sh -c 'docker logs --tail 50 qwen3.8-27b'
scripts/vm-run.sh scripts/bench.sh            # vllm bench serve at concurrency 1/4/16/32 + shared prefix
scripts/vm-run.sh -c 'python3 /opt/llm-self-hosting/scripts/realtext.py 1 32'   # real-text decode speed
az group delete -n <resource-group> --yes     # remove everything
```

`deploy.sh` sends the files of this folder plus the non-empty lines of your local `.env`, and
`scripts/merge-env.sh` merges them into `/opt/llm-self-hosting/.env` on the VM.
By default it starts the core and observability Compose files, adding
`compose.ngrok.yaml` only when both ngrok values are non-empty in the
workstation `.env`. Removing both values disables ngrok on the next deployment;
a partial configuration fails before syncing. Set
`COMPOSE_FILES` to override this automatic selection.

## Monitoring provisioning

[`infra/provision-monitoring.sh`](infra/provision-monitoring.sh) creates or
reuses the complete Azure destination required by
[`compose.observability.yaml`](compose.observability.yaml):

- a Log Analytics workspace for OTLP traces and logs;
- a workspace-based Application Insights resource for application views and KQL;
- an Azure Monitor workspace for OTLP/Prometheus metrics;
- a public Data Collection Endpoint (DCE) and a Data Collection Rule (DCR)
  that route each signal to the correct workspace;
- a region-isolated user-assigned identity with **Monitoring Metrics Publisher**
  on the DCR; and
- an identity attachment to every tagged stack VM in the selected region.

The script uses the checked-in
[`infra/monitoring-otlp.json`](infra/monitoring-otlp.json) template, derives the
DCR immutable ID and DCE domains from Azure, and replaces only the five
telemetry keys in the ignored workstation `.env`. It also prints those values
for CI or copy/paste use. Common options:

```bash
LOCATION=southeastasia infra/provision-monitoring.sh
LOCATION=southeastasia WRITE_ENV=0 infra/provision-monitoring.sh  # print only
LOCATION=southeastasia ATTACH_VMS=0 infra/provision-monitoring.sh # don't attach VMs
```

Resource names can be overridden with `MONITORING_RG`, `LAW_NAME`, `AMW_NAME`,
`APP_INSIGHTS_NAME`, `DCE_NAME` and `DCR_NAME`. All resources must be in the
same region. The script registers required Azure resource providers when the
caller has permission.

To remove monitoring, first stop using its identity, then delete its resource
group:

```bash
az group delete -n rg-llm-telemetry --yes
```

The lower-level [`infra/telemetry-identities.sh`](infra/telemetry-identities.sh)
remains available for adding identities in more regions to an existing DCR,
but normal deployments should use `provision-monitoring.sh`.

## What we measured

One H100 NVL, vLLM 26.07 (NGC), MTP with 3 speculative tokens, FP8 KV cache, October 2026:

| | BF16 checkpoint | FP8 checkpoint |
|---|---|---|
| Weights in GPU memory | 51.9 GiB | 29.0 GiB |
| KV cache | 805K tokens (GPU memory 0.90) | 1.5M tokens (GPU memory 0.93) |
| Single-stream decode, 512 tokens, thinking off | 124 tok/s | 165-172 tok/s |
| Real text, 32 concurrent requests | not measured | ~1,550 output tok/s |

## Dashboard

[`observability/grafana/h100-llm.json`](observability/grafana/h100-llm.json) is the h100-llm dashboard,
generated by `build_dashboard.py`. To import it into Grafana, for example Azure Managed Grafana:

1. Go to **Dashboards** > **New** > **Import** and upload `h100-llm.json`.
2. When asked for the **Application Insights resource ID**, enter the ID of the Application Insights resource
   with OTLP support that receives your traces and logs
   (`/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Insights/components/<name>`).
3. At the top of the dashboard, pick the Prometheus data source of your Azure Monitor workspace in
   **datasource**, and your Azure Monitor data source in **Azure Monitor**.

If your Azure Monitor workspace data source uses the Azure Monitor Managed Service for Prometheus plugin
(Grafana 13 and later), change the `datasource` variable's type to that plugin.

The monitoring provisioner does not create Azure Managed Grafana. Grafana is
optional: the collector and Azure resources ingest data without it. The files
under `observability/` align with the provisioned resources as follows:

- `otelcol/config.yaml` authenticates with the regional managed identity and
  exports traces, logs and metrics to the three generated OTLP URLs.
- `dcgm/counters.csv` selects the H100 GPU metrics scraped by `dcgm-exporter`.
- `grafana/h100-llm.json` and `build_dashboard.py` visualize metrics from the
  Azure Monitor workspace and traces/logs from Application Insights.

The **Token economics** row compares what the
tokens served would sell for, at the price variables at the top of the dashboard, with the VM price per
hour. The defaults are a $2 VM hour and a public list price for Qwen3.8-27B in October 2026
($0.425 per 1M input tokens, $0.085 cached input, $2.55 output); change them to your own.

The **Traces and logs** row reads Application Insights with KQL through the Azure Monitor data source: one
row per model call from the LiteLLM spans (duration, time to first token, tokens, finish reason, trace ID),
and vLLM's engine-stats and warning log lines, from the Application Insights resource you entered on import
(the hidden `appinsights` constant; change it under **Settings** > **Variables**). The panels show selected
fields only: the LLM-call spans also carry every tool definition the client sends.

Every metric, log and span carries `upstream_model` (from `LLM_MODEL`), so runs of different models on the
same VM can be compared.

## Access control

The LiteLLM gateway has no authentication. Access control is the localhost bind on the VM plus the ngrok
IP allow-list in `config/ngrok-traffic-policy.yaml`, which also blocks `/metrics` at the edge. Add a
LiteLLM master key or an ngrok auth policy if you need per-user access.
