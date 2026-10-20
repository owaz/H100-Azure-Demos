#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
: "${EXPECTED_GPUS:?Set EXPECTED_GPUS to 1 or 2}"
case "$EXPECTED_GPUS" in 1|2) ;; *) echo "ERROR: EXPECTED_GPUS must be 1 or 2." >&2; exit 2 ;; esac
LAB_DIR=/opt/arc-gpu-k8s-lab
diagnostics() {
  rc=$?
  if [ "$rc" != 0 ]; then
    echo "ERROR: GPU validation failed (exit $rc)."
    kubectl get pods -A -o wide || true
    kubectl describe pod gpu-smoke -n gpu-lab || true
    kubectl logs -n gpu-lab gpu-smoke || true
    kubectl get events -A --sort-by=.lastTimestamp | tail -n 25 || true
  fi
  exit "$rc"
}
trap diagnostics EXIT
bash "$(dirname "${BASH_SOURCE[0]}")/wait-for-node.sh"
deadline=$((SECONDS + 1800))
while :; do
  nodes="$(kubectl get nodes -o json)"
  if jq -e --argjson expected "$EXPECTED_GPUS" '
    (.items | length) == 1 and
    .items[0].status.allocatable["nvidia.com/gpu"] == ($expected | tostring)
  ' <<< "$nodes" >/dev/null; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: Expected exactly $EXPECTED_GPUS allocatable NVIDIA GPUs on one node." >&2
    exit 1
  fi
  sleep 15
done
kubectl wait --for=jsonpath='{.status.state}'=ready clusterpolicy/cluster-policy --timeout=300s
kubectl create namespace gpu-lab --dry-run=client -o yaml | kubectl apply -f -
kubectl delete pod gpu-smoke -n gpu-lab --ignore-not-found --wait=true --timeout=120s
kubectl apply -f "$LAB_DIR/manifests/gpu-smoke.yaml"
kubectl wait -n gpu-lab --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=300s
kubectl logs -n gpu-lab gpu-smoke
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
echo "PASS: $EXPECTED_GPUS allocatable GPU(s), ready ClusterPolicy, and a GPU-limited CUDA pod completed."
