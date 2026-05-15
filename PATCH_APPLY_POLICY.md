# Patch Apply Policy

This document defines how to maintain, test, and evolve a patch stack for a
vendor/distribution kernel source package.  The goal is to make patch work
repeatable, bisectable, and safe when the same tree is reused for many
incremental rebuilds.

The examples refer to this repository, but the policy is intentionally generic
enough for other projects that need to maintain a mixed stack of upstream
backports, board-specific fixes, and experiments.

## Goals

- Keep the final patch stack reproducible from a clean upstream source tree.
- Keep upstream/imported patches separate from local changes.
- Make each patch layer easy to review and drop independently.
- Avoid relying on a dirty build tree as the source of truth.
- Detect when a patch stack requires a clean rebuild instead of trying unsafe
  in-place patch surgery.
- Preserve fast `--reuse-build` cycles for adding new patches on top.

## Source Of Truth

The canonical source of truth is:

- `patches/series`
- every patch file listed in `patches/series`
- the exact upstream source package/version used for extraction
- the build script logic that applies the series

The expanded kernel tree under `work/` is not source of truth.  It is a build
artifact.  It may contain generated packaging state, compiled objects, and
partial state from failed experiments.

If behavior differs between a clean tree and `work/`, trust the clean tree.

## Patch Layers

Patch filenames must make their layer obvious.  Use numeric prefixes so the
order is deterministic and reviewable.

Recommended ranges:

- `0000-0099`: upstream backports or patch-equivalent imports
- `0100-0199`: board/platform enablement required for basic functionality
- `0200-0299`: stable local fixes validated on hardware
- `0300-0799`: optional features or support-package related kernel changes
- `0800-0899`: diagnostics that should normally not ship permanently
- `0900-0999`: experiments under active testing

This project currently uses:

- `0001-*`: upstream-style backport for TPS68470 clock consumers
- `0100-*`: Dell 5290 base enablement
- `0200-*`: system sleep robustness fixes
- `0900-*`: hibernate and camera recovery experiments

Avoid mixing layers in one patch.  For example, do not combine an upstream
backport with a Dell-only workaround.  Put the upstream part first, then add a
separate local patch on top.

## Upstream vs Local Changes

Upstream or imported patches should remain as close as practical to their
source:

- Keep upstream commit message/context when available.
- Avoid local edits inside the imported patch unless required for backporting.
- If a backport needs adaptation, keep the adaptation minimal and document it in
  the patch header or repository notes.
- Put local policy, quirks, and experiments in a later patch.

Local patches should be explicit about scope:

- Use board names in the filename for board-specific changes, for example
  `5290-*`.
- Gate machine-specific runtime behavior with DMI/ACPI checks when possible.
- Avoid making a board workaround look like a generic driver fix unless it has
  been validated as generic.

When a newer upstream patch becomes available, prefer replacing the local
approximation with the upstream version and then reapplying any still-needed
local delta on top.

## Editing Existing Patches

Editing an already-applied patch is dangerous in a reused build tree.

Allowed without clean rebuild:

- Add a new patch at the end of `patches/series`.
- Add a pure documentation file outside the kernel tree.
- Update build scripts or support tooling.

Requires clean rebuild:

- Modify a patch that was already applied to the current `work/` tree.
- Reorder existing patches.
- Delete an existing patch from the middle of the stack.
- Squash multiple already-applied patches.
- Change an upstream/source version.

Reason: once later patches touch the same hunks, `patch --reverse --dry-run` is
not a stable test for whether an earlier patch is applied.  A reused tree can no
longer safely reconstruct the middle of the patch stack.

The build script must fail clearly when a previously recorded patch checksum
changes and tell the developer to rebuild with `--clean`.

## Applying Patches In Reuse Builds

For fast development, a reused tree is acceptable only when appending new
patches on top of the existing stack.

The build script should:

1. Calculate checksums for every patch in `patches/series`.
2. Compare those checksums with the recorded state in `work/.state/patches.applied`.
3. Skip patches that are already recorded with the same checksum.
4. Stop with an explicit error if a recorded patch filename exists but its
   checksum changed.
5. Apply only new patches that are not in the recorded state.
6. Record the full current patch fingerprint after successful application.

For new patches, the script should prefer this order:

1. `patch --forward --dry-run`
2. `patch --forward`
3. only if forward dry-run fails, try `patch --reverse --dry-run` as a fallback
   to detect a manually applied patch
4. otherwise fail

Do not run reverse checks for every old patch during normal reuse.  That creates
false failures when later patches modified the same area.

## Clean Tree Consistency Check

Before trusting a non-trivial patch stack change, verify it from a clean source
tree.

Recommended workflow:

```bash
tmpdir="$(mktemp -d work/patch-test-clean.XXXXXX)"
cd "$tmpdir"
dpkg-source -x ../downloads/linux-hwe-6.17_6.17.0-23.23~24.04.1.dsc src
cd src
while IFS= read -r patch_file; do
    [ -n "$patch_file" ] || continue
    patch -p1 --forward < "/path/to/repo/patches/$patch_file"
done < /path/to/repo/patches/series
```

The exact source version must match the intended build source version.  If the
clean check succeeds but `work/` fails, the build tree is dirty or stale.  Use a
clean rebuild or create a new build tree.

## Consistency Checklist

Run these checks before committing patch stack changes:

- `git status --short --branch`
- `git diff --check`
- `git diff --staged --check`
- apply the full `patches/series` to a clean extracted source tree
- verify the build script can apply new patches with `--reuse-build --no-build`
- inspect the generated log for rejected hunks or unexpected prompts
- ensure no `*.rej` files exist in the build tree

Useful commands:

```bash
find work -name '*.rej' -print
find work -name '*.orig' -print
git diff -- patches/series patches/*.patch
```

Patch files are allowed to contain context lines that `git diff --check` reports
as whitespace warnings when the patch itself is staged.  Treat warnings inside
`.patch` files carefully: they may be literal patch context, not code
whitespace.  Still fix malformed patch formatting, trailing junk, and accidental
editor artifacts.

## Build Tree Hygiene

Do not manually edit files under `work/` and then treat the result as final.
Manual edits in `work/` are acceptable only as a temporary way to generate or
debug a patch.

After manual testing:

1. Convert the change into a patch under `patches/`.
2. Add it to `patches/series`.
3. Reverse the manual edit or recreate the build tree.
4. Verify the patch applies to a clean tree.

If a failed patch run leaves reject files:

```bash
find work -name '*.rej' -print
```

Do not continue a build while reject files are present.  Inspect them, fix the
patch or clean the tree, and rerun.

## Commit Policy

Keep commits small and separated by purpose:

- one commit for a kernel patch or a small group of inseparable kernel patches
- one commit for build-script behavior
- one commit for documentation
- one commit for test tooling

Do not mix a kernel experiment with build infrastructure fixes unless the build
fix is required to make that exact patch apply.

Use conventional commit subjects, for example:

- `fix(kernel): replay TPS68470 state after hibernate`
- `fix(build): skip recorded patches during reuse`
- `docs: document patch apply policy`

Before committing, inspect staged content:

```bash
git diff --staged --stat
git diff --staged
git diff --staged --check
```

The commit message must describe the staged change, not unstaged work or the
intended next step.

## Failure Modes

Common failure: an old patch fails after adding a new patch.

Likely cause: the script rechecked an old patch with `patch --reverse --dry-run`
after later patches changed the same hunk.

Correct response: use recorded patch checksums and apply only new patches in
reuse mode.  If an existing patch changed, rebuild clean.

Common failure: `Unreversed patch detected` appears in logs.

Likely cause: reverse checking was attempted before forward checking, or a patch
is already partially applied.

Correct response: prefer forward dry-run for new patches and use reverse dry-run
only as fallback.  If partial state exists, clean the tree.

Common failure: clean tree applies but build tree fails.

Likely cause: dirty `work/` tree.

Correct response: do not debug the patch first.  Recreate or clean the build
tree, then retry.

Common failure: build tree applies but clean tree fails.

Likely cause: the patch depends on uncommitted or manually applied state.

Correct response: regenerate the patch against the correct base and verify the
entire `series` from a clean source tree.

## Promotion From Experiment To Stable

Experimental patches should remain in the `0900-*` range until validated.

When an experiment is proven useful:

1. Move or recreate it in the stable local range, for example `0200-*`.
2. Keep the old experimental patch out of `series`.
3. Re-verify from a clean tree.
4. Tag or document the known-good commit if it is a meaningful hardware-tested
   milestone.

Do not tag commits that only represent failed experiments unless the tag name
clearly says they are failed diagnostic checkpoints.

## Release Readiness

A patch stack is release-ready when:

- it applies from a clean source tree without rejects
- it builds from clean source
- it supports `--reuse-build` for appending new patches
- failed experiments are not mixed into the stable layer
- hardware test results are documented
- installation instructions point to the exact source version and ABI
- the resulting runtime behavior is reproducible after reboot
