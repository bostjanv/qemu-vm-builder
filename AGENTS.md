# AGENTS.md

Bash scripts that build a fast-booting Ubuntu VM for QEMU's `microvm` machine:
a custom kernel (`bzImage`) plus a partitionless Btrfs raw image (`image.raw`).
Read [README.md](README.md) for usage and every setting.

## Layout

- `build.sh` reads `vm.conf` (env vars override it), downloads and checks
  Ubuntu Base, then runs the two build scripts. Steps whose output exists are
  skipped.
- `build-microvm-kernel.sh` builds Linux 6.18.x from Firecracker's pinned guest
  config. `CONFIG_MODULES=n`, no initramfs: everything needed to boot is built
  in, and the script fails if `olddefconfig` drops a required option.
- `prepare-ubuntu-rootfs.sh` provisions the rootfs in an unprivileged user
  namespace and runs `mkfs.btrfs --rootdir`. Code inside the `GUEST` heredoc
  and `run_chroot` runs in the guest chroot; the rest runs on the host.
- `boot-ubuntu-microvm.sh` boots the VM with user-mode networking (SSH on
  `127.0.0.1:MICROVM_SSH_PORT`).
- `vm.conf.example` and `provision.d.example/` are templates that users copy
  to `vm.conf` and `provision.d/`.

## Design constraints

- Never require root. Scripts refuse to run as root or under fakeroot. The
  rootfs build uses `unshare --user --map-auto --map-root-user`, so guest files
  are owned by subordinate IDs; delete them inside the namespace (see
  `cleanup`). No device nodes can be created, so `/dev` stays empty and the
  kernel's devtmpfs provides it.
- Don't change the host network or system: no TAP, bridges, or installed files.
- Never overwrite outputs. Build into a temp file and publish it atomically.
- Keep `x-option-roms=on` in the boot script: direct `-kernel` boot needs it
  because the disk has no bootloader.
- New kernel features must be built in (`=y`) and added to the script's
  required-option check. The guest has no `modprobe`.
- New settings are `MICROVM_*` variables. Document them in the script's
  `--help`, the README tables, and `vm.conf.example`. Don't invent defaults
  the user didn't ask for.

## Shell style

Match the existing scripts: `#!/usr/bin/env bash`, `set -Eeuo pipefail`,
`die`/`log` helpers printing to stderr, a `usage` heredoc for `-h`/`--help`,
exit code 2 on usage errors, `[[ ]]`, `--` before path arguments, and regex
validation of user-supplied values.

## Verifying changes

There is no test suite or CI.

- Always: `bash -n`, `shellcheck`, and `--help` on every changed script.
- Rootfs changes: build a scratch image in a git-ignored directory with a
  throwaway key, for example `ssh-keygen -q -t ed25519 -N '' -f DIR/testkey`.
  Inspect the image without root using
  `btrfs restore --path-regex … IMAGE OUTDIR` to read files and
  `btrfs inspect-internal dump-tree -t fs IMAGE` for ownership and modes.
  Remove scratch files afterwards.
- Booting needs `/dev/kvm`. If it is unavailable, say the VM was not booted
  instead of claiming the boot works; the user boots it himself.
- Reuse `build/` (Ubuntu Base download, kernel cache) instead of rebuilding.
  Don't move `build/kernel-*/build`; it contains absolute paths.
- `update-alternatives` warnings about missing man pages during the build are
  harmless.

## Git

- The user edits files between turns. Check `git status` and diffs first and
  keep his changes.
- Commit subjects are imperative, with a short bulleted body when useful.
- Push through gh only when asked:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push`.
