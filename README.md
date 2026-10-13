# Run fast AI pilots on Azure Spot H100 GPUs

Azure Spot Virtual Machines make unused Azure GPU capacity available at a lower price in exchange for interruptible availability. That trade-off is a strong fit for quick pilots, proofs of concept (PoCs), benchmarks, evaluations, and demos that need powerful GPUs for a limited time but do not require production uptime.

This repository turns that low-priority GPU approach into an end-to-end Azure deployment for serving a curated catalog of open models on one or two H100 GPUs. It provisions the infrastructure, deploys an OpenAI-compatible API, collects telemetry, and includes a Grafana dashboard for performance, reliability, and token economics.

## Why use Spot GPUs for pilots and PoCs?

- **Start with production-class accelerators**: test model quality, latency, throughput, and concurrency on one or two H100 GPUs without first committing to always-on capacity.
- **Move quickly from idea to endpoint**: use the included scripts to find candidate regions, provision the VM, deploy the model stack, and run smoke tests and benchmarks.
- **Measure before scaling**: capture application, model, GPU, host, and cost telemetry so a pilot can produce evidence for architecture and capacity decisions.
- **Pay for experiments, not idle time**: stop or deallocate the VM between sessions and keep the downloaded model on a persistent data disk.
- **Plan for interruption**: Spot VMs can be evicted at any time and capacity is not guaranteed. Use regular Azure capacity for production workloads that require predictable availability.

The complete deployment is in [`h100-spot-llm-lab/`](h100-spot-llm-lab/), with the step-by-step runbook in its [`README.md`](h100-spot-llm-lab/README.md).

## Fork information

This repository is a personal fork of [`1w2w3y/wuyi-labs`](https://github.com/1w2w3y/wuyi-labs). 

This fork focuses on a reusable H100 deployment with Azure-native monitoring.

## What this repository does

The current demo lives in [`h100-spot-llm-lab/`](h100-spot-llm-lab/). It automates the path from an empty Azure resource group to an observable large language model endpoint.

The demo includes:

- **GPU inference**: pinned permissive checkpoints selected for `Standard_NC40ads_H100_v5` (one GPU) or `Standard_NC80adis_H100_v5` (two GPUs)
- **Model server**: profile-driven vLLM with model-appropriate parallelism, context, cache, parser, and speculative settings
- **API gateway**: LiteLLM exposes an OpenAI-compatible API and records model telemetry
- **Private host**: the VM has no public IP or Secure Shell (SSH) ingress
- **Optional public access**: ngrok publishes the gateway with an Internet Protocol (IP) allow-list
- **Azure monitoring**: OpenTelemetry sends metrics, logs, and traces to Azure Monitor
- **Grafana dashboard**: panels cover cost, tokens, latency, GPU load, host health, traces, and logs
- **Operations**: scripts provision, deploy, benchmark, inspect, start, stop, and remove the stack

### Available models

The checked-in catalog currently includes:

- **Qwen3.8 27B FP8** (`Qwen/Qwen3.8-27B-FP8`)
- **OpenAI gpt-oss-20b** (`openai/gpt-oss-20b`)
- **OpenAI gpt-oss-120b** (`openai/gpt-oss-120b`)
- **Qwen3 32B FP8** (`Qwen/Qwen3-32B-FP8`)
- **Qwen3 30B-A3B Instruct 2507** (`Qwen/Qwen3-30B-A3B-Instruct-2507`)
- **Mistral Small 3.1 24B** (`mistralai/Mistral-Small-3.1-24B-Instruct-2503`)
- **Qwen2.5 72B Instruct** (`Qwen/Qwen2.5-72B-Instruct`, NC80 only)
- **Qwen3-Next 80B-A3B Instruct** (`Qwen/Qwen3-Next-80B-A3B-Instruct`, NC80 only)

NC80 offers all NC40-compatible models plus the two NC80-only models. See the
lab [model compatibility matrix](h100-spot-llm-lab/README.md#model-catalog-and-compatibility)
for validation status and download sizes.

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
      Selected catalog model on one or two H100 NVL GPUs

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

[`compose.yaml`](h100-spot-llm-lab/compose.yaml) defines model download, vLLM, and LiteLLM. [`compose.observability.yaml`](h100-spot-llm-lab/compose.observability.yaml) adds the OpenTelemetry Collector and NVIDIA Data Center GPU Manager (DCGM) exporter. [`compose.ngrok.yaml`](h100-spot-llm-lab/compose.ngrok.yaml) adds the optional public tunnel.

Every service binds to localhost on the VM. Azure Network Security Group rules deny inbound internet traffic, and a Network Address Translation (NAT) gateway handles outbound traffic.

## Model serving

The interactive launcher filters the pinned catalog by the selected VM size.
NC80 includes all NC40-compatible choices plus larger two-GPU checkpoints.
Catalog profiles define tensor parallelism, context, cache type, concurrency,
parsers, and optional speculative decoding for each model/SKU combination.
Checkpoints are stored on a persistent data disk, and the serving container
runs without Hugging Face network access after download.

LiteLLM publishes the model as `local-llm`. Clients can use the OpenAI chat completions interface without knowing the internal vLLM service address.

## Azure infrastructure

[`infra/provision-spot-vm.sh`](h100-spot-llm-lab/infra/provision-spot-vm.sh) creates the compute environment. It provisions the VM, data disk, virtual network, Network Security Group, NAT gateway, and managed identities. `RESOURCE_GROUP` is the single resource-group input shared by compute and monitoring, so deleting that group removes the complete lab.

The VM uses Azure Spot capacity by default. For new VMs, the provisioner offers the one-GPU NC40 and two-GPU NC80 sizes; `VM_SIZE` provides the same choice for non-interactive runs. [`infra/spot-regions.sh`](h100-spot-llm-lab/infra/spot-regions.sh) compares eviction rates, prices, and placement scores before deployment and accepts `SKU` to select the size to inspect. You can remove the Spot flags when you need regular capacity and have the required quota.

The scripts support zonal and regional placement. Regional placement gives the Azure allocator more options when H100 capacity is scarce.

## Monitoring and telemetry

[`infra/provision-monitoring.sh`](h100-spot-llm-lab/infra/provision-monitoring.sh) creates the Azure monitoring destination. It uses [`infra/monitoring-otlp.json`](h100-spot-llm-lab/infra/monitoring-otlp.json) to deploy:

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

[`observability/otelcol/config.yaml`](h100-spot-llm-lab/observability/otelcol/config.yaml) defines one pipeline for each OpenTelemetry signal:

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

[`observability/grafana/h100-llm.json`](h100-spot-llm-lab/observability/grafana/h100-llm.json) is ready to import into Grafana. [`observability/grafana/build_dashboard.py`](h100-spot-llm-lab/observability/grafana/build_dashboard.py) generates the JSON source.

![Grafana dashboard showing H100 model throughput, token rates, cache use, and concurrent requests](h100-spot-llm-lab/observability/grafana/h100-llm-dashboard.png)

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

Install the Azure Command-Line Interface (CLI), Python 3, and `jq`, then authenticate with `az login`. You also need 40 low-priority virtual CPUs of Spot quota in your selected region.

Run the interactive launcher:

```bash
cd h100-spot-llm-lab
cp .env.example .env
scripts/launch.sh
```

The launcher guides you through the VM size, Azure region, resource group, model, monitoring, and ngrok options. It provisions or reuses the VM, deploys the selected model, waits for the services to become healthy, and runs the smoke test. The first deployment downloads the model and can take about 20 minutes.

To enable ngrok, set both `NGROK_AUTHTOKEN` and `NGROK_URL` in `.env` before running the launcher. Leave both values empty to keep the gateway private.

Read the [complete deployment guide](h100-spot-llm-lab/README.md) for region selection, monitoring options, dashboard import, troubleshooting, and cleanup.

## Operate and benchmark the stack

The repository includes scripts for common operations:

| Script | Purpose |
|---|---|
| `scripts/launch.sh` | Interactively provision or reuse a VM and deploy the complete demo |
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
h100-spot-llm-lab/
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
