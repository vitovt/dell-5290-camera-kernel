# Dell Latitude 5290 2-in-1 camera kernel task

This workspace adapts the Dell Latitude 5285 camera enablement series to
`Latitude 5290 2-in-1` and uses the Ubuntu source-package workflow instead of
cloning the full upstream kernel tree.

## Chosen workflow

The current host runs Ubuntu/KDE neon kernel `6.17.0-19-generic`, which maps to
the Ubuntu HWE source package family `linux-hwe-6.17`. The automation here is
built around:

1. Downloading the matching Ubuntu source package metadata and tarballs.
2. Extracting the source locally.
3. Applying only the local `patches/0001` .. `0005` patch set.
4. Optionally running Ubuntu's interactive config editor.
5. Building Ubuntu-native `.deb` packages.

This keeps the packaging close to the target distro and avoids downloading the
entire upstream git history just to carry a 5-patch local delta.

For the currently tested `linux-hwe-6.17` amd64 packaging on this host, the
automation also applies a local packaging workaround that flips
`do_tools_perf_jvmti` off if Ubuntu's HWE rules enable it but `perf` does not
actually emit `libperf-jvmti.so`. This workaround is outside the camera patch
set and only affects packaging of the perf JVMTI helper.

## Important caveat

This workspace was prepared on a non-target machine. The live host here reports
`HP 250 G7 Notebook PC`, not `Dell Latitude 5290 2-in-1`. That means:

- Source download, patch preparation, script validation, and package build can
  be done here.
- Real camera bring-up validation must be run on the actual Dell hardware.

## Layout

- `patches/`: local 5290 patch set
- `scripts/build-kernel-5290.sh`: Ubuntu-source package automation
- `scripts/collect-debug-info.sh`: baseline and post-patch diagnostics capture
- `scripts/validate-cameras.sh`: focused camera validation commands
- `scripts/unpack-dell-camera-drivers.sh`: helper for Dell Windows packages
- `out/`: built `.deb` artifacts
- `logs/`: build and diagnostic logs
- `results/`: captured runtime diagnostics

## Suggested execution order

1. Run `scripts/collect-debug-info.sh baseline`.
2. Run `scripts/build-kernel-5290.sh --collect-debug`.
3. Install the built `.deb` packages on the Dell machine.
4. Reboot into the patched kernel.
5. Run `scripts/validate-cameras.sh`.
6. If needed, compare `results/baseline/` vs `results/post-patch/`.

## Notes about Ubuntu source selection

The script defaults to `linux-hwe-6.17` when it detects a `6.17.*` running
kernel. It downloads the latest available source stanza from `apt-cache
showsrc`, which may be newer than the currently booted point release. That is
acceptable for a local forward-port workflow, but the exact source version can
be pinned with `--source-version`.
