#!/usr/bin/env bash
set -euo pipefail

timeout="${1:-300}"
[[ "$timeout" =~ ^[0-9]+$ ]] ||
  { echo "ERROR: Node startup timeout must be a non-negative number of seconds." >&2; exit 2; }
deadline=$((SECONDS + timeout))
echo "==> Waiting up to ${timeout}s for K3s node registration and readiness"
while :; do
  if nodes="$(kubectl get nodes -o name --request-timeout=10s)" && [ -n "$nodes" ]; then
    break
  fi
  remaining=$((deadline - SECONDS))
  if [ "$remaining" -le 0 ]; then
    echo "ERROR: No Kubernetes node registered within ${timeout}s; check the K3s service and journal." >&2
    exit 1
  fi
  echo "K3s node not registered yet; retrying."
  if [ "$remaining" -gt 2 ]; then sleep 2; else sleep "$remaining"; fi
done
remaining=$((deadline - SECONDS))
if [ "$remaining" -le 0 ]; then
  echo "ERROR: Node registered, but the ${timeout}s startup deadline expired before readiness." >&2
  exit 1
fi
kubectl wait --for=condition=Ready nodes --all --timeout="${remaining}s"
