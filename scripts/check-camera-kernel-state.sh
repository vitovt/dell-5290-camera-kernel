#!/usr/bin/env bash
set -euo pipefail

printf 'Kernel:\n'
uname -a
printf '\nLoaded camera modules:\n'
lsmod | grep -E '^(ov5670|ov8858|dw9714|ipu3_cio2|ipu3_imgu|intel_skl_int3472|tps68470|clk_tps68470|gpio_tps68470)' || true

printf '\nDW9714 module strings:\n'
if [[ -e /lib/modules/"$(uname -r)"/kernel/drivers/media/i2c/dw9714.ko.zst ]]; then
	zstdcat /lib/modules/"$(uname -r)"/kernel/drivers/media/i2c/dw9714.ko.zst \
		| strings \
		| grep -E 'dw9714_vcm_system|Ignoring power .* system' || true
else
	modinfo dw9714 2>/dev/null || true
fi

printf '\nTPS68470 board-data strings:\n'
if [[ -e /lib/modules/"$(uname -r)"/kernel/drivers/platform/x86/intel/int3472/intel_skl_int3472_tps68470.ko.zst ]]; then
	zstdcat /lib/modules/"$(uname -r)"/kernel/drivers/platform/x86/intel/int3472/intel_skl_int3472_tps68470.ko.zst \
		| strings \
		| grep -E 'i2c-INT3477:00-VCM|dell_5290_int3477_vcm|Latitude 5290' || true
else
	modinfo intel_skl_int3472_tps68470 2>/dev/null || true
fi

printf '\nRecent relevant dmesg:\n'
dmesg 2>/dev/null \
	| grep -Ei 'dw9714|ov5670|ov8858|ipu3|cio2|imgu|int3472|tps68470|vcc not found|failed to suspend|PM:' \
	| tail -n 160 || true
