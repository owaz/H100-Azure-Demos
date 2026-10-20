import base64
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


LAB = Path(__file__).resolve().parents[1]
PROJECT = "arc-gpu-k8s-lab"

AZ_MOCK = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
def emit(value):
    print(json.dumps(value))
if os.environ.get("MOCK_AZ_FAIL") == "1" or os.environ.get("MOCK_AZ_FAIL_AT") == " ".join(args[:2]):
    print("Azure request failed", file=sys.stderr)
    sys.exit(7)
if args[:2] == ["account", "show"] and "--query" in args:
    print("test-subscription")
elif args[:2] == ["group", "exists"]:
    print(os.environ.get("MOCK_GROUP_EXISTS", "true"))
elif args[:2] == ["group", "show"]:
    emit({"tags": {"project": os.environ.get("MOCK_GROUP_OWNER", "arc-gpu-k8s-lab")}})
elif args[:2] == ["vm", "list"]:
    emit([] if os.environ.get("MOCK_NEW") == "1" else [{"name": os.environ.get("MOCK_OTHER_VM", "vm-arc-gpu-h100")}])
elif args[:2] == ["vm", "show"]:
    if "--query" in args:
        print("southeastasia")
    else:
        emit({"tags": {"project": os.environ.get("MOCK_VM_OWNER", "arc-gpu-k8s-lab")},
              "priority": os.environ.get("MOCK_PRIORITY", "Spot"),
              "hardwareProfile": {"vmSize": os.environ.get("VM_SIZE", "Standard_NC40ads_H100_v5")}})
elif args[:3] == ["vm", "run-command", "invoke"]:
    marker = os.environ.get("MOCK_MARKER", "ARC_GPU_EXIT=0")
    emit({"value": [{"message": "[stdout]\n" + marker + "\n[stderr]\n"}]})
"""

KUBECTL_MOCK = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
state = os.environ.get("MOCK_NODE_STATE")
if args[:2] == ["get", "nodes"] and "-o" in args and args[args.index("-o") + 1] == "name":
    polls = int(open(state).read()) if state and os.path.exists(state) else 0
    if state:
        with open(state, "w") as f:
            f.write(str(polls + 1))
    if polls >= int(os.environ.get("MOCK_EMPTY_NODE_POLLS", "0")):
        print("node/vm-arc-gpu-h100")
    elif os.environ.get("MOCK_API_UNAVAILABLE") == "1":
        print("Unable to connect to the server: connection refused", file=sys.stderr)
        sys.exit(1)
elif args[:1] == ["wait"] and "nodes" in args:
    polls = int(open(state).read()) if state and os.path.exists(state) else 0
    if polls < int(os.environ.get("MOCK_EMPTY_NODE_POLLS", "0")):
        print("error: no matching resources found", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("MOCK_NODE_NOT_READY") == "1":
        print("error: timed out waiting for the condition on nodes", file=sys.stderr)
        sys.exit(1)
elif args[:2] == ["get", "nodes"] and "-o" in args and args[args.index("-o") + 1] == "json":
    print(json.dumps({"items": [{"status": {"allocatable": {"nvidia.com/gpu": os.environ.get("EXPECTED_GPUS", "1")}}}]}))
elif args[:1] == ["wait"] and "pod/gpu-smoke" in args and os.environ.get("MOCK_POD_FAIL") == "1":
    print("Pod never succeeded", file=sys.stderr)
    sys.exit(1)
elif args[:1] == ["logs"]:
    print("CUDA vector addition: Test PASSED")
elif args[:2] == ["create", "namespace"]:
    print("apiVersion: v1\nkind: Namespace\nmetadata:\n  name: gpu-lab")
elif args[:1] == ["apply"] and args[-1] == "-":
    sys.stdin.read()
"""


class LabTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "calls.jsonl"
        for name, script in (("az", AZ_MOCK), ("kubectl", KUBECTL_MOCK)):
            target = self.root / name
            target.write_text(script)
            target.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.root}:{os.environ['PATH']}",
            "MOCK_LOG": str(self.log),
            "RESOURCE_GROUP": "rg-arc-gpu-test",
            "LOCATION": "southeastasia",
            "VM_NAME": "vm-arc-gpu-h100",
            "VM_SIZE": "Standard_NC40ads_H100_v5",
            "ZONE": "none",
            "SUBSCRIPTION": "test-subscription",
        }

    def run_bootstrap_readiness(self, **env):
        script = (LAB / "scripts/bootstrap.sh").read_text()
        readiness = script.split('INSTALL_K3S_VERSION="$K3S_VERSION" sh "$work/k3s-install.sh"\n', 1)[1]
        readiness = readiness.split('\necho "==> Installing checksum-verified Helm"', 1)[0]
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", readiness],
            env={**self.env, "LAB_DIR": str(LAB), **env},
            text=True, capture_output=True, timeout=20,
        )

    def test_bootstrap_waits_for_node_registration_before_readiness(self):
        result = self.run_bootstrap_readiness(
            MOCK_NODE_STATE=str(self.root / "node-polls"),
            MOCK_EMPTY_NODE_POLLS="2",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("no matching resources found", result.stderr)
        calls = self.calls()
        ready = next(i for i, c in enumerate(calls) if c[:1] == ["wait"])
        self.assertEqual(sum(c[:2] == ["get", "nodes"] for c in calls[:ready]), 3)

    def test_bootstrap_retries_api_startup_errors(self):
        result = self.run_bootstrap_readiness(
            MOCK_NODE_STATE=str(self.root / "node-polls"),
            MOCK_EMPTY_NODE_POLLS="1",
            MOCK_API_UNAVAILABLE="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("connection refused", result.stderr)

    def test_registered_but_unready_node_still_fails_bootstrap(self):
        result = self.run_bootstrap_readiness(MOCK_NODE_NOT_READY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out waiting", result.stderr)
        self.assertFalse(any(c[:2] == ["get", "runtimeclass"] for c in self.calls()))

    def test_node_registration_timeout_fails_explicitly(self):
        result = subprocess.run(
            ["bash", str(LAB / "scripts/wait-for-node.sh"), "0"],
            env={**self.env, "MOCK_EMPTY_NODE_POLLS": "100"},
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No Kubernetes node registered within 0s", result.stderr)
        self.assertFalse(any(c[:1] == ["wait"] for c in self.calls()))

    def run_deploy(self, action="up", **env):
        return subprocess.run(
            ["bash", str(LAB / "deploy.sh"), action],
            env={**self.env, **env},
            text=True,
            capture_output=True,
            timeout=30,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_new_vm_is_private_spot_and_independently_tagged(self):
        result = self.run_deploy(MOCK_NEW="1", MOCK_GROUP_EXISTS="false", ZONE="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[:2] == ["vm", "create"])
        for flag, value in (
            ("--priority", "Spot"), ("--eviction-policy", "Deallocate"),
            ("--public-ip-address", ""), ("--enable-secure-boot", "false"),
            ("--zone", "2"), ("--size", "Standard_NC40ads_H100_v5"),
        ):
            self.assertEqual(create[create.index(flag) + 1], value)
        self.assertIn(f"project={PROJECT}", create)
        self.assertEqual(create[create.index("--subscription") + 1], "test-subscription")
        self.assertNotIn("--generate-ssh-keys", create)
        self.assertTrue(any(c[:3] == ["network", "nat", "gateway"] for c in self.calls()))
        request = next(c for c in self.calls() if c[:3] == ["vm", "run-command", "invoke"])
        script = request[request.index("--scripts") + 1]
        encoded = re.search(r"printf '%s' '([^']+)' \| base64", script).group(1)
        with tarfile.open(fileobj=io.BytesIO(base64.b64decode(encoded))) as archive:
            self.assertIn("scripts/bootstrap.sh", archive.getnames())
            self.assertIn("scripts/wait-for-node.sh", archive.getnames())
            self.assertIn("manifests/gpu-smoke.yaml", archive.getnames())
            for member in archive.getmembers():
                self.assertFalse(Path(member.name).name.startswith("._"))
                self.assertFalse(any(
                    key.startswith(("LIBARCHIVE.xattr.", "SCHILY.xattr."))
                    for key in member.pax_headers
                ))
        self.assertIn("K3S_VERSION=v1.35.9+k3s1", script)
        self.assertIn("EXPECTED_GPUS=1", script)
        self.assertIn('exit "$rc"', script)
        safe_failure = script.replace("install -d -m 700 /opt/arc-gpu-k8s-lab", "false", 1)
        self.assertNotEqual(safe_failure, script)
        failed_guest = subprocess.run(
            ["sh", "-c", safe_failure], capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(failed_guest.returncode, 1)
        self.assertIn("ARC_GPU_EXIT=1", failed_guest.stdout)

    def test_regional_placement_omits_zone(self):
        result = self.run_deploy(MOCK_NEW="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[:2] == ["vm", "create"])
        self.assertNotIn("--zone", create)

    def test_foreign_resource_group_is_not_adopted(self):
        result = self.run_deploy(MOCK_GROUP_OWNER="llm-self-hosting")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to use resource group", result.stderr)
        self.assertFalse(any(c[:1] == ["vm"] for c in self.calls()))

    def test_foreign_vm_is_not_started_or_bootstrapped(self):
        result = self.run_deploy(MOCK_VM_OWNER="llm-self-hosting")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to use VM", result.stderr)
        self.assertFalse(any(c[:2] == ["vm", "start"] for c in self.calls()))
        self.assertFalse(any(c[:2] == ["vm", "run-command"] for c in self.calls()))

    def test_other_vm_in_group_prevents_new_vm(self):
        result = self.run_deploy(MOCK_OTHER_VM="some-other-vm")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already contains another VM", result.stderr)

    def test_azure_failure_is_not_treated_as_missing_resources(self):
        result = self.run_deploy(MOCK_AZ_FAIL="1")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(len(self.calls()), 1)

    def test_failed_group_existence_check_does_not_create_resources(self):
        result = self.run_deploy(MOCK_AZ_FAIL_AT="group exists")
        self.assertEqual(result.returncode, 7)
        self.assertFalse(any(c[:2] == ["group", "create"] for c in self.calls()))
        self.assertFalse(any(c[:1] == ["network"] for c in self.calls()))

    def test_guest_failures_and_missing_marker_fail_deploy(self):
        for marker in ("ARC_GPU_EXIT=42", "no completion marker"):
            with self.subTest(marker=marker):
                result = self.run_deploy(MOCK_MARKER=marker)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("completed successfully", result.stdout)

    def test_unsupported_size_and_invalid_location_fail_before_azure(self):
        for config in ({"VM_SIZE": "Standard_D4s_v5"}, {"LOCATION": "bad;echo unsafe"}):
            with self.subTest(config=config):
                result = self.run_deploy(**config)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_verify_transports_two_gpu_expectation_without_starting_vm(self):
        result = self.run_deploy("verify", VM_SIZE="Standard_NC80adis_H100_v5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[:2] == ["vm", "start"] for c in self.calls()))
        request = next(c for c in self.calls() if c[:2] == ["vm", "run-command"])
        script = request[request.index("--scripts") + 1]
        self.assertIn("EXPECTED_GPUS=2", script)
        self.assertIn("bash /opt/arc-gpu-k8s-lab/scripts/verify.sh", script)
        self.assertNotIn("bash /opt/arc-gpu-k8s-lab/scripts/bootstrap.sh", script)

    def test_stop_deallocates_only_owned_vm(self):
        result = self.run_deploy("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[:2] == ["vm", "deallocate"] for c in self.calls()))
        self.assertFalse(any(c[:2] == ["vm", "run-command"] for c in self.calls()))

    def test_gpu_verification_checks_pod_completion_and_exposes_failure(self):
        for fail in ("0", "1"):
            with self.subTest(fail=fail):
                result = subprocess.run(
                    ["bash", str(LAB / "scripts/verify.sh")],
                    env={**self.env, "EXPECTED_GPUS": "2", "MOCK_POD_FAIL": fail},
                    text=True, capture_output=True, timeout=30,
                )
                self.assertEqual(result.returncode == 0, fail == "0", result.stderr)
                if fail == "1":
                    self.assertIn("GPU validation failed", result.stdout)
                else:
                    self.assertIn("2 allocatable GPU(s)", result.stdout)
                    self.assertTrue(any(
                        c[:1] == ["wait"] and
                        "--for=jsonpath={.status.phase}=Succeeded" in c
                        for c in self.calls()
                    ))

    def test_actual_gpu_count_filter_rejects_missing_wrong_or_multiple_nodes(self):
        script = (LAB / "scripts/verify.sh").read_text()
        query = re.search(
            r"""jq -e --argjson expected "\$EXPECTED_GPUS" '(.+?)'""",
            script, re.DOTALL,
        ).group(1)
        for counts, expected, succeeds in (
            (["1"], 1, True), (["2"], 2, True), (["1"], 2, False),
            (["2"], 1, False), ([None], 1, False), ([], 1, False),
            (["1", "1"], 1, False),
        ):
            with self.subTest(counts=counts, expected=expected):
                nodes = {"items": [
                    {"status": {"allocatable": {} if count is None else {"nvidia.com/gpu": count}}}
                    for count in counts
                ]}
                result = subprocess.run(
                    ["jq", "-e", "--argjson", "expected", str(expected), query],
                    input=json.dumps(nodes), text=True, capture_output=True,
                )
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)


if __name__ == "__main__":
    unittest.main()
