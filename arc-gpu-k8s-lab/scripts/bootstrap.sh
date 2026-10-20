#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "ERROR: Run as root." >&2; exit 1; }

LAB_DIR=/opt/arc-gpu-k8s-lab
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DEBIAN_FRONTEND=noninteractive
: "${K3S_VERSION:?}" "${GPU_OPERATOR_VERSION:?}" "${HELM_VERSION:?}" "${EXPECTED_GPUS:?}"
if [ -d /opt/llm-self-hosting ] || command -v docker >/dev/null; then
  echo "ERROR: Refusing to bootstrap a host with an existing Docker/LLM lab." >&2
  exit 1
fi
if [ -d /etc/rancher/k3s ] && [ ! -f /etc/arc-gpu-k8s-lab ]; then
  echo "ERROR: Existing Kubernetes installation is not owned by this lab." >&2
  exit 1
fi
if [ ! -f /etc/arc-gpu-k8s-lab ] && command -v nvidia-smi >/dev/null; then
  echo "ERROR: Expected a fresh VM without a pre-installed NVIDIA driver." >&2
  exit 1
fi
. /etc/os-release
[ "$ID:$VERSION_ID" = ubuntu:24.04 ] ||
  { echo "ERROR: This bootstrap expects Ubuntu 24.04." >&2; exit 1; }
exec > >(tee -a /var/log/arc-gpu-k8s-lab.log) 2>&1
touch /etc/arc-gpu-k8s-lab
work=""

diagnostics() {
  rc=$?
  if [ "$rc" != 0 ]; then
    echo "ERROR: Bootstrap failed (exit $rc). Diagnostic output follows."
    if command -v kubectl >/dev/null; then
      kubectl get nodes,pods -A -o wide || true
      kubectl get events -A --sort-by=.lastTimestamp | tail -n 30 || true
    fi
  fi
  if [ -n "${work:-}" ]; then
    rm -f "$work/k3s-install.sh" "$work/helm.tar.gz" "$work/helm.sha256" "$work/helm"
    rmdir "$work"
  fi
  exit "$rc"
}
trap diagnostics EXIT

echo "==> Preparing host and kernel headers"
printf 'DPkg::Lock::Timeout "1200";\n' > /etc/apt/apt.conf.d/99arc-gpu-lock-timeout
apt-get update
apt-get install -y ca-certificates curl gnupg pciutils jq \
  "linux-headers-$(uname -r)" build-essential
lspci -n | grep -i '10de:' >/dev/null ||
  { echo "ERROR: No NVIDIA PCI device found." >&2; exit 1; }
modprobe overlay
modprobe br_netfilter
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/arc-gpu.conf
printf 'net.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-iptables=1\n' > /etc/sysctl.d/90-arc-gpu.conf
sysctl --system
swapoff -a

echo "==> Installing NVIDIA Container Toolkit (driver remains Operator-managed)"
install -d -m 755 /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
  gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit=1.20.1-1 nvidia-container-toolkit-base=1.20.1-1 \
  libnvidia-container-tools=1.20.1-1 libnvidia-container1=1.20.1-1
nvidia-ctk config --in-place --set nvidia-container-cli.root=/run/nvidia/driver \
  --set nvidia-container-runtime.mode=legacy

echo "==> Installing pinned K3s"
install -d -m 700 /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'EOF'
write-kubeconfig-mode: "0600"
default-runtime: nvidia
disable:
  - traefik
  - servicelb
EOF
work="$(mktemp -d)"
curl -fsSL https://get.k3s.io -o "$work/k3s-install.sh"
INSTALL_K3S_VERSION="$K3S_VERSION" sh "$work/k3s-install.sh"
bash "$LAB_DIR/scripts/wait-for-node.sh"
kubectl get runtimeclass nvidia

echo "==> Installing checksum-verified Helm"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "$work/helm.tar.gz"
printf 'dbb4c8fc8e19d159d1a63dda8db655f9ffa4aac1b9a6b188b34a40957119b286  %s\n' \
  "$work/helm.tar.gz" > "$work/helm.sha256"
sha256sum -c "$work/helm.sha256"
tar -xzf "$work/helm.tar.gz" -C "$work" --strip-components=1 linux-amd64/helm
install -m 755 "$work/helm" /usr/local/bin/helm

echo "==> Installing NVIDIA GPU Operator"
helm upgrade --install gpu-operator gpu-operator --repo https://helm.ngc.nvidia.com/nvidia \
  --version "$GPU_OPERATOR_VERSION" --namespace gpu-operator --create-namespace \
  --values "$LAB_DIR/manifests/gpu-operator-values.yaml" --wait --timeout 30m
bash "$LAB_DIR/scripts/verify.sh"
echo "==> Bootstrap and GPU workload validation passed"
