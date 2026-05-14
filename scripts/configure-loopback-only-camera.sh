#!/usr/bin/env bash
set -euo pipefail

LOOPBACK_DEVICE="${LOOPBACK_DEVICE:-/dev/video42}"
CONFIG_BASENAME="60-dell-5290-loopback-only.lua"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/wireplumber/main.lua.d"
USER_CONFIG_PATH="${USER_CONFIG_DIR}/${CONFIG_BASENAME}"

usage() {
	cat <<EOF
usage: $(basename "$0") <command> [options]

Configure WirePlumber for loopback-only camera usage on Dell 5290.

Commands:
  install      Disable physical libcamera/IPU3 cameras in WirePlumber
  remove       Remove the WirePlumber override
  status       Show current override and camera device users
  restart      Restart user PipeWire/WirePlumber services
  help         Show this help

Options:
  --device <path>  V4L2 loopback device to keep visible, default: ${LOOPBACK_DEVICE}
  --no-restart     Do not restart PipeWire/WirePlumber after install/remove
  -h, --help       Show this help

The override is installed under:
  ${USER_CONFIG_PATH}

It disables WirePlumber's libcamera monitor and disables V4L2 nodes
/dev/video0 through /dev/video31. The loopback device, normally /dev/video42,
remains visible for Zoom, Telegram and browsers.
EOF
}

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

restart_services() {
	log "restarting user PipeWire/WirePlumber services"
	systemctl --user restart pipewire pipewire-pulse wireplumber
}

write_config() {
	local tmp

	mkdir -p "${USER_CONFIG_DIR}"
	tmp="$(mktemp "${USER_CONFIG_DIR}/.${CONFIG_BASENAME}.XXXXXX")"

	{
		cat <<EOF
-- Managed by dell-5290-camera-kernel/scripts/configure-loopback-only-camera.sh
--
-- Keep applications on the v4l2loopback camera (${LOOPBACK_DEVICE}) and stop
-- WirePlumber from opening the unstable physical IPU3/libcamera cameras.

libcamera_monitor.enabled = false

v4l2_monitor.rules = {
EOF

		for number in $(seq 0 31); do
			cat <<EOF
  {
    matches = {
      {
        { "api.v4l2.path", "equals", "/dev/video${number}" },
      },
    },
    apply_properties = {
      ["device.disabled"] = true,
      ["node.disabled"] = true,
    },
  },
EOF
		done

		cat <<EOF
  {
    matches = {
      {
        { "api.v4l2.path", "equals", "${LOOPBACK_DEVICE}" },
      },
    },
    apply_properties = {
      ["node.nick"] = "Dell 5290 Camera",
      ["node.description"] = "Dell 5290 Camera (loopback)",
      ["priority.session"] = 1000,
    },
  },
}
EOF
	} >"${tmp}"

	chmod 0644 "${tmp}"
	mv "${tmp}" "${USER_CONFIG_PATH}"
	log "installed ${USER_CONFIG_PATH}"
}

show_status() {
	local devices=()
	local dev

	if [[ -e "${USER_CONFIG_PATH}" ]]; then
		printf 'WirePlumber override: installed at %s\n' "${USER_CONFIG_PATH}"
	else
		printf 'WirePlumber override: not installed at %s\n' "${USER_CONFIG_PATH}"
	fi

	printf 'Loopback device: %s' "${LOOPBACK_DEVICE}"
	if [[ -e "${LOOPBACK_DEVICE}" ]]; then
		printf ' (present)\n'
	else
		printf ' (missing)\n'
	fi

	printf '\nRelevant camera devices:\n'
	ls -l /dev/media* /dev/video* /dev/v4l-subdev* "${LOOPBACK_DEVICE}" 2>/dev/null || true

	for dev in /dev/media* /dev/video* /dev/v4l-subdev* /dev/dma_heap/system; do
		[[ -e "${dev}" ]] || continue
		devices+=("${dev}")
	done

	if [[ "${#devices[@]}" -gt 0 ]] && command -v fuser >/dev/null 2>&1; then
		printf '\nCamera device users:\n'
		fuser -v "${devices[@]}" 2>/dev/null || true
	fi

	printf '\nRelevant processes:\n'
	ps -eo pid,ppid,stat,comm,args \
		| grep -Ei 'gst-launch|libcamera|pipewire|wireplumber|xdg-desktop-portal|chrome|chromium|vivaldi|firefox|zoom|telegram|cheese' \
		| grep -v grep || true
}

COMMAND="${1:-help}"
shift || true

DO_RESTART=1

while [[ $# -gt 0 ]]; do
	case "$1" in
		--device)
			[[ $# -ge 2 ]] || {
				printf 'missing value for --device\n' >&2
				exit 2
			}
			LOOPBACK_DEVICE="$2"
			shift 2
			;;
		--no-restart)
			DO_RESTART=0
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

case "${COMMAND}" in
	install)
		write_config
		if [[ "${DO_RESTART}" -eq 1 ]]; then
			restart_services
		fi
		show_status
		;;
	remove)
		if [[ -e "${USER_CONFIG_PATH}" ]]; then
			rm -f "${USER_CONFIG_PATH}"
			log "removed ${USER_CONFIG_PATH}"
		else
			log "override is not installed"
		fi
		if [[ "${DO_RESTART}" -eq 1 ]]; then
			restart_services
		fi
		show_status
		;;
	status)
		show_status
		;;
	restart)
		restart_services
		show_status
		;;
	help|-h|--help)
		usage
		;;
	*)
		printf 'unknown command: %s\n' "${COMMAND}" >&2
		usage >&2
		exit 2
		;;
esac
