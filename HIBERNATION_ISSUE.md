# Dell 5290 Camera Hibernate Issue

This note records the Dell Latitude 5290 2-in-1 hibernate investigation so the
same dead ends are not repeated later.

## Symptom

The cameras worked after a fresh boot and after normal suspend/resume, but
failed after hibernate/restore.  Typical userspace symptoms were:

- `cam -l` could still enumerate cameras in some cases.
- GStreamer/libcamera failed when starting capture.
- PipeWire could crash when an application such as Cheese tried to open the
  camera after hibernate.
- Reboot restored camera operation.

Representative kernel/user-space signatures:

```text
ov5670_start_streaming failed to set powerup registers
Failed to queue buffer 0: Input/output error
dw9714 ... I2C write fail
libcamera::V4L2VideoDevice::streamOff() assertion "cache_->isEmpty()"
```

## Working Fix

The working fix is in:

- `0903-5290-tps68470-restore-i2c-bridge-after-hibernate.patch`
- `0904-5290-tps68470-replay-child-state-after-hibernate.patch`

After S4 restore, the TPS68470 PMIC remains visible on I2C, but the downstream
camera child state is partially lost.  Restoring only the secondary I2C bridge
is not enough.  The working sequence also replays the TPS68470 static clock
setup, regulator selector values and camera GPIO sleep-state before enabling the
secondary I2C bridge.

Successful hibernate recovery logs:

```text
Dell 5290 2-in-1 restored TPS68470 S_I2C_CTL=0x03 after hibernate
```

The final patch intentionally does not dump all TPS68470 registers on every
restore.  Those dumps were useful for diagnosis, but too noisy for the working
patch set.

## Hypotheses Tried

✅ Replay TPS68470 child state after hibernate

This fixed the issue.  Diagnostic dumps showed that S4 restore lost important
TPS68470 child state, including secondary I2C, GPIO mode/output, clock and
regulator selector registers.  Replaying the child state made both cameras work
again after hibernate.

❌ Treat it as a userspace device-busy problem

`fuser`/`lsof` did catch real userspace holders in some sessions, especially
PipeWire/WirePlumber and browsers.  Closing those processes helped with normal
`Device or resource busy` cases, but did not fix post-hibernate capture
failures where the kernel device state was already bad.

❌ Reset media graphs with `media-ctl -r`

Resetting `/dev/media0` and `/dev/media1` is still useful before tests, but it
only clears media graph links.  It cannot restore TPS68470 PMIC child state
lost across S4.

❌ Restart PipeWire/WirePlumber

Restarting PipeWire and WirePlumber can release userspace handles and avoid
portal/browser interference.  It did not repair the hibernate failure because
the sensor/PMIC state below libcamera was wrong.

❌ Use loopback-only mode as the kernel fix

The V4L2 loopback workflow is good for Zoom, Telegram and browsers because it
keeps applications away from the physical IPU3 cameras.  It is not a kernel
hibernate fix: `run-cam.sh` still needs one physical camera to start correctly
after restore.

❌ Make DW9714 system sleep best-effort only

Making DW9714 system suspend/resume best-effort helped prevent lens I2C errors
from aborting machine sleep.  It did not restore OV sensor capture after
hibernate because the missing state was in TPS68470 child configuration.

❌ Retry OV5670 streaming and extend power-up delays

Retries and longer settle delays reduced one class of front-camera startup
fragility, but did not solve the S4 failure.  After hibernate the hardware state
needed to be replayed before sensor streaming was attempted.

❌ Restore only TPS68470 `VSIOVAL` and `S_I2C_CTL`

This was a useful intermediate step and proved that the secondary I2C bridge was
part of the problem.  It was insufficient because S4 also lost clock, regulator
selector and camera GPIO child state.

❌ Reinitialize or soft-reset the whole TPS68470 PMIC after S4

This was not the winning approach.  A broad PMIC reset risks disturbing child
devices and did not match the observed failure: the PMIC itself stayed reachable
while specific child state was lost.  Targeted child-state replay is smaller and
matched the successful diagnostic evidence.

## Practical Guidance

- If cameras fail after hibernate, first confirm that the booted kernel contains
  `0903` and `0904`.
- If applications report busy devices, collect `fuser`/`lsof` before rebooting;
  userspace holders are a separate problem from the S4 PMIC-state issue.
- Do not remove the loopback-only workflow.  It remains the most predictable
  desktop integration path even though the kernel hibernate issue is fixed.
- If importing newer upstream 5285 work, keep the 5290 hibernate replay logic as
  a separate local patch until an upstream-equivalent solution exists.
