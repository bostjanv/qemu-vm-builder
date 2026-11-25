# QEMU VM Builder

Scripts for building small, fast-booting Debian VMs for QEMU/KVM. The VM uses
QEMU's `microvm` machine type, a custom kernel with everything built in, and a
raw disk image with a Btrfs root filesystem. The image has no partitions,
bootloader, or initramfs. QEMU boots the kernel directly.

The goal is to minimize boot time and disk usage:

- **Boot time:** the `microvm` machine uses VirtIO MMIO devices instead of
  PCI, and the boot script turns off legacy devices (PIT, PIC, RTC). QEMU
  starts the kernel directly, and the kernel has no modules or initramfs to
  load, so it mounts the root filesystem straight away.
- **Disk usage:** the image is a sparse file, so unused space takes no room on
  the host. The root filesystem is Btrfs, chosen for its space-saving
  features. Data is compressed with Zstd, both when the image is built and
  when the guest writes later. Btrfs can also store identical data only once:
  copies made with `cp --reflink` share their data, and a deduplication tool
  such as [bees](https://github.com/Zygo/bees) can merge duplicates that
  already exist (see [Provisioning scripts](#provisioning-scripts)).

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
- For changing the scripts: `shellcheck`

## Quick start

```bash
cp vm.conf.example vm.conf   # optional: edit the settings
./build.sh
./boot-debian-microvm.sh build/bzImage build/image.raw
ssh -p 2222 127.0.0.1
```

`build.sh` downloads the root filesystem of Debian's official Docker image
(built by [debuerreotype](https://github.com/debuerreotype/debuerreotype)) and
checks it against the SHA256 digest in the image's OCI manifest. Then it
builds the kernel (`build/bzImage`) and the root filesystem image
(`build/image.raw`). Steps whose output already exists are skipped, so delete
an output to rebuild it. Debian rebuilds its Docker image regularly with the
latest updates; delete `build/debian-RELEASE-amd64-rootfs.tar.gz` to download
the current one.

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
| `MICROVM_KERNEL` | `MICROVM_BUILD_DIR/bzImage` | Kernel output path |
| `MICROVM_IMAGE` | `MICROVM_BUILD_DIR/image.raw` | Image output path |
| `MICROVM_IMAGE_SIZE` | `8G` | Image size (the file is sparse) |
| `MICROVM_DEBIAN_RELEASE` | `trixie` | Debian release (codename, such as `trixie`, `forky`, or `sid`) |
| `MICROVM_KERNEL_VERSION` | `6.18.63` | Linux 6.18.x release |
| `MICROVM_USER` | your user name | Guest user name |
| `MICROVM_HOSTNAME` | `debian-microvm` | Guest hostname |
| `MICROVM_SSH_KEY` | `~/.ssh/id_ed25519.pub` | Public key(s) allowed to log in |
| `MICROVM_SSH_PORT` | `2222` | Host port forwarded to the guest's SSH server |
| `MICROVM_PACKAGES` | none | Extra Debian packages, separated by spaces |
| `MICROVM_PROVISION_DIR` | none | Directory of provisioning scripts (see below) |
| `MICROVM_BUILD_DIR` | `./build` | Outputs, downloads, kernel build cache, and temporary files |
| `MICROVM_KERNEL_JOBS` | number of CPUs | Parallel kernel compile jobs |
| `MICROVM_KERNEL_USB` | `0` | Set to `1` to build USB support into the kernel (see [USB passthrough](#usb-passthrough)) |

The boot script uses these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MICROVM_MEMORY` | `8G` | Guest RAM |
| `MICROVM_CPUS` | `4` | Number of vCPUs |
| `MICROVM_CONSOLE` | `virtio` | `virtio` or `serial` (shows early boot logs) |
| `MICROVM_DAEMON` | `1` | Set to `0` to run in the foreground |
| `MICROVM_RUNTIME_DIR` | `$XDG_RUNTIME_DIR/debian-microvm-PORT` | Console socket, PID file, and log |
| `MICROVM_USB_DEVICES` | none | Host USB devices to pass through, as `VENDOR:PRODUCT` IDs separated by spaces |
| `MICROVM_MONITOR_SOCKET` | none | Path of a QEMU human monitor (HMP) Unix socket; connect with `socat -,rawer,escape=0x1d UNIX-CONNECT:PATH` |

### Provisioning scripts

Set `MICROVM_PROVISION_DIR` to a directory of `*.sh` scripts. They run as
root inside the guest, in name order, after the base system is set up. They
have network access, so they can use `apt-get install`. They also get
`MICROVM_USER` and `MICROVM_HOSTNAME` as environment variables. Files they
create in the user's home directory should be owned by that user.

[provision.d.example](provision.d.example) has two example scripts:

- `10-dev-tools.sh` installs a few tools and sets up the user's shell.
- `20-bees.sh` builds [bees](https://github.com/Zygo/bees) from source (Debian
  has no package for it) and removes the compilers afterwards. On the first
  boot, it configures bees for the root filesystem, sizing the hash table to
  the filesystem, and enables `beesd@UUID.service` for background
  deduplication. The UUID is only known then, because `mkfs.btrfs` creates it
  after provisioning.

To use them:

```bash
cp -r provision.d.example provision.d   # then edit or add scripts
echo 'MICROVM_PROVISION_DIR=provision.d' >>vm.conf
./build.sh
```

### USB passthrough

The kernel has no USB support by default. To pass a host USB device through
to the VM:

1. Set `MICROVM_KERNEL_USB=1` in `vm.conf`, delete `build/bzImage`, and run
   `./build.sh`. The kernel then has the USB core and the xHCI controller
   that QEMU adds to the `microvm` machine, without PCI.
2. Give your user read/write access to the device on the host. Device nodes
   in `/dev/bus/usb` usually belong to root; a udev rule can grant access,
   for example
   `SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6001", TAG+="uaccess"`
   in `/etc/udev/rules.d/70-microvm-usb.rules` grants it to the user logged
   in at the local seat.
3. Boot with the device's vendor and product ID, as shown by `lsusb`:

   ```bash
   MICROVM_USB_DEVICES=0403:6001 ./boot-debian-microvm.sh build/bzImage build/image.raw
   ```

The boot script stops if the device is connected but not accessible. A
device that is not connected yet is attached when it is plugged in. If
several connected devices have the same IDs, QEMU passes through one of them.

In the guest, the device appears in `/dev/bus/usb`, so programs that use
libusb can drive it. The kernel includes no USB device drivers, such as
USB serial adapters, storage, or keyboards, because modules are disabled;
add the ones you need to `build-microvm-kernel.sh`.

## Individual steps

`build.sh` runs these scripts, which can also be used on their own:

```bash
./build-microvm-kernel.sh 6.18.63 build/bzImage
./prepare-debian-rootfs.sh build/debian-trixie-amd64-rootfs.tar.gz build/image.raw 8G ~/.ssh/id_ed25519.pub
./boot-debian-microvm.sh build/bzImage build/image.raw
```
