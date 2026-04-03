# Dell Latitude 5290 2-in-1 Camera Kernel

## Problem

Dell Latitude 5290 2-in-1 devices can ship with an Intel IPU-based camera stack
that does not work with the stock Ubuntu kernel out of the box. The missing
pieces are not a single userspace package or one BIOS toggle: the kernel needs
several platform and camera-driver patches so the camera sensors, power
sequencing and IPU bridge are detected correctly.

This repository contains:

- a small patch set adapted for the Dell Latitude 5290 2-in-1
- a build script that uses Ubuntu kernel source packages instead of a full
  upstream kernel git checkout
- helper scripts for diagnostics and validation

The build script rewrites the Ubuntu ABI to a custom local ABI by default
(`999`), so the resulting `.deb` packages do not conflict with the stock Ubuntu
kernel packages already installed on your machine.

Important:

- The built kernel package is `linux-image-unsigned-...`, so Secure Boot should
  be disabled unless you plan to sign the kernel yourself.
- Kernel compilation is large and slow. Expect many hours on older hardware and
  make sure you have plenty of free disk space.

## Build And Install

This section is written for a user who just wants to build and install the
patched kernel with as little decision-making as possible.

### 1. Open a terminal in this repository

```bash
cd /home/vitovt/Desktop/Dev/DELL5290/dell-5290-camera-kernel
```

### 2. Make sure Secure Boot is off

This repository builds an unsigned kernel image. If Secure Boot is enabled, the
system may refuse to boot the custom kernel.

Optional check:

```bash
mokutil --sb-state || true
```

If it says Secure Boot is enabled, turn it off in UEFI/BIOS before continuing.

### 3. Build the patched kernel

Run this exact command:

```bash
./scripts/build-kernel-5290.sh --install-build-deps --collect-debug
```

What this does:

- installs missing build dependencies with `apt`
- downloads the matching Ubuntu kernel source package
- applies the local camera patch set
- changes the Ubuntu ABI to a local custom ABI (`999`) so the packages do not
  collide with the stock Ubuntu kernel
- reuses previous build artifacts automatically when possible
- prints the exact `sudo dpkg -i ...` command at the end if the build succeeds

Notes:

- You do not need to choose the kernel version manually. The script detects the
  right Ubuntu kernel source family and picks the source version automatically.
- If the build stops because of a temporary error, fix the problem and rerun the
  same command. The default behavior is to reuse the existing work tree instead
  of starting from zero.
- If `apt build-dep` complains about missing source repositories (`deb-src`),
  enable source repositories in your Ubuntu software sources and then rerun the
  same command.

### 4. Install the built kernel packages

At the end of a successful build, the script prints a ready-to-run command that
starts with:

```bash
sudo dpkg -i ...
```

Copy that command exactly and run it.

Then run:

```bash
sudo apt -f install
```

Do not use:

```bash
sudo dpkg -i *
```

That installs unrelated helper packages too and is the easiest way to create
dependency noise or package-name conflicts.

### 5. Reboot

```bash
sudo reboot
```

### 6. Confirm that the custom kernel is running

After reboot:

```bash
uname -r
```

You should see a custom ABI such as:

```text
6.17.0-999-generic
```

The important part is that it should be your custom ABI, not the stock Ubuntu
ABI that was previously installed.

### 7. Check the cameras

Run:

```bash
./scripts/validate-cameras.sh
```

If you want to save a before/after comparison, the build step above already
captured baseline debug information with `--collect-debug`.

## If You Already Installed A Wrong Same-Name Kernel

Older local builds that reused the stock Ubuntu ABI, for example `...-20`,
could conflict with the official Ubuntu packages because the package names were
the same.

If that happened earlier, first restore the stock Ubuntu packages:

```bash
sudo apt -f install
sudo apt install --reinstall linux-image-generic linux-headers-generic linux-generic
```

Then build again with the repository default workflow:

```bash
./scripts/build-kernel-5290.sh --install-build-deps
```

The current script defaults to a custom ABI, so new packages should be created
with a non-conflicting version such as `6.17.0-999-generic`.

## Advanced Notes

### Common useful commands

Reuse the existing build tree and only rerun packaging:

```bash
./scripts/build-kernel-5290.sh --reuse-build
```

Force a full clean rebuild:

```bash
./scripts/build-kernel-5290.sh --clean
```

Print the install command again without rebuilding:

```bash
./scripts/build-kernel-5290.sh --no-build --print-install-command
```

Pick a different custom ABI:

```bash
./scripts/build-kernel-5290.sh --local-abi 998
```

Keep the stock Ubuntu ABI anyway:

```bash
./scripts/build-kernel-5290.sh --no-local-abi
```

This is not recommended. It can produce package names that collide with the
official Ubuntu kernel packages already installed on the system.

### Repository layout

- [patches](/home/vitovt/Desktop/Dev/DELL5290/dell-5290-camera-kernel/patches): local 5290 patch set
- [scripts/build-kernel-5290.sh](/home/vitovt/Desktop/Dev/DELL5290/dell-5290-camera-kernel/scripts/build-kernel-5290.sh): main build automation
- [scripts/collect-debug-info.sh](/home/vitovt/Desktop/Dev/DELL5290/dell-5290-camera-kernel/scripts/collect-debug-info.sh): baseline diagnostics
- [scripts/validate-cameras.sh](/home/vitovt/Desktop/Dev/DELL5290/dell-5290-camera-kernel/scripts/validate-cameras.sh): post-boot camera checks
- [README-task.md](/home/vitovt/Desktop/Dev/DELL5290/dell-5290-camera-kernel/README-task.md): original task-oriented notes

### Credits

- The patch set here adapts Dell Latitude 5285 camera enablement work to the
  Dell Latitude 5290 2-in-1.
- The build flow is intentionally based on Ubuntu source packages and Ubuntu
  packaging rules instead of a raw upstream kernel build.

### References

- Canonical kernel docs: https://canonical-kernel-docs.readthedocs-hosted.com/latest/how-to/develop-customise/build-kernel/
- Ubuntu wiki note about custom Ubuntu kernel builds: https://wiki.ubuntu.com/Kernel/BuildYourOwnKernel
- Current repository revision while writing this README: `3beee47`
