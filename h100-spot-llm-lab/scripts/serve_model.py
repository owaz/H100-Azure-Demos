#!/usr/bin/env python3
import json
import os
import subprocess
from pathlib import Path

from model_profile import CatalogError, load_catalog, resolve_profile


def build_command(resolved: dict) -> list:
    model = resolved["model"]
    profile = resolved["profile"]
    command = [
        "python3",
        "-m",
        "vllm.entrypoints.openai.api_server",
        "--model",
        f"/models/{model['model_dir']}",
        "--served-model-name",
        model["id"],
        "--host",
        "0.0.0.0",
        "--port",
        "8080",
        "--max-model-len",
        str(profile["max_model_len"]),
        "--gpu-memory-utilization",
        str(profile["gpu_memory_utilization"]),
        "--tensor-parallel-size",
        str(profile["tensor_parallel_size"]),
        "--max-num-seqs",
        str(profile["max_num_seqs"]),
        "--max-num-batched-tokens",
        str(profile["max_num_batched_tokens"]),
        "--kv-cache-dtype",
        profile["kv_cache_dtype"],
        "--enable-prefix-caching",
    ]
    command.extend(profile["vllm_args"])
    return command


def main() -> int:
    catalog_path = Path(os.environ.get("MODEL_CATALOG", "/app/config/models.json"))
    model_id = os.environ.get("MODEL_ID", "")
    vm_size = os.environ.get("MODEL_VM_SIZE", "")
    if not model_id or not vm_size:
        raise CatalogError("MODEL_ID and MODEL_VM_SIZE are required")
    resolved = resolve_profile(load_catalog(catalog_path), model_id, vm_size)
    command = build_command(resolved)
    if os.environ.get("MODEL_COMMAND_ONLY") == "1":
        print(json.dumps(command))
        return 0
    print(
        f"Starting {model_id} on {vm_size} ({resolved['profile']['status']} profile)",
        flush=True,
    )
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
