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
- a small `dell-5290-camera-support` package that installs the udev rule needed
  for libcamera to access `/dev/dma_heap/system`
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
- builds `dell-5290-camera-support`, which grants the desktop session access to
  `/dev/dma_heap/system` after reboot
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

Copy that command exactly and run it. It should install the runtime kernel
packages, the matching headers and `dell-5290-camera-support`.

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

The important packages in the printed command are:

- `linux-image-unsigned-...`: the custom kernel image
- `linux-modules-...`: base kernel modules
- `linux-modules-extra-...`: extra modules, including patched camera/platform drivers
- `linux-modules-ipu6-...`, `linux-modules-usbio-...`,
  `linux-modules-vision-...`: Ubuntu split module packages used by this kernel
- `linux-modules-iwlwifi-...`: Wi-Fi modules for this ABI
- `linux-headers-...` and `linux-hwe-6.17-headers-...`: headers for DKMS and
  external modules
- `dell-5290-camera-support`: udev rule for `/dev/dma_heap/system`

Other generated packages, such as `linux-tools-*`, `linux-cloud-tools-*`,
`linux-buildinfo-*` and `linux-lib-rust-*`, are optional and are not required
for booting this kernel or using the cameras.

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

The validator resets the media graphs, checks both explicit cameras and writes
logs under `results/post-patch/<timestamp>/`.

For a quick visible smoke test:

```bash
media-ctl -r -d /dev/media0
media-ctl -r -d /dev/media1
gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PCI0.LNK0' ! queue ! videoconvert ! queue ! autovideosink
```

For the back camera:

```bash
media-ctl -r -d /dev/media0
media-ctl -r -d /dev/media1
gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PCI0.LNK1' ! queue ! videoconvert ! queue ! autovideosink
```

If you want to save a before/after comparison, the build step above already
captured baseline debug information with `--collect-debug`.

## Desktop Applications

Applications that use GStreamer/libcamera directly should work with the system
`libcamera` package. The fallback `uncalibrated.yaml` messages are expected for
this hardware and do not prevent the cameras from working.

### Zoom from a `.deb`

Zoom may use either PipeWire/portal integration or direct V4L2 device access,
depending on the version and settings. First try the native cameras in Zoom's
video settings after confirming that the GStreamer tests above work.

If Zoom does not show a usable camera, use a V4L2 loopback device as a virtual
webcam. This is the most predictable bridge for applications that do not handle
libcamera/IPU3 cameras directly:

```bash
sudo apt install v4l2loopback-dkms v4l2loopback-utils
sudo modprobe v4l2loopback video_nr=42 card_label="Dell 5290 Camera" exclusive_caps=1
./run-cam.sh
```

Keep `run-cam.sh` running while Zoom is open, then select `Dell 5290 Camera`
in Zoom.

Use the back camera instead:

```bash
./run-cam.sh back
```

The one-shot `modprobe` command above does not survive reboot. To create
`/dev/video42` automatically on every boot:

```bash
echo v4l2loopback | sudo tee /etc/modules-load.d/dell-5290-camera.conf
printf 'options v4l2loopback video_nr=42 card_label="Dell 5290 Camera" exclusive_caps=1\n' \
  | sudo tee /etc/modprobe.d/dell-5290-camera.conf
```

Reload it immediately without rebooting:

```bash
sudo modprobe -r v4l2loopback
sudo modprobe v4l2loopback
```

Verify:

```bash
v4l2-ctl --list-devices | grep -A3 "Dell 5290 Camera"
ls -l /dev/video42
```

If you do not want to use the helper script, this is the raw front-camera
pipeline:

```bash
gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PCI0.LNK0' ! queue ! videoconvert ! video/x-raw,format=YUY2 ! v4l2sink device=/dev/video42 sync=false
```

### Telegram Flatpak

Telegram Flatpak may not have direct access to host video devices by default.
If it cannot see the camera, grant device access:

```bash
flatpak override --user --device=all org.telegram.desktop
```

Restart Telegram after changing the override.

If Telegram still does not show a usable camera, use the same V4L2 loopback
setup as for Zoom and select `Dell 5290 Camera` inside Telegram.

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

This also refreshes the local `dell-5290-camera-support` package in
`out/<abi-release>/`.

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

### Upstream Status

The original Dell Latitude 5285 work is still moving upstream.  As of
2026-04-28, the latest public series is v6 and it differs from this tested
5290 patch set in a few important ways:

- v6 replaces the early GNVS write workaround with static TPS68470 clock
  consumers in board data.  This is cleaner for upstream, but the local 5290
  kernel still keeps the GNVS fix because it is the path tested on this
  hardware.
- v6 maps OV8858 I/O power through the standard `dovdd` supply and does not
  add a driver-specific `vsio` supply.  The local 5290 patch still requests
  `vsio` explicitly because this setup was tested with the Dell 5290 secondary
  I2C passthrough.
- The local 5290 board data also adds the DW9714 `vcc` regulator consumer for
  `i2c-INT3477:00-VCM`; this fixed repeated VCM I2C failures on the 5290 and
  is not present in the 5285 series.

Do not replace the local patch set with a newer upstream 5285 revision without
rebuilding and retesting both cameras and the virtual-camera bridge.

### References

- Canonical kernel docs: https://canonical-kernel-docs.readthedocs-hosted.com/latest/how-to/develop-customise/build-kernel/
- Ubuntu wiki note about custom Ubuntu kernel builds: https://wiki.ubuntu.com/Kernel/BuildYourOwnKernel
- LKML thread for the original Dell Latitude 5285 camera work: https://lkml.org/lkml/2026/3/19/2413
- Current v6 Dell Latitude 5285 camera series: https://www.spinics.net/lists/kernel/msg6170768.html
- Current repository revision can be checked with `git log --oneline -1`.
