#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-baseline}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/results/${LABEL}/${STAMP}"
mkdir -p "${OUT_DIR}"

run_capture() {
	local name="$1"
	shift
	local stdout_file="${OUT_DIR}/${name}.stdout"
	local stderr_file="${OUT_DIR}/${name}.stderr"
	local rc=0

	printf '==> %s\n' "$*" | tee -a "${OUT_DIR}/commands.log" >/dev/null
	if ! "$@" >"${stdout_file}" 2>"${stderr_file}"; then
		rc=$?
	fi
	printf '%s %s\n' "${name}" "${rc}" >> "${OUT_DIR}/exit-codes.txt"
}

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

run_capture uname uname -a
run_capture os-release cat /etc/os-release
run_capture dmi-sys-vendor cat /sys/class/dmi/id/sys_vendor
run_capture dmi-product-name cat /sys/class/dmi/id/product_name
run_capture dmi-board-name cat /sys/class/dmi/id/board_name
run_shell acpi-hids "grep . /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -E 'INT3472|INT3477|INT3479|INT3446'"
run_shell lsmod "lsmod | grep -E 'ipu|int3472|ov5670|ov8858|intel_lpss'"
run_shell dmesg "dmesg | grep -Ei 'ipu|int3472|ov5670|ov8858|INT3446|INT3477|INT3479'"
run_shell cam-list "cam -l || true"
run_shell media-ctl "media-ctl -p || true"
run_shell v4l2-devices "v4l2-ctl --list-devices || true"

cat > "${OUT_DIR}/summary.txt" <<EOF
label=${LABEL}
timestamp=${STAMP}
host_uname=$(uname -a)
host_product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
EOF

printf '%s\n' "${OUT_DIR}"
