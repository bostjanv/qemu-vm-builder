# QEMU VM Builder

Scripts for building small, fast-booting Ubuntu VMs for QEMU/KVM. The VM uses
QEMU's `microvm` machine type, a custom kernel with everything built in, and a
raw disk image with a Btrfs root filesystem. The image has no partitions,
bootloader, or initramfs. QEMU boots the kernel directly.

Everything runs as your normal user, without sudo. The image is provisioned
inside an unprivileged user namespace, and the VM uses QEMU user-mode
networking, so the host system and network are not changed.

## Requirements

- An x86-64 Linux host with KVM access (`/dev/kvm`) and `qemu-system-x86_64`
- Kernel build tools: `gcc`, `make`, `bc`, `bison`, `flex`, `perl`, `curl`,
  `xz`, and the libelf and OpenSSL development headers
- Image build tools: `unshare` (util-linux 2.38 or newer), `newuidmap` and
  `newgidmap` (the `shadow` or `uidmap` package), `btrfs-progs`, `systemctl`,
  `tar`, and `gzip`
- A subordinate UID/GID range for your user in `/etc/subuid` and `/etc/subgid`
  (most distributions create one with the account)
- An Ubuntu Base tarball, such as `ubuntu-base-26.04.1-base-amd64.tar.gz` from
  <https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/>
- An SSH public key (the default is `~/.ssh/id_ed25519.pub`)

## Quick start

### 1. Build the root filesystem image

```bash
./prepare-ubuntu-rootfs.sh ubuntu-base-26.04.1-base-amd64.tar.gz image.raw 8G ~/.ssh/id_ed25519.pub
```

This creates a sparse raw image with systemd, SSH, and DHCP networking. It
also creates a guest user with the same name as your host user. That user has
passwordless sudo and logs in over SSH with your key. The size argument
defaults to `2G`.

### 2. Build the kernel

```bash
./build-microvm-kernel.sh 6.18.59 ./bzImage
```

This downloads Linux 6.18.x and builds a kernel with no modules, starting from
Firecracker's guest configuration. All drivers needed to boot (VirtIO MMIO,
block, network, console, and Btrfs/Zstd) are built in.

### 3. Boot the VM

```bash
./boot-ubuntu-microvm.sh ./bzImage ./image.raw
```

By default the VM runs in the background with 4 vCPUs and 8 GB of RAM, and SSH
is forwarded to `127.0.0.1:2222`. A third argument sets a different SSH port,
which also lets you run several VMs at once. The script prints the paths of the
console socket and log.

### 4. Connect and shut down

```bash
ssh -p 2222 127.0.0.1
ssh -p 2222 127.0.0.1 sudo poweroff
```

## Customization

All scripts accept these environment variables. Run any script with `--help`
for details.

| Variable | Used by | Default | Purpose |
| --- | --- | --- | --- |
| `MICROVM_BUILD_DIR` | rootfs, kernel | `./.microvm-build` | Kernel source and build cache, and temporary rootfs files |
| `MICROVM_USER` | rootfs, boot | your user name | Guest user name |
| `MICROVM_HOSTNAME` | rootfs | `ubuntu-microvm` | Guest hostname |
| `MICROVM_PACKAGES` | rootfs | none | Extra Ubuntu packages, separated by spaces |
| `MICROVM_KERNEL_JOBS` | kernel | number of CPUs | Parallel compile jobs |
| `MICROVM_MEMORY` | boot | `8G` | Guest RAM |
| `MICROVM_CPUS` | boot | `4` | Number of vCPUs |
| `MICROVM_CONSOLE` | boot | `virtio` | `virtio` or `serial` (shows early boot logs) |
| `MICROVM_DAEMON` | boot | `1` | Set to `0` to run in the foreground |
| `MICROVM_RUNTIME_DIR` | boot | `$XDG_RUNTIME_DIR/ubuntu-microvm-PORT` | Console socket, PID file, and log |

Example:

```bash
MICROVM_HOSTNAME=devbox MICROVM_PACKAGES='git vim curl' \
    ./prepare-ubuntu-rootfs.sh ubuntu-base-26.04.1-base-amd64.tar.gz devbox.raw 16G
```

## Post-installation ideas

- Install and enable [bees](https://github.com/Zygo/bees) for background Btrfs
  deduplication.
