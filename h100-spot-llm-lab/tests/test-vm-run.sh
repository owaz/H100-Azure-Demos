#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "${tmp_dir}/az" <<'EOF'
#!/usr/bin/env bash
script_path=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --scripts ]; then
    script_path="${2#@}"
    break
  fi
  shift
done
[ -n "$script_path" ] || exit 2
set +e
output="$(bash "$script_path" 2>&1)"
printf 'Enable succeeded:\n[stdout]\n%s\n[stderr]\n' "$output"
exit 0
EOF
chmod +x "${tmp_dir}/az"

export PATH="${tmp_dir}:${PATH}"
export SUBSCRIPTION="sub-test"
export RESOURCE_GROUP="rg-test"
export VM_NAME="vm-test"

success_output="$(scripts/vm-run.sh -c 'echo remote-ok')"
printf '%s\n' "$success_output" | grep -Fq remote-ok
if printf '%s\n' "$success_output" | grep -Fq __VM_RUN_EXIT_CODE__; then
  echo "vm-run leaked its exit-status sentinel" >&2
  exit 1
fi

failure_output="${tmp_dir}/failure-output"
set +e
scripts/vm-run.sh -c 'echo remote-fail >&2; exit 23' >"$failure_output" 2>&1
status=$?
set -e
[ "$status" = 23 ] || {
  echo "vm-run returned ${status}, expected remote status 23" >&2
  exit 1
}
grep -Fq remote-fail "$failure_output"

cat > "${tmp_dir}/remote-script.sh" <<'EOF'
#!/usr/bin/env bash
echo file-script-fail >&2
exit 17
EOF
set +e
scripts/vm-run.sh "${tmp_dir}/remote-script.sh" >"$failure_output" 2>&1
status=$?
set -e
[ "$status" = 17 ] || {
  echo "vm-run returned ${status}, expected file script status 17" >&2
  exit 1
}
grep -Fq file-script-fail "$failure_output"

echo "vm-run tests: PASS"
