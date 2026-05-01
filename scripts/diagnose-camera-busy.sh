#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-camera-busy}"
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

run_bounded_shell() {
	local name="$1"
	local cmd="$2"
	local stdout_file="${OUT_DIR}/${name}.stdout"
	local stderr_file="${OUT_DIR}/${name}.stderr"
	local rc=0

	printf '==> %s\n' "${cmd}" | tee -a "${OUT_DIR}/commands.log" >/dev/null
	bash -lc "${cmd}" >"${stdout_file}" 2>"${stderr_file}" || rc=$?
	printf '%s %s\n' "${name}" "${rc}" >> "${OUT_DIR}/exit-codes.txt"
}

run_shell date "date --iso-8601=seconds"
run_shell uptime "uptime"
run_shell uname "uname -a"
run_shell devices "ls -l /dev/media* /dev/video* /dev/v4l-subdev* /dev/dma_heap/system 2>/dev/null || true"
run_shell acl "getfacl -p /dev/dma_heap/system /dev/media0 /dev/media1 /dev/video0 /dev/video1 /dev/video42 2>/dev/null || true"
run_shell groups "id && groups"
run_shell fuser "fuser -v /dev/media* /dev/video* /dev/v4l-subdev* /dev/dma_heap/system 2>/dev/null || true"
run_shell lsof "command -v lsof >/dev/null && lsof /dev/media* /dev/video* /dev/v4l-subdev* /dev/dma_heap/system 2>/dev/null || true"
run_shell camera-processes "ps -eo pid,ppid,stat,comm,args | grep -Ei 'gst-launch|libcamera|pipewire|wireplumber|xdg-desktop-portal|chrome|chromium|vivaldi|firefox|zoom|telegram|cheese' | grep -v grep || true"
run_bounded_shell cam-list "timeout --signal=TERM --kill-after=2s 8s cam -l 2>&1 | head -n 240"
run_shell media0 "media-ctl -p -d /dev/media0 || true"
run_shell media1 "media-ctl -p -d /dev/media1 || true"
run_shell v4l2-devices "v4l2-ctl --list-devices || true"
run_shell wpctl "wpctl status || true"
run_shell dmesg "dmesg | grep -Ei 'ov5670|ov8858|dw9714|ipu3|cio2|imgu|int3472|tps68470|v4l2|media|fail|error|busy|timeout' | tail -n 240 || true"

cat > "${OUT_DIR}/next-steps.txt" <<'EOF'
If cam-list shows "Device or resource busy":
1. Check fuser.stdout and camera-processes.stdout first.
2. Close or stop the process that owns /dev/media0, /dev/video0, /dev/video1,
   /dev/video6, /dev/video11, /dev/video42, or related /dev/v4l-subdev nodes.
3. After closing the owner, run:
     media-ctl -r -d /dev/media0
     media-ctl -r -d /dev/media1
     cam -l
4. If fuser shows no owner but cam -l still reports busy, collect sudo dmesg
   and test whether the failure started after suspend/resume.
EOF

printf '%s\n' "${OUT_DIR}"
