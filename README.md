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
- An SSH public key (the default is `~/.ssh/id_ed25519.pub`)

## Quick start

```bash
cp vm.conf.example vm.conf   # optional: edit the settings
./build.sh
./boot-ubuntu-microvm.sh bzImage image.raw
ssh -p 2222 127.0.0.1
```

`build.sh` downloads Ubuntu Base and checks it against Ubuntu's published
SHA256 checksum. Then it builds the kernel (`bzImage`) and the root filesystem
image (`image.raw`). Steps whose output already exists are skipped, so delete
an output to rebuild it.

The image contains systemd, SSH, and DHCP networking, plus a guest user with
the same name as your host user. That user logs in over SSH with your key and
has passwordless sudo. The kernel is Linux 6.18.x with no modules, built from
Firecracker's guest configuration. All drivers needed to boot (VirtIO MMIO,
block, network, console, and Btrfs/Zstd) are built in.

By default the VM runs in the background with 4 vCPUs and 8 GB of RAM, and SSH
is forwarded to `127.0.0.1:2222`. Set `MICROVM_SSH_PORT` in `vm.conf` to use a
different port; `build.sh` prints the matching boot and SSH commands. A
different port per VM lets you run several VMs at once. To shut the VM
down, run `ssh -p 2222 127.0.0.1 sudo poweroff`.

## Configuration

`build.sh` reads `vm.conf`, or the file given as its argument. See
[vm.conf.example](vm.conf.example). The same settings can be set as
environment variables, which take precedence over the file. The individual
scripts also read the user, hostname, package, provisioning, build directory,
and job settings. Run any script with `--help` for details.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MICROVM_KERNEL` | `bzImage` | Kernel output path |
| `MICROVM_IMAGE` | `image.raw` | Image output path |
| `MICROVM_IMAGE_SIZE` | `8G` | Image size (the file is sparse) |
| `MICROVM_UBUNTU_VERSION` | `26.04.1` | Ubuntu Base release |
| `MICROVM_KERNEL_VERSION` | `6.18.59` | Linux 6.18.x release |
| `MICROVM_USER` | your user name | Guest user name |
| `MICROVM_HOSTNAME` | `ubuntu-microvm` | Guest hostname |
| `MICROVM_SSH_KEY` | `~/.ssh/id_ed25519.pub` | Public key(s) allowed to log in |
| `MICROVM_SSH_PORT` | `2222` | Host port forwarded to the guest's SSH server |
| `MICROVM_PACKAGES` | none | Extra Ubuntu packages, separated by spaces |
| `MICROVM_PROVISION_DIR` | none | Directory of provisioning scripts (see below) |
| `MICROVM_BUILD_DIR` | `./build` | Downloads, kernel build cache, and temporary files |
| `MICROVM_KERNEL_JOBS` | number of CPUs | Parallel kernel compile jobs |

The boot script uses these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MICROVM_MEMORY` | `8G` | Guest RAM |
| `MICROVM_CPUS` | `4` | Number of vCPUs |
| `MICROVM_CONSOLE` | `virtio` | `virtio` or `serial` (shows early boot logs) |
| `MICROVM_DAEMON` | `1` | Set to `0` to run in the foreground |
| `MICROVM_RUNTIME_DIR` | `$XDG_RUNTIME_DIR/ubuntu-microvm-PORT` | Console socket, PID file, and log |

### Provisioning scripts

Set `MICROVM_PROVISION_DIR` to a directory of `*.sh` scripts. They run as
root inside the guest, in name order, after the base system is set up. They
have network access, so they can use `apt-get install`. They also get
`MICROVM_USER` and `MICROVM_HOSTNAME` as environment variables. Files they
create in the user's home directory should be owned by that user.

[provision.d.example](provision.d.example) has an example script that
installs a few tools and sets up the user's shell. To use it:

```bash
cp -r provision.d.example provision.d   # then edit or add scripts
echo 'MICROVM_PROVISION_DIR=provision.d' >>vm.conf
./build.sh
```

## Individual steps

`build.sh` runs these scripts, which can also be used on their own:

```bash
./build-microvm-kernel.sh 6.18.59 ./bzImage
./prepare-ubuntu-rootfs.sh ubuntu-base-26.04.1-base-amd64.tar.gz image.raw 8G ~/.ssh/id_ed25519.pub
./boot-ubuntu-microvm.sh ./bzImage ./image.raw
```

## Post-installation ideas

- Install and enable [bees](https://github.com/Zygo/bees) for background Btrfs
  deduplication.
