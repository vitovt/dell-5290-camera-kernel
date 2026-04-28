#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
LOOPBACK_DEVICE="${LOOPBACK_DEVICE:-/dev/video42}"
VIDEO_FORMAT="${VIDEO_FORMAT:-YUY2}"
USE_XTERM=1
HOLD_XTERM=0
CAMERA="front"

usage() {
	cat <<EOF
usage: $(basename "$0") [front|back] [options]

Options:
  --device <path>   V4L2 loopback device, default: ${LOOPBACK_DEVICE}
  --no-xterm        Run in the current terminal
  --hold            Keep xterm open after the command exits
  -h, --help        Show this help

Examples:
  ./run-cam.sh
  ./run-cam.sh back
  ./run-cam.sh front --device /dev/video42
EOF
}

camera_id_for() {
	case "$1" in
		front|0|LNK0|lnk0)
			printf '_SB_.PCI0.LNK0'
			;;
		back|1|LNK1|lnk1)
			printf '_SB_.PCI0.LNK1'
			;;
		_SB_.PCI0.LNK0|_SB_.PCI0.LNK1)
			printf '%s' "$1"
			;;
		*)
			printf 'unknown camera: %s\n' "$1" >&2
			exit 2
			;;
	esac
}

reset_media_graphs() {
	for media in /dev/media0 /dev/media1; do
		[[ -e "${media}" ]] || continue
		media-ctl -r -d "${media}" || true
	done
}

run_worker() {
	local camera_id="$1"
	local camera_name="\\\\${camera_id}"
	local gst_pid=""
	local rc=0

	if [[ ! -e "${LOOPBACK_DEVICE}" ]]; then
		cat >&2 <<EOF
${LOOPBACK_DEVICE} does not exist.
Create it first, for example:
  sudo modprobe v4l2loopback video_nr=42 card_label="Dell 5290 Camera" exclusive_caps=1
EOF
		exit 1
	fi

	cleanup() {
		rc=$?
		trap - EXIT HUP INT TERM
		if [[ -n "${gst_pid}" ]] && kill -0 "${gst_pid}" 2>/dev/null; then
			kill -TERM "${gst_pid}" 2>/dev/null || true
			wait "${gst_pid}" 2>/dev/null || true
		fi
		reset_media_graphs
		exit "${rc}"
	}

	trap cleanup EXIT HUP INT TERM

	reset_media_graphs
	printf 'Forwarding %s to %s. Close this window or press Ctrl+C to stop.\n' "${camera_id}" "${LOOPBACK_DEVICE}"

	gst-launch-1.0 libcamerasrc "camera-name=${camera_name}" \
		! queue \
		! videoconvert \
		! "video/x-raw,format=${VIDEO_FORMAT}" \
		! v4l2sink "device=${LOOPBACK_DEVICE}" sync=false &
	gst_pid=$!
	wait "${gst_pid}"
}

if [[ "${1:-}" == "--worker" ]]; then
	shift
	[[ $# -eq 2 ]] || {
		printf 'internal error: --worker requires <camera-id> <loopback-device>\n' >&2
		exit 2
	}
	LOOPBACK_DEVICE="$2"
	run_worker "$1"
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		front|back|0|1|LNK0|LNK1|lnk0|lnk1|_SB_.PCI0.LNK0|_SB_.PCI0.LNK1)
			CAMERA="$1"
			shift
			;;
		--device)
			LOOPBACK_DEVICE="$2"
			shift 2
			;;
		--no-xterm)
			USE_XTERM=0
			shift
			;;
		--hold)
			HOLD_XTERM=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'unknown option: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

CAMERA_ID="$(camera_id_for "${CAMERA}")"

if [[ "${USE_XTERM}" -eq 1 ]]; then
	xterm_args=(-T "Virtual Camera" -bg darkblue -fg yellow)
	if [[ "${HOLD_XTERM}" -eq 1 ]]; then
		xterm_args=(-hold "${xterm_args[@]}")
	fi
	exec xterm "${xterm_args[@]}" -e "${SCRIPT_PATH}" --worker "${CAMERA_ID}" "${LOOPBACK_DEVICE}"
fi

run_worker "${CAMERA_ID}"
