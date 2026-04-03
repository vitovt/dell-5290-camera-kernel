#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="${ROOT_DIR}/patches"
LOG_DIR="${ROOT_DIR}/logs"
OUT_DIR="${ROOT_DIR}/out"
WORKDIR="${ROOT_DIR}/work"
JOBS="$(nproc)"
SOURCE_PACKAGE=""
SOURCE_VERSION=""
KERNEL_REF=""
BUILD_TARGET="dpkg-buildpackage"
USE_LOCAL_ABI=1
LOCAL_ABI="999"
DO_CLEAN=0
DO_MENUCONFIG=0
DO_OLDDEFCONFIG=0
DO_INSTALL=0
DO_NO_BUILD=0
DO_COLLECT_DEBUG=0
DO_INSTALL_BUILD_DEPS=0

usage() {
	cat <<'EOF'
usage: build-kernel-5290.sh [options]

Options:
  --workdir <path>
  --source-package <name>
  --source-version <version>
  --kernel-ref <value>      Alias for --source-version in Ubuntu-source mode
  --local-abi <n>           Numeric ABI override for custom Ubuntu package names
  --no-local-abi            Keep Ubuntu ABI/package names and print removal hints
  --clean                   Re-extract sources and rebuild from scratch
  --full-rebuild            Alias for --clean
  --reuse-build             Reuse existing compiled tree (default)
  --menuconfig
  --olddefconfig
  --jobs <n>
  --install
  --no-build
  --collect-debug
  --install-build-deps
  --build-target <mode>     dpkg-buildpackage (default) or bindeb-pkg
EOF
}

log() {
	printf '[%s] %s\n' "$(date +%F' '%T)" "$*" | tee -a "${BUILD_LOG}"
}

die() {
	log "ERROR: $*"
	collect_artifacts || true
	exit 1
}

detect_source_package() {
	local version_sig
	version_sig="$(cat /proc/version_signature 2>/dev/null || true)"

	if [[ -n "${SOURCE_PACKAGE}" ]]; then
		return
	fi

	if [[ "${version_sig}" == *" 6.17."* ]]; then
		SOURCE_PACKAGE="linux-hwe-6.17"
	else
		SOURCE_PACKAGE="linux"
	fi
}

resolve_source_version() {
	local metadata_file stanza
	metadata_file="${STATE_DIR}/showsrc.txt"
	apt-cache showsrc "${SOURCE_PACKAGE}" > "${metadata_file}"

	if [[ -n "${SOURCE_VERSION}" ]]; then
		return
	fi

	SOURCE_VERSION="$(awk '/^Version: / { print $2; exit }' "${metadata_file}")"
	[[ -n "${SOURCE_VERSION}" ]] || die "failed to resolve source version for ${SOURCE_PACKAGE}"
}

derive_version_plan() {
	local base_version original_revision upload_revision

	base_version="${SOURCE_VERSION%-*}"
	original_revision="${SOURCE_VERSION##*-}"
	ORIGINAL_ABI="${original_revision%%.*}"
	[[ "${ORIGINAL_ABI}" =~ ^[0-9]+$ ]] || die "source revision ${original_revision} does not begin with a numeric ABI"

	if [[ "${USE_LOCAL_ABI}" -eq 1 ]]; then
		[[ "${LOCAL_ABI}" =~ ^[0-9]+$ ]] || die "local ABI must be numeric, got ${LOCAL_ABI}"
		TARGET_ABI="${LOCAL_ABI}"
	else
		TARGET_ABI="${ORIGINAL_ABI}"
	fi

	if [[ "${TARGET_ABI}" == "${ORIGINAL_ABI}" ]]; then
		TARGET_SOURCE_VERSION="${SOURCE_VERSION}"
	else
		if [[ "${original_revision}" == *.* ]]; then
			upload_revision="${original_revision#*.}"
			TARGET_SOURCE_VERSION="${base_version}-${TARGET_ABI}.${upload_revision}"
		else
			TARGET_SOURCE_VERSION="${base_version}-${TARGET_ABI}"
		fi
	fi

	ABI_RELEASE="${base_version}-${TARGET_ABI}"
	ARTIFACT_DIR="${OUT_DIR}/${ABI_RELEASE}"
}

extract_selected_stanza() {
	local metadata_file="$1"
	local stanza_file="$2"

	awk -v pkg="${SOURCE_PACKAGE}" -v ver="${SOURCE_VERSION}" '
	BEGIN { RS=""; FS="\n" }
	{
		p = ""; v = "";
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^Package: /) p = substr($i, 10);
			if ($i ~ /^Version: /) v = substr($i, 10);
		}
		if (p == pkg && v == ver) {
			print $0;
			exit 0;
		}
	}
	' "${metadata_file}" > "${stanza_file}"

	[[ -s "${stanza_file}" ]] || die "could not find source stanza for ${SOURCE_PACKAGE} ${SOURCE_VERSION}"
}

download_source_archives() {
	local metadata_file="${STATE_DIR}/showsrc.txt"
	local stanza_file="${STATE_DIR}/showsrc-selected.txt"
	local directory file base_url dsc_file
	local -a files=()

	extract_selected_stanza "${metadata_file}" "${stanza_file}"
	directory="$(awk -F': ' '/^Directory: / { print $2; exit }' "${stanza_file}")"
	[[ -n "${directory}" ]] || die "missing Directory field for ${SOURCE_PACKAGE} ${SOURCE_VERSION}"

	mapfile -t files < <(
		awk '
			/^Files:$/ { in_files = 1; next }
			in_files && /^[A-Z][A-Za-z-]*: / { in_files = 0 }
			in_files && NF >= 3 { print $3 }
		' "${stanza_file}" | awk '!seen[$0]++'
	)
	[[ "${#files[@]}" -gt 0 ]] || die "missing Files list for ${SOURCE_PACKAGE} ${SOURCE_VERSION}"

	base_url="http://archive.ubuntu.com/ubuntu"
	mkdir -p "${DOWNLOAD_DIR}"

	for file in "${files[@]}"; do
		log "downloading ${file}"
		wget -c -O "${DOWNLOAD_DIR}/${file}" "${base_url}/${directory}/${file}" >> "${BUILD_LOG}" 2>&1
	done

	dsc_file="$(printf '%s\n' "${files[@]}" | awk '/\.dsc$/ { print; exit }')"
	[[ -n "${dsc_file}" ]] || die "failed to locate .dsc file"
	DSC_FILE="${DOWNLOAD_DIR}/${dsc_file}"
}

extract_source_tree() {
	local extracted

	if [[ -d "${SOURCE_TREE}" ]]; then
		log "source tree already present at ${SOURCE_TREE}"
		return
	fi

	mkdir -p "${WORKDIR}"
	dpkg-source -x "${DSC_FILE}" "${SOURCE_TREE}" >> "${BUILD_LOG}" 2>&1

	extracted=1
	[[ -n "${extracted}" ]] || die "source extraction failed"
}

detect_packaging_dir() {
	local candidate

	if [[ -n "${DEBIAN_DIR:-}" && -f "${DEBIAN_DIR}/changelog" ]]; then
		return
	fi

	for candidate in "${SOURCE_TREE}"/debian*; do
		[[ -f "${candidate}/changelog" ]] || continue
		if head -n 1 "${candidate}/changelog" | grep -q "^${SOURCE_PACKAGE} "; then
			DEBIAN_DIR="${candidate}"
			return
		fi
	done

	die "failed to locate packaging directory for ${SOURCE_PACKAGE}"
}

warn_same_abi_conflicts() {
	log "WARNING: local ABI renaming is disabled; packages will keep Ubuntu ABI ${ABI_RELEASE} and may collide with installed Ubuntu kernel packages."
	log "WARNING: minimum image conflict removal command:"
	log "WARNING:   sudo apt remove linux-image-${ABI_RELEASE}-generic"
	log "WARNING: full same-ABI stack removal command:"
	log "WARNING:   sudo apt remove linux-image-${ABI_RELEASE}-generic linux-modules-${ABI_RELEASE}-generic linux-modules-extra-${ABI_RELEASE}-generic linux-headers-${ABI_RELEASE}-generic ${SOURCE_PACKAGE}-headers-${ABI_RELEASE}"
}

apply_local_abi_policy() {
	local changelog current_version

	detect_packaging_dir
	changelog="${DEBIAN_DIR}/changelog"
	current_version="$(dpkg-parsechangelog -l"${changelog}" -S version)"

	if [[ "${current_version}" != "${TARGET_SOURCE_VERSION}" ]]; then
		sed -i "1s/(${current_version})/(${TARGET_SOURCE_VERSION})/" "${changelog}"
		log "set ${DEBIAN_DIR}/changelog package version to ${TARGET_SOURCE_VERSION}"
	else
		log "packaging changelog already set to ${TARGET_SOURCE_VERSION}"
	fi

	if [[ "${USE_LOCAL_ABI}" -eq 1 ]]; then
		log "using Ubuntu-style custom ABI ${TARGET_ABI}; package names will use ${ABI_RELEASE}"
	else
		warn_same_abi_conflicts
	fi
}

install_build_deps() {
	if [[ "${DO_INSTALL_BUILD_DEPS}" -eq 0 ]]; then
		return
	fi

	log "installing build dependencies for ${SOURCE_PACKAGE}"
	sudo apt-get update >> "${BUILD_LOG}" 2>&1
	sudo apt-get build-dep -y "${SOURCE_PACKAGE}" >> "${BUILD_LOG}" 2>&1
}

copy_runtime_config() {
	if [[ ! -r "/boot/config-$(uname -r)" ]]; then
		log "skipping runtime config seed: /boot/config-$(uname -r) not found"
		return
	fi

	cp "/boot/config-$(uname -r)" "${SOURCE_TREE}/.config"
	log "seeded ${SOURCE_TREE}/.config from running kernel"
}

prepare_config() {
	if [[ "${BUILD_TARGET}" == "dpkg-buildpackage" ]]; then
		log "skipping top-level .config seeding for Ubuntu packaging build"
		return
	fi

	copy_runtime_config

	if [[ "${DO_OLDDEFCONFIG}" -eq 1 ]]; then
		if [[ -f "${SOURCE_TREE}/Makefile" ]]; then
			log "running olddefconfig for symbol sanity"
			(
				cd "${SOURCE_TREE}"
				yes "" | make olddefconfig
			) >> "${BUILD_LOG}" 2>&1 || die "olddefconfig failed"
		fi
	fi
}

apply_patches() {
	local stamp_file="${STATE_DIR}/patches.applied"
	local patch_file

	if [[ -f "${stamp_file}" ]]; then
		log "patches already applied"
		return
	fi

	for patch_file in "${PATCH_DIR}"/[0-9][0-9][0-9][0-9]-*.patch; do
		log "applying $(basename "${patch_file}")"
		(
			cd "${SOURCE_TREE}"
			patch -p1 --forward < "${patch_file}"
		) >> "${BUILD_LOG}" 2>&1 || die "failed to apply $(basename "${patch_file}")"
	done

	date +%s > "${stamp_file}"
}

run_menuconfig_if_requested() {
	if [[ "${DO_MENUCONFIG}" -eq 0 ]]; then
		return
	fi

	case "${BUILD_TARGET}" in
		dpkg-buildpackage)
			log "running Ubuntu config editor"
			(
				cd "${SOURCE_TREE}"
				skipmodule=true skipabi=true fakeroot debian/rules editconfigs
			) >> "${BUILD_LOG}" 2>&1 || die "debian/rules editconfigs failed"
			;;
		bindeb-pkg)
			log "running make menuconfig"
			(
				cd "${SOURCE_TREE}"
				make menuconfig
			) >> "${BUILD_LOG}" 2>&1 || die "menuconfig failed"
			;;
		*)
			die "unsupported build target ${BUILD_TARGET}"
			;;
	esac
}

apply_packaging_workarounds() {
	local amd64_rules

	detect_packaging_dir
	amd64_rules="${DEBIAN_DIR}/rules.d/amd64.mk"
	if [[ -f "${amd64_rules}" ]] && grep -q '^do_tools_perf_jvmti = true$' "${amd64_rules}"; then
		log "disabling do_tools_perf_jvmti in Ubuntu HWE amd64 packaging to avoid missing libperf-jvmti.so"
		sed -i 's/^do_tools_perf_jvmti = true$/do_tools_perf_jvmti = false/' "${amd64_rules}"
	fi
}

build_debs() {
	if [[ "${DO_NO_BUILD}" -eq 1 ]]; then
		log "skipping build because --no-build was requested"
		return
	fi

	case "${BUILD_TARGET}" in
		dpkg-buildpackage)
			log "building Ubuntu kernel packages with incremental dpkg-buildpackage -nc"
			(
				cd "${SOURCE_TREE}"
				DEB_BUILD_OPTIONS="parallel=${JOBS}" \
				skipmodule=true skipabi=true \
				dpkg-buildpackage -b -uc -us -nc
			) >> "${BUILD_LOG}" 2>&1 || die "dpkg-buildpackage failed"
			;;
		bindeb-pkg)
			log "building packages with make bindeb-pkg"
			(
				cd "${SOURCE_TREE}"
				make -j"${JOBS}" bindeb-pkg LOCALVERSION=-dell5290cam
			) >> "${BUILD_LOG}" 2>&1 || die "make bindeb-pkg failed"
			;;
		*)
			die "unsupported build target ${BUILD_TARGET}"
			;;
	esac
}

collect_artifacts() {
	local artifact_root name_filter
	local found=0
	artifact_root="${ARTIFACT_DIR:-${OUT_DIR}}"
	name_filter='*.deb'
	if [[ -n "${ABI_RELEASE:-}" ]]; then
		name_filter="*${ABI_RELEASE}*.deb"
	fi
	mkdir -p "${artifact_root}"

	while IFS= read -r -d '' deb; do
		found=1
		cp -f "${deb}" "${artifact_root}/"
	done < <(find "${WORKDIR}" -maxdepth 3 -type f -name "${name_filter}" -print0)

	if [[ "${found}" -eq 0 ]]; then
		log "no .deb artifacts matching ${name_filter} found under ${WORKDIR}"
	else
		log "copied .deb artifacts into ${artifact_root}"
	fi
}

install_kernel_if_requested() {
	local deb
	local -a debs=()

	if [[ "${DO_INSTALL}" -eq 0 ]]; then
		return
	fi

	shopt -s nullglob
	for deb in \
		"${ARTIFACT_DIR}"/linux-image-unsigned-"${ABI_RELEASE}"-*.deb \
		"${ARTIFACT_DIR}"/linux-image-"${ABI_RELEASE}"-*.deb \
		"${ARTIFACT_DIR}"/linux-modules-"${ABI_RELEASE}"-*.deb \
		"${ARTIFACT_DIR}"/linux-modules-*-"${ABI_RELEASE}"-*.deb \
		"${ARTIFACT_DIR}"/linux-headers-"${ABI_RELEASE}"-*.deb \
		"${ARTIFACT_DIR}"/"${SOURCE_PACKAGE}"-headers-"${ABI_RELEASE}"_*.deb
	do
		[[ -f "${deb}" ]] || continue
		debs+=("${deb}")
	done
	shopt -u nullglob
	[[ "${#debs[@]}" -gt 0 ]] || die "no installable kernel debs available in ${ARTIFACT_DIR}"

	log "installing built kernel runtime/header packages from ${ARTIFACT_DIR}"
	sudo dpkg -i "${debs[@]}" >> "${BUILD_LOG}" 2>&1 || die "dpkg installation failed"
}

post_build_summary() {
	cat <<EOF | tee -a "${BUILD_LOG}"
source_package=${SOURCE_PACKAGE}
source_version=${SOURCE_VERSION}
package_version=${TARGET_SOURCE_VERSION}
abi_release=${ABI_RELEASE}
source_tree=${SOURCE_TREE}
download_dir=${DOWNLOAD_DIR}
out_dir=${ARTIFACT_DIR:-${OUT_DIR}}
build_log=${BUILD_LOG}
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--workdir)
				WORKDIR="$2"
				shift 2
				;;
			--source-package)
				SOURCE_PACKAGE="$2"
				shift 2
				;;
			--source-version)
				SOURCE_VERSION="$2"
				shift 2
				;;
			--kernel-ref)
				KERNEL_REF="$2"
				SOURCE_VERSION="$2"
				shift 2
				;;
			--local-abi)
				USE_LOCAL_ABI=1
				LOCAL_ABI="$2"
				shift 2
				;;
			--no-local-abi)
				USE_LOCAL_ABI=0
				shift
				;;
			--clean)
				DO_CLEAN=1
				shift
				;;
			--full-rebuild)
				DO_CLEAN=1
				shift
				;;
			--reuse-build)
				DO_CLEAN=0
				shift
				;;
			--menuconfig)
				DO_MENUCONFIG=1
				shift
				;;
			--olddefconfig)
				DO_OLDDEFCONFIG=1
				shift
				;;
			--jobs)
				JOBS="$2"
				shift 2
				;;
			--install)
				DO_INSTALL=1
				shift
				;;
			--no-build)
				DO_NO_BUILD=1
				shift
				;;
			--collect-debug)
				DO_COLLECT_DEBUG=1
				shift
				;;
			--install-build-deps)
				DO_INSTALL_BUILD_DEPS=1
				shift
				;;
			--build-target)
				BUILD_TARGET="$2"
				shift 2
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				echo "unknown option: $1" >&2
				usage >&2
				exit 2
				;;
		esac
	done
}

main() {
	parse_args "$@"

	mkdir -p "${LOG_DIR}" "${WORKDIR}" "${OUT_DIR}"
	BUILD_LOG="${LOG_DIR}/build-kernel-5290-$(date +%Y%m%d-%H%M%S).log"
	STATE_DIR="${WORKDIR}/.state"
	DOWNLOAD_DIR="${WORKDIR}/downloads"
	mkdir -p "${STATE_DIR}" "${DOWNLOAD_DIR}"

	detect_source_package
	resolve_source_version
	derive_version_plan

	SOURCE_TREE="${WORKDIR}/${SOURCE_PACKAGE}-${SOURCE_VERSION}"

	if [[ "${DO_CLEAN}" -eq 1 ]]; then
		log "cleaning ${SOURCE_TREE} and ${DOWNLOAD_DIR}"
		rm -rf "${SOURCE_TREE}" "${DOWNLOAD_DIR}" "${STATE_DIR}"
		mkdir -p "${STATE_DIR}" "${DOWNLOAD_DIR}"
	fi

	log "source package: ${SOURCE_PACKAGE}"
	log "source version: ${SOURCE_VERSION}"
	log "package version: ${TARGET_SOURCE_VERSION}"
	log "abi release: ${ABI_RELEASE}"
	if [[ -n "${KERNEL_REF}" ]]; then
		log "kernel-ref alias used: ${KERNEL_REF}"
	fi

	if [[ "${DO_COLLECT_DEBUG}" -eq 1 ]]; then
		"${ROOT_DIR}/scripts/collect-debug-info.sh" baseline >> "${BUILD_LOG}" 2>&1 || true
	fi

	install_build_deps
	download_source_archives
	extract_source_tree
	apply_local_abi_policy
	prepare_config
	apply_patches
	run_menuconfig_if_requested
	apply_packaging_workarounds
	build_debs
	collect_artifacts
	install_kernel_if_requested
	post_build_summary
}

main "$@"
