#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/results/dell-driver-unpack/${STAMP}"
mkdir -p "${OUT_DIR}"

if [[ $# -ne 1 ]]; then
	echo "usage: $0 <dell-exe-path-or-url>" >&2
	exit 2
fi

INPUT="$1"
SOURCE_FILE=""

download_if_needed() {
	if [[ "${INPUT}" =~ ^https?:// ]]; then
		SOURCE_FILE="${OUT_DIR}/$(basename "${INPUT}")"
		curl -L --fail --output "${SOURCE_FILE}" "${INPUT}"
	else
		SOURCE_FILE="$(readlink -f "${INPUT}")"
	fi
}

extract_with() {
	local tool="$1"
	case "${tool}" in
		7z)
			7z x -y -o"${OUT_DIR}/extract" "${SOURCE_FILE}"
			;;
		cabextract)
			(
				cd "${OUT_DIR}/extract"
				cabextract "${SOURCE_FILE}"
			)
			;;
		innoextract)
			innoextract -d "${OUT_DIR}/extract" "${SOURCE_FILE}"
			;;
		bsdtar)
			bsdtar -C "${OUT_DIR}/extract" -xf "${SOURCE_FILE}"
			;;
		*)
			return 1
			;;
	esac
}

download_if_needed
mkdir -p "${OUT_DIR}/extract"

for tool in 7z cabextract innoextract bsdtar; do
	if command -v "${tool}" >/dev/null 2>&1; then
		if extract_with "${tool}" >"${OUT_DIR}/${tool}.stdout" 2>"${OUT_DIR}/${tool}.stderr"; then
			printf '%s\n' "${tool}" > "${OUT_DIR}/extractor-used.txt"
			break
		fi
	fi
done

if [[ ! -f "${OUT_DIR}/extractor-used.txt" ]]; then
	echo "no supported extractor succeeded" >&2
	exit 1
fi

find "${OUT_DIR}/extract" \( -iname '*.inf' -o -iname '*.cat' -o -iname '*.sys' \) | sort > "${OUT_DIR}/inventory.txt"
printf '%s\n' "${OUT_DIR}"
