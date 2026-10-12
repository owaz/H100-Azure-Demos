#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

SUPPORTED_VM_SIZES = {
    "Standard_NC40ads_H100_v5": 1,
    "Standard_NC80adis_H100_v5": 2,
}
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]*$")
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class CatalogError(ValueError):
    pass


def default_catalog_path() -> Path:
    return Path(__file__).resolve().parents[1] / "config" / "models.json"


def load_catalog(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as handle:
            catalog = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise CatalogError(f"cannot read model catalog {path}: {exc}") from exc
    validate_catalog(catalog)
    return catalog


def validate_catalog(catalog: dict) -> None:
    if catalog.get("schema_version") != 1:
        raise CatalogError("model catalog schema_version must be 1")
    models = catalog.get("models")
    if not isinstance(models, list) or not models:
        raise CatalogError("model catalog must contain a non-empty models array")

    seen = set()
    for model in models:
        model_id = model.get("id")
        if not isinstance(model_id, str) or not ID_PATTERN.fullmatch(model_id):
            raise CatalogError(f"invalid model id: {model_id!r}")
        if model_id in seen:
            raise CatalogError(f"duplicate model id: {model_id}")
        seen.add(model_id)
        for key in ("display_name", "description", "repo", "model_dir", "license"):
            if not isinstance(model.get(key), str) or not model[key]:
                raise CatalogError(f"{model_id}: {key} must be a non-empty string")
        if model.get("access") != "ungated":
            raise CatalogError(f"{model_id}: only ungated models are allowed")
        if not REVISION_PATTERN.fullmatch(str(model.get("revision", ""))):
            raise CatalogError(f"{model_id}: revision must be a pinned 40-character commit")
        if not isinstance(model.get("download_size_gb"), (int, float)) or model["download_size_gb"] <= 0:
            raise CatalogError(f"{model_id}: download_size_gb must be positive")
        patterns = model.get("download_patterns")
        if not isinstance(patterns, list) or not patterns or not all(isinstance(item, str) and item for item in patterns):
            raise CatalogError(f"{model_id}: download_patterns must be a non-empty string array")
        capabilities = model.get("capabilities")
        if not isinstance(capabilities, dict) or not all(
            isinstance(capabilities.get(key), bool) for key in ("reasoning", "tools")
        ):
            raise CatalogError(f"{model_id}: reasoning and tools capabilities must be booleans")
        smoke = model.get("smoke")
        if not isinstance(smoke, dict) or not isinstance(smoke.get("chat_template_kwargs"), dict):
            raise CatalogError(f"{model_id}: smoke.chat_template_kwargs must be an object")
        profiles = model.get("vm_profiles")
        if not isinstance(profiles, dict) or not profiles:
            raise CatalogError(f"{model_id}: vm_profiles must be non-empty")
        for vm_size, profile in profiles.items():
            validate_profile(model_id, vm_size, profile)


def validate_profile(model_id: str, vm_size: str, profile: dict) -> None:
    if vm_size not in SUPPORTED_VM_SIZES:
        raise CatalogError(f"{model_id}: unsupported VM profile {vm_size}")
    if not isinstance(profile, dict):
        raise CatalogError(f"{model_id}/{vm_size}: profile must be an object")
    if profile.get("status") not in ("candidate", "validated"):
        raise CatalogError(f"{model_id}/{vm_size}: status must be candidate or validated")
    tp_size = profile.get("tensor_parallel_size")
    if tp_size not in range(1, SUPPORTED_VM_SIZES[vm_size] + 1):
        raise CatalogError(f"{model_id}/{vm_size}: invalid tensor_parallel_size {tp_size}")
    positive_ints = ("max_model_len", "max_num_seqs", "max_num_batched_tokens")
    for key in positive_ints:
        if not isinstance(profile.get(key), int) or profile[key] <= 0:
            raise CatalogError(f"{model_id}/{vm_size}: {key} must be a positive integer")
    utilization = profile.get("gpu_memory_utilization")
    if not isinstance(utilization, (int, float)) or not 0 < utilization < 1:
        raise CatalogError(f"{model_id}/{vm_size}: gpu_memory_utilization must be between 0 and 1")
    if profile.get("kv_cache_dtype") not in ("auto", "fp8"):
        raise CatalogError(f"{model_id}/{vm_size}: unsupported kv_cache_dtype")
    args = profile.get("vllm_args")
    if not isinstance(args, list) or not all(isinstance(item, str) and item for item in args):
        raise CatalogError(f"{model_id}/{vm_size}: vllm_args must be a string array")
    managed_args = {
        "--model",
        "--served-model-name",
        "--host",
        "--port",
        "--max-model-len",
        "--gpu-memory-utilization",
        "--tensor-parallel-size",
        "--max-num-seqs",
        "--max-num-batched-tokens",
        "--kv-cache-dtype",
    }
    conflicts = managed_args.intersection(args)
    if conflicts:
        raise CatalogError(
            f"{model_id}/{vm_size}: vllm_args overrides managed flags: {', '.join(sorted(conflicts))}"
        )


def find_model(catalog: dict, model_id: str) -> dict:
    for model in catalog["models"]:
        if model["id"] == model_id:
            return model
    raise CatalogError(f"unknown model id: {model_id}")


def resolve_profile(catalog: dict, model_id: str, vm_size: str) -> dict:
    if vm_size not in SUPPORTED_VM_SIZES:
        raise CatalogError(f"unsupported VM size: {vm_size}")
    model = find_model(catalog, model_id)
    profile = model["vm_profiles"].get(vm_size)
    if profile is None:
        raise CatalogError(f"{model_id} is not compatible with {vm_size}")
    return {"model": model, "vm_size": vm_size, "profile": profile}


def list_models(catalog: dict, vm_size: str) -> list:
    if vm_size not in SUPPORTED_VM_SIZES:
        raise CatalogError(f"unsupported VM size: {vm_size}")
    rows = []
    for model in catalog["models"]:
        profile = model["vm_profiles"].get(vm_size)
        if profile:
            rows.append(
                {
                    "id": model["id"],
                    "display_name": model["display_name"],
                    "status": profile["status"],
                    "download_size_gb": model["download_size_gb"],
                    "description": model["description"],
                }
            )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and resolve model catalog profiles")
    parser.add_argument("--catalog", type=Path, default=default_catalog_path())
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("vm_size")
    list_parser.add_argument("--tsv", action="store_true")
    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("model_id")
    resolve_parser.add_argument("vm_size")

    args = parser.parse_args()
    try:
        catalog = load_catalog(args.catalog)
        if args.command == "validate":
            print(f"valid: {len(catalog['models'])} models")
        elif args.command == "list":
            rows = list_models(catalog, args.vm_size)
            if args.tsv:
                for row in rows:
                    print(
                        "\t".join(
                            str(row[key])
                            for key in ("id", "display_name", "status", "download_size_gb", "description")
                        )
                    )
            else:
                json.dump(rows, sys.stdout, indent=2)
                print()
        elif args.command == "resolve":
            json.dump(resolve_profile(catalog, args.model_id, args.vm_size), sys.stdout, indent=2)
            print()
    except CatalogError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
