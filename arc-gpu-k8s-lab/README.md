# Azure Arc GPU Kubernetes lab

This folder provisions a **new**, private Azure H100 Spot VM with single-node K3s and the NVIDIA GPU Operator. All Kubernetes experiment code, configuration, tests, and documentation stays here.

## Scope

- This is an experimental self-managed Kubernetes lab, not the AKS enabled by Azure Arc product.
- The existing H100 Spot VM lab at [`../h100-spot-llm-lab/`](../h100-spot-llm-lab/) is reference-only. Its code and documentation are not to be changed for Kubernetes experiments.
- The feasibility assessment is in [`arc-gpu-feasibility.md`](arc-gpu-feasibility.md).

## Important limitations

- **This is not AKS.** You own Kubernetes installation, upgrades, backups, and recovery. Azure Arc attachment is not automated yet; this deployment establishes and tests the GPU cluster first.
- **Spot is interruptible.** An eviction takes down both Kubernetes's control plane and its GPU workloads. There is no HA or capacity guarantee. Managed OS disk state survives deallocation, but restart depends on available capacity.
- **No production support claim.** The exact Azure SKU, Ubuntu kernel, K3s, and Operator combination needs live validation. Local tests validate orchestration and manifests, not GPU hardware.
- **This creates billable resources.** `--max-price -1` permits the prevailing Spot price up to the regular VM price; it is not a dollar budget cap. Deallocation stops VM compute charges, but the managed disk, NAT gateway, and egress public IP continue to cost money.
- **GPU Operator is privileged.** It installs the NVIDIA driver and deploys privileged node components. Secure Boot is disabled for its kernel modules; vTPM remains enabled.

## Layout and ownership

| File | Purpose |
|---|---|
| [`deploy.sh`](deploy.sh) | New VM/network provisioning, ownership guards, payload upload, guest result checking |
| [`scripts/bootstrap.sh`](scripts/bootstrap.sh) | Host prerequisites, K3s, NVIDIA runtime, Helm, GPU Operator |
| [`scripts/verify.sh`](scripts/verify.sh) | Exact GPU count, ready Operator policy, CUDA workload completion |
| [`manifests/gpu-operator-values.yaml`](manifests/gpu-operator-values.yaml) | Operator ownership and lab-specific settings |
| [`manifests/gpu-smoke.yaml`](manifests/gpu-smoke.yaml) | GPU-limited CUDA vector-add workload |
| [`tests/test_deploy.py`](tests/test_deploy.py) | Offline Azure CLI and Kubernetes orchestration tests |

The bootstrap installs NVIDIA Container Toolkit **1.20.1-1** on the host before K3s so K3s can discover `nvidia-container-runtime` and persist the runtime in its own containerd configuration. Its driver root is `/run/nvidia/driver`, the Operator's driver mount. The Operator manages the **driver**, device plugin, node feature discovery, validation, and DCGM exporter. Its toolkit management is disabled to avoid two owners rewriting K3s's generated runtime configuration.

K3s uses `nvidia` as its default runtime; the smoke pod also explicitly selects `runtimeClassName: nvidia`. This lab uses the legacy NVIDIA runtime path rather than CDI, exposes whole GPUs, and disables MIG management, confidential-computing mode management, VM/vGPU passthrough managers, and automatic driver upgrades. Do not install an additional NVIDIA device plugin or another host driver.

Pinned versions:

- K3s **v1.35.9+k3s1**
- GPU Operator **v26.7.2**, including its chart-default driver version
- Helm **v3.20.0**, verified against a checked-in SHA-256
- Ubuntu **24.04 LTS**, Azure marketplace `server:latest` image
- CUDA vector-add smoke image pinned by digest

The Ubuntu image, kernel, and package dependencies are not immutable pins. Kernel/driver compatibility and repository availability still need verification at deployment time. The K3s installer downloads and verifies its pinned release binary, but the installer script itself is fetched from the upstream installation endpoint.

## Prerequisites

- Local Bash, Azure CLI (`az login` with the correct subscription selected), `jq`, `tar`, `base64`, and `ssh-keygen`.
- Permission to create a dedicated resource group, networking resources, and VMs, and to invoke VM Run Command.
- Regional Spot vCPU quota sufficient for **40 vCPUs** (NC40, one H100 NVL) or **80 vCPUs** (NC80, two H100 NVLs), plus SKU availability and any subscription-specific GPU restrictions.
- Outbound access to Azure management/VM-agent services, Ubuntu repositories, K3s/GitHub releases, Helm downloads, NVIDIA package/chart registries, and Kubernetes container registries.
- A new resource group name, or an existing dedicated group already tagged `project=arc-gpu-k8s-lab`. Untagged/foreign groups and VMs are deliberately rejected; do not retag the existing Spot VM lab to bypass these guards.

The Azure subscription is resolved once at command startup and passed explicitly to subsequent Azure commands. Set `SUBSCRIPTION=<id>` to override the currently selected subscription.

## Deploy

Run from the repository root:

```bash
export RESOURCE_GROUP=rg-arc-gpu-k8s-lab
export LOCATION=southeastasia
export VM_SIZE=Standard_NC40ads_H100_v5
# Optional: export ZONE=2   # default: regional placement

bash arc-gpu-k8s-lab/deploy.sh up
```

For two H100s, use `VM_SIZE=Standard_NC80adis_H100_v5`. The default VM name is `vm-arc-gpu-h100`; override with `VM_NAME` if needed. Keep the same environment variables for later commands.

The deployment:

1. Creates a tagged, dedicated resource group if absent.
2. Creates its own VNet (`10.70.0.0/16`), subnet, NSG, NAT gateway, and outbound-only public IP.
3. Creates a Spot VM with **no VM public IP**, no internet ingress, a 256 GiB Premium managed OS disk, and eviction policy **Deallocate**. The OS disk stores cluster state and container images; ephemeral local storage is not used.
4. Uploads only this lab's guest scripts and manifests through Azure Run Command. No workstation kubeconfig or Azure credentials are copied to the VM. An ephemeral SSH key is created for Azure's VM provisioning requirement and discarded locally; administration uses Run Command.
5. Installs K3s (without Traefik or ServiceLB) and GPU Operator, then waits for the expected GPU resource count and a ready ClusterPolicy.
6. Runs a GPU-limited CUDA vector-add pod and requires it to reach `Succeeded`. Azure extension success without a guest completion marker is treated as failure.

Allow roughly 20-40 minutes for initial image downloads and driver compilation, potentially longer on a cold host. Errors leave resources intact for inspection; there is no automatic deletion or fallback to another region, VM, or regular-priced capacity. Fix the reported cause and rerun `up` against the same owned VM. A second VM is not silently created.

Only the exact named, lab-tagged VM can be reused. The script never discovers the existing LLM VM, calls its provisioner, or copies its application files. Existing Kubernetes or Docker/LLM installations on an unowned guest are rejected by bootstrap.

## Verify, inspect, and stop

```bash
bash arc-gpu-k8s-lab/deploy.sh verify
bash arc-gpu-k8s-lab/deploy.sh status
bash arc-gpu-k8s-lab/deploy.sh stop
```

`verify` reruns the CUDA pod, checks exactly one node with one or two allocatable `nvidia.com/gpu` resources, and prints logs. It does not start a stopped VM. `up` starts and reconciles this lab's existing VM; it does not perform an automatic Kubernetes/driver upgrade workflow.

For guest inspection:

```bash
az vm run-command invoke -g "$RESOURCE_GROUP" -n "${VM_NAME:-vm-arc-gpu-h100}" \
  --command-id RunShellScript \
  --scripts 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl get nodes,pods -A -o wide; kubectl get clusterpolicy; tail -n 80 /var/log/arc-gpu-k8s-lab.log' \
  --query 'value[].message' -o tsv
```

The admin kubeconfig is root-readable only and stays on the VM. There is no workstation API access path or exposed dashboard. If the driver fails, inspect pods in `gpu-operator` and their events/logs; do not hide the failure by installing a second driver.

After a kernel change or reboot, rerun `verify` on the running VM. Periodically check disk space and kernel/driver compatibility; no unattended Kubernetes upgrade or backup mechanism is provided.

### Remove the lab

Review the dedicated group before deleting it:

```bash
az resource list -g "$RESOURCE_GROUP" -o table
az group delete -n "$RESOURCE_GROUP"
```

Deletion removes **all** resources in that group, including cluster state. Do not point these commands at the existing LLM lab. Azure CLI prompts for confirmation.

## Local validation

No cloud subscription or VM is used by these tests:

```bash
bash -n arc-gpu-k8s-lab/deploy.sh arc-gpu-k8s-lab/scripts/*.sh
python3 -m unittest discover -s arc-gpu-k8s-lab/tests -v
helm template gpu-operator gpu-operator \
  --repo https://helm.ngc.nvidia.com/nvidia --version v26.7.2 \
  --namespace gpu-operator \
  --values arc-gpu-k8s-lab/manifests/gpu-operator-values.yaml >/dev/null
```

The tests mock Azure and Kubernetes commands; rendering the chart needs registry access. A successful live `up`/`verify` is still required to establish hardware/runtime compatibility.

## Sources

- [K3s NVIDIA runtime detection and RuntimeClass](https://docs.k3s.io/advanced#nvidia-container-runtime)
- [NVIDIA GPU Operator deployment scenarios, including a pre-installed toolkit without drivers](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html)
- [GPU Operator platform support](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/platform-support.html)
- [GPU Operator values at the pinned release](https://github.com/NVIDIA/gpu-operator/blob/v26.7.2/deployments/gpu-operator/values.yaml)
- [Azure Spot VM eviction and billing considerations](https://learn.microsoft.com/azure/virtual-machines/spot-vms)
- [Azure VM Run Command restrictions](https://learn.microsoft.com/azure/virtual-machines/linux/run-command)
