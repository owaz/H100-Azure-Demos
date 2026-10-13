#!/usr/bin/env python3
import json
import os
import subprocess
from pathlib import Path

from model_profile import CatalogError, find_model, load_catalog


def build_command(model: dict) -> list:
    destination = Path("/models") / model["model_dir"]
    command = [
        "hf",
        "download",
        model["repo"],
        "--revision",
        model["revision"],
        "--local-dir",
        str(destination),
    ]
    for pattern in model["download_patterns"]:
        command.extend(["--include", pattern])
    return command


def main() -> int:
    catalog_path = Path(os.environ.get("MODEL_CATALOG", "/app/config/models.json"))
    model_id = os.environ.get("MODEL_ID", "")
    if not model_id:
        raise CatalogError("MODEL_ID is required")
    model = find_model(load_catalog(catalog_path), model_id)
    command = build_command(model)
    if os.environ.get("MODEL_COMMAND_ONLY") == "1":
        print(json.dumps(command))
        return 0
    destination = Path("/models") / model["model_dir"]
    print(f"Downloading {model['repo']}@{model['revision']} to {destination}", flush=True)
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
