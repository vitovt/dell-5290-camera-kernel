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
	bash -lc "${cmd}" >"${stdout_file}" 2>"${stderr_file}" || rc=$?
	printf '%s %s\n' "${name}" "${rc}" >> "${OUT_DIR}/exit-codes.txt"
}

run_shell uname "uname -a"
run_shell dmesg "dmesg | grep -Ei 'INT3446|INT3472|INT3477|INT3479|ipu3|ov5670|ov8858|dw9714|tps68470|dma_heap'"
run_shell dma-heap-acl "getfacl -p /dev/dma_heap/system"
run_shell cam-list "cam -l || true"
run_shell media-ctl-cio2 "media-ctl -p -d /dev/media0 || true"
run_shell media-ctl-imgu "media-ctl -p -d /dev/media1 || true"
run_shell v4l2-devices "v4l2-ctl --list-devices || true"
run_shell gst-front "media-ctl -r -d /dev/media0 && media-ctl -r -d /dev/media1 && timeout --signal=TERM --kill-after=5s 20s gst-launch-1.0 libcamerasrc camera-name='\\\\_SB_.PCI0.LNK0' ! queue ! videoconvert ! queue ! fakesink"
run_shell gst-back "media-ctl -r -d /dev/media0 && media-ctl -r -d /dev/media1 && timeout --signal=TERM --kill-after=5s 20s gst-launch-1.0 libcamerasrc camera-name='\\\\_SB_.PCI0.LNK1' ! queue ! videoconvert ! queue ! fakesink"

cat > "${OUT_DIR}/success-criteria.txt" <<'EOF'
Level 1: dmesg no longer shows "No board-data found for this model"
Level 2: cam -l shows OV5670 / INT3479
Level 3: cam -l shows OV5670 / INT3479 and OV8858 / INT3477
Level 4: /dev/dma_heap/system grants the desktop user read/write access
Level 5: both explicit camera pipelines succeed within 20 seconds:
  - \_SB_.PCI0.LNK0 front camera
  - \_SB_.PCI0.LNK1 back camera
EOF

printf '%s\n' "${OUT_DIR}"
