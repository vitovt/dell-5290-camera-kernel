#!/usr/bin/env bash
set -euo pipefail

module_strings() {
	local module_path

	module_path="$(modinfo -F filename "$1" 2>/dev/null || true)"
	if [[ -z "${module_path}" || ! -e "${module_path}" ]]; then
		modinfo "$1" 2>/dev/null || true
		return
	fi

	case "${module_path}" in
	*.zst)
		zstdcat "${module_path}" | strings
		;;
	*.xz)
		xzcat "${module_path}" | strings
		;;
	*.gz)
		zcat "${module_path}" | strings
		;;
	*)
		strings "${module_path}"
		;;
	esac
}

printf 'Kernel:\n'
uname -a
printf '\nLoaded camera modules:\n'
lsmod | grep -E '^(ov5670|ov8858|dw9714|ipu3_cio2|ipu3_imgu|intel_skl_int3472|tps68470|clk_tps68470|gpio_tps68470)' || true

printf '\nDW9714 module strings:\n'
module_strings dw9714 \
	| grep -E 'dw9714_vcm_system|Ignoring power .* system|dw9714_vcm_suspend|dw9714_vcm_resume' || true

printf '\nOV sensor system sleep strings:\n'
module_strings ov5670 \
	| grep -E 'ov5670_system_|force runtime .* system sleep' || true
module_strings ov8858 \
	| grep -E 'ov8858_system_|force runtime .* system sleep' || true

printf '\nTPS68470 board-data strings:\n'
module_strings intel_skl_int3472_tps68470 \
	| grep -E 'i2c-INT3477:00-VCM|dell_5290_int3477_vcm|Latitude 5290' || true

printf '\nRecent relevant dmesg:\n'
dmesg 2>/dev/null \
	| grep -Ei 'dw9714|ov5670|ov8858|ipu3|cio2|imgu|int3472|tps68470|vcc not found|failed to suspend|PM:' \
	| tail -n 160 || true
