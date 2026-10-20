# Copilot instructions

## Kubernetes lab isolation

- Keep all Kubernetes/Arc GPU experiment code, configuration, tests, and documentation under [`arc-gpu-k8s-lab/`](../arc-gpu-k8s-lab/).
- Treat [`h100-spot-llm-lab/`](../h100-spot-llm-lab/) as the existing Spot VM lab, not the home for Kubernetes work. Do not edit its code, configuration, tests, or documentation for Kubernetes experiments.
- The existing Spot VM lab may be read as a reference for VM capabilities and current NVIDIA host setup. Do not change or provision that VM as part of Kubernetes work unless the user explicitly asks.
- If a Kubernetes task appears to require changes outside `arc-gpu-k8s-lab/`, stop and ask the user before making them.
