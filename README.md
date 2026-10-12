# Deploy Qwen3.8-27B on an Azure H100 Spot VM

This repository contains an end-to-end Azure demo for serving Qwen3.8-27B on one H100 GPU. It provisions the infrastructure, deploys an OpenAI-compatible API, collects telemetry, and includes a Grafana dashboard for performance, reliability, and token economics.

## Fork information

This repository is a personal fork of [`1w2w3y/wuyi-labs`](https://github.com/1w2w3y/wuyi-labs). The upstream repository contains experiments, code samples, demos, and resources for artificial intelligence, cloud computing, and software engineering.

This fork focuses on a reusable H100 deployment with Azure-native monitoring.

## What this repository does

The current demo lives in [`2610-h100-qwen-38-27b/`](2610-h100-qwen-38-27b/). It automates the path from an empty Azure resource group to an observable large language model endpoint.

The demo includes:

- **GPU inference**: Qwen3.8-27B FP8 on one `Standard_NC40ads_H100_v5` VM
- **Model server**: vLLM with FP8 key-value cache, prefix caching, and Multi-Token Prediction (MTP)
- **API gateway**: LiteLLM exposes an OpenAI-compatible API and records model telemetry
- **Private host**: the VM has no public IP or Secure Shell (SSH) ingress
- **Optional public access**: ngrok publishes the gateway with an Internet Protocol (IP) allow-list
- **Azure monitoring**: OpenTelemetry sends metrics, logs, and traces to Azure Monitor
- **Grafana dashboard**: panels cover cost, tokens, latency, GPU load, host health, traces, and logs
- **Operations**: scripts provision, deploy, benchmark, inspect, start, stop, and remove the stack

## Architecture

The stack separates model serving, public access, and observability into Docker Compose files. You can deploy the core service alone or add either overlay.

```text
Client
  |
  +--> optional ngrok endpoint with an IP allow-list
         |
         v
      LiteLLM gateway on 127.0.0.1:4000
         |
         v
      vLLM on 127.0.0.1:8096
         |
         v
      Qwen3.8-27B FP8 on one H100 NVL GPU

LiteLLM traces -------+
vLLM metrics ---------+
GPU metrics ----------+--> OpenTelemetry Collector
Host metrics ---------+       |
Container metrics ----+       +--> Application Insights: traces and logs
Container logs -------+       +--> Azure Monitor workspace: metrics
Host logs ------------+
                                      |
                                      v
                              Grafana dashboard
```

[`compose.yaml`](2610-h100-qwen-38-27b/compose.yaml) defines model download, vLLM, and LiteLLM. [`compose.observability.yaml`](2610-h100-qwen-38-27b/compose.observability.yaml) adds the OpenTelemetry Collector and NVIDIA Data Center GPU Manager (DCGM) exporter. [`compose.ngrok.yaml`](2610-h100-qwen-38-27b/compose.ngrok.yaml) adds the optional public tunnel.

Every service binds to localhost on the VM. Azure Network Security Group rules deny inbound internet traffic, and a Network Address Translation (NAT) gateway handles outbound traffic.

## Model serving

The demo downloads the pinned [`Qwen/Qwen3.8-27B-FP8`](https://huggingface.co/Qwen/Qwen3.8-27B-FP8) checkpoint to a persistent data disk. The container then runs without Hugging Face network access.

The vLLM configuration targets the 94 GB H100 NVL:

- Native 262K context window
- FP8 weights and key-value cache
- Prefix caching
- Three speculative MTP tokens
- Up to 32 concurrent sequences
- Automatic tool selection with the Qwen parser
- Image input with bounded image count and dimensions

LiteLLM publishes the model as `local-llm`. Clients can use the OpenAI chat completions interface without knowing the internal vLLM service address.

## Azure infrastructure

[`infra/provision-spot-vm.sh`](2610-h100-qwen-38-27b/infra/provision-spot-vm.sh) creates the compute environment. It provisions the VM, data disk, virtual network, Network Security Group, NAT gateway, and managed identities.

The VM uses Azure Spot capacity by default. [`infra/spot-regions.sh`](2610-h100-qwen-38-27b/infra/spot-regions.sh) compares eviction rates, prices, and placement scores before deployment. You can remove the Spot flags when you need regular capacity and have the required quota.

The scripts support zonal and regional placement. Regional placement gives the Azure allocator more options when H100 capacity is scarce.

## Monitoring and telemetry

[`infra/provision-monitoring.sh`](2610-h100-qwen-38-27b/infra/provision-monitoring.sh) creates the Azure monitoring destination. It uses [`infra/monitoring-otlp.json`](2610-h100-qwen-38-27b/infra/monitoring-otlp.json) to deploy:

- A Log Analytics workspace for traces and logs
- A workspace-based Application Insights resource
- An Azure Monitor workspace for metrics
- A Data Collection Endpoint (DCE)
- A Data Collection Rule (DCR)
- A regional user-assigned managed identity
- The role assignment required to publish telemetry

The script discovers the generated ingestion endpoints and writes five non-secret values to the local `.env` file. It can also attach the regional identity to existing tagged demo VMs.

The OpenTelemetry Collector authenticates with the managed identity. No monitoring secret is stored on disk.

### Collected signals

[`observability/otelcol/config.yaml`](2610-h100-qwen-38-27b/observability/otelcol/config.yaml) defines one pipeline for each OpenTelemetry signal:

- **Traces**: LiteLLM generative artificial intelligence spans received over OpenTelemetry Protocol (OTLP)
- **Model metrics**: vLLM request, token, cache, scheduler, and latency measurements
- **Gateway metrics**: LiteLLM request and response measurements
- **GPU metrics**: utilization, memory, power, temperature, clocks, and throttling from DCGM
- **Host metrics**: central processing unit, memory, load, disk, filesystem, network, paging, and process data
- **Container metrics**: CPU, memory, network, block input/output, uptime, process count, and restart data
- **Logs**: selected Docker container logs and host deployment logs
- **Collector metrics**: queue, export, receive, refusal, and failure measurements

The collector adds Azure resource metadata, deployment details, service names, container names, and `upstream_model`. That model label lets you compare different model runs on the same infrastructure.

The collector filters routine health checks, metric scrapes, empty lines, and Docker pull progress. A persistent queue protects telemetry during temporary export failures.

## Grafana dashboard

[`observability/grafana/h100-llm.json`](2610-h100-qwen-38-27b/observability/grafana/h100-llm.json) is ready to import into Grafana. [`observability/grafana/build_dashboard.py`](2610-h100-qwen-38-27b/observability/grafana/build_dashboard.py) generates the JSON source.

The dashboard contains these sections:

- **Overview**: requests, tokens, throughput, latency, errors, and active work
- **Token economics**: estimated token revenue, VM cost, margin, and break-even throughput
- **Throughput**: input tokens, cached tokens, output tokens, and per-request distributions
- **LiteLLM gateway**: gateway traffic, errors, overhead, and response behavior
- **Traffic and latency**: request queueing, time to first token, inter-token latency, and end-to-end latency
- **Cache and scheduling**: key-value cache use, prefix cache hits, preemptions, speculative acceptance, and completion reasons
- **GPU**: utilization, memory, power, temperature, clocks, and throttle reasons
- **Host and containers**: host resources, disk use, network traffic, container resources, uptime, and restarts
- **Telemetry pipeline**: collector receive, export, queue, refusal, and failure state
- **Traces and logs**: LiteLLM model-call spans plus vLLM engine and warning logs from Application Insights

The dashboard reads Prometheus metrics from the Azure Monitor workspace. It uses Azure Monitor queries for Application Insights traces and logs.

Grafana is optional. Azure continues to ingest telemetry when you do not deploy or configure a Grafana instance.

## Deploy the demo

Install the Azure Command-Line Interface (CLI) and `jq`, then authenticate with `az login`. You also need 40 low-priority virtual CPUs of Spot quota in your selected region.

Run these commands from the demo directory:

```bash
cd 2610-h100-qwen-38-27b
cp .env.example .env
LOCATION=southeastasia infra/provision-monitoring.sh
LOCATION=southeastasia ZONE=2 \
  IDENTITY_RG=rg-llm-telemetry infra/provision-spot-vm.sh
scripts/vm-run.sh scripts/bootstrap-host.sh
scripts/deploy.sh up
scripts/vm-run.sh scripts/smoke-test.sh
```

The first deployment downloads the model and can take about 20 minutes. Set both `NGROK_AUTHTOKEN` and `NGROK_URL` in `.env` to enable ngrok. Leave both values empty to keep the gateway private.

Read the [complete deployment guide](2610-h100-qwen-38-27b/README.md) for region selection, monitoring options, dashboard import, troubleshooting, and cleanup.

## Operate and benchmark the stack

The repository includes scripts for common operations:

| Script | Purpose |
|---|---|
| `scripts/vm-power.sh` | Start, stop, or inspect the VM |
| `scripts/vm-run.sh` | Run a command or local script through Azure VM Run Command |
| `scripts/vm-status.sh` | Inspect containers, downloads, and GPU memory |
| `scripts/smoke-test.sh` | Test health, chat, tools, and single-stream decoding |
| `scripts/bench.sh` | Benchmark concurrency levels and shared-prefix workloads |
| `scripts/realtext.py` | Measure decoding throughput with realistic text |
| `scripts/deploy.sh` | Copy the demo to the VM and manage Docker Compose |
| `scripts/bootstrap-host.sh` | Configure storage, NVIDIA drivers, Docker, and startup |

The included measurements reached 165 to 172 output tokens per second for one stream. A 32-request real-text run reached about 1,550 output tokens per second. Actual results depend on model settings, prompt shape, region, image versions, and available GPU clocks.

## Security model

The deployment reduces the VM’s public attack surface:

- The VM has no public IP
- The Network Security Group allows no inbound internet traffic
- Administrative commands use Azure VM Run Command instead of SSH
- Service ports bind to localhost
- Monitoring uses managed identity authentication
- The optional ngrok policy restricts source IP addresses and blocks `/metrics`

LiteLLM does not use an application-level master key in the default configuration. Add LiteLLM authentication or an ngrok authentication policy before sharing the endpoint with multiple users.

## Cost and availability

Azure Spot pricing and H100 capacity change by region and time. Spot VMs can be evicted without notice, so this configuration targets experiments, benchmarks, and interruptible demos.

The eviction policy deallocates the VM. The model remains on the data disk, and the stack restarts after capacity returns. Use regular capacity for production workloads that require predictable availability.

The Grafana token economics panels compare estimated token revenue with the configured VM hourly price. Change the dashboard variables to match your Azure rate and pricing model.

## Repository layout

```text
2610-h100-qwen-38-27b/
├── compose.yaml                 Core model and gateway services
├── compose.observability.yaml   Collector and GPU monitoring
├── compose.ngrok.yaml           Optional public endpoint
├── config/                      ngrok traffic policy
├── images/                      Custom vLLM image
├── infra/                       Azure provisioning and templates
├── litellm/                     Gateway, logging, and callbacks
├── observability/
│   ├── dcgm/                    GPU metric selection
│   ├── grafana/                 Dashboard source and JSON
│   └── otelcol/                 Telemetry pipeline
└── scripts/                     Deployment, operations, and benchmarks
```

## License

This repository retains the upstream project’s [MIT License](LICENSE).
