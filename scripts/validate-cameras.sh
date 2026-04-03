#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-post-patch}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/results/${LABEL}/${STAMP}"
mkdir -p "${OUT_DIR}"

run_shell() {
	local name="$1"
	local cmd="$2"
	local stdout_file="${OUT_DIR}/${name}.stdout"
	local stderr_file="${OUT_DIR}/${name}.stderr"
	local rc=0

	printf '==> %s\n' "${cmd}" | tee -a "${OUT_DIR}/commands.log" >/dev/null
	if ! bash -lc "${cmd}" >"${stdout_file}" 2>"${stderr_file}"; then
		rc=$?
	fi
	printf '%s %s\n' "${name}" "${rc}" >> "${OUT_DIR}/exit-codes.txt"
}

run_shell uname "uname -a"
run_shell dmesg "dmesg | grep -Ei 'INT3446|INT3472|INT3477|INT3479|ipu3|ov5670|ov8858'"
run_shell cam-list "cam -l || true"
run_shell media-ctl "media-ctl -p || true"
run_shell v4l2-devices "v4l2-ctl --list-devices || true"
run_shell gst "gst-launch-1.0 libcamerasrc ! videoconvert ! fakesink || true"

cat > "${OUT_DIR}/success-criteria.txt" <<'EOF'
Level 1: dmesg no longer shows "No board-data found for this model"
Level 2: cam -l shows OV5670 / INT3479
Level 3: cam -l shows OV5670 / INT3479 and OV8858 / INT3477
Level 4: gst-launch-1.0 libcamerasrc ! videoconvert ! fakesink succeeds
EOF

printf '%s\n' "${OUT_DIR}"
