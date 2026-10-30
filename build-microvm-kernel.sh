#!/usr/bin/env bash
# Build an upstream x86-64 Linux kernel for QEMU's `-M microvm` machine.
# Use Firecracker's pinned 6.18 guest config as a small-device baseline,
# removing optional services and adding the QEMU/systemd features we need.
# The root filesystem is a partitionless Btrfs raw disk at /dev/vda. No initramfs,
# bootloader, sudo, host networking changes, or kernel installation is needed.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: build-microvm-kernel.sh [KERNEL_VERSION] [OUTPUT_BZIMAGE]

Examples:
  ./build-microvm-kernel.sh
  ./build-microvm-kernel.sh 6.18.59 ./bzImage
  MICROVM_KERNEL_JOBS=4 ./build-microvm-kernel.sh 6.18.59 ./kernel-microvm

Defaults:
  KERNEL_VERSION       6.18.59 (Linux longterm, released October 2026)
  OUTPUT_BZIMAGE       ./bzImage
  MICROVM_KERNEL_JOBS  Number of available processors
  MICROVM_BUILD_DIR    ./build

The source, pinned Firecracker configuration, and incremental build are kept in:
  MICROVM_BUILD_DIR/kernel-VERSION/

Only 6.18.x kernels are supported: the Firecracker baseline is for Linux 6.18.
The baseline is pinned to Firecracker's public guest kernel configuration;
the script removes optional SCSI/USB, ext4/NFS/XFS/overlay, netfilter and extra
VirtIO transports, while enabling built-in Btrfs/Zstd, systemd and SSH.

Required host tools: curl, tar, xz, gcc, make, bc, bison, flex, perl,
plus the usual Linux kernel development headers/libraries (libelf and libssl).
For Arch Linux, install build dependencies through pacman if needed.

Everything runs as your normal user. Existing output files are never replaced.
This builds only the kernel; it does not boot QEMU or modify the Ubuntu raw image.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*" >&2; }

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
(( $# <= 2 )) || { usage >&2; exit 2; }

(( EUID != 0 )) || die 'run as your ordinary user, without sudo or fakeroot'
[[ -z ${FAKEROOTKEY:-} ]] || die 'do not run under fakeroot'

version=${1:-6.18.59}
output=${2:-./bzImage}
jobs=${MICROVM_KERNEL_JOBS:-}

[[ $version =~ ^6\.18\.[0-9]+$ ]] || \
    die "this Firecracker configuration is intended for Linux 6.18.x (got $version)"
[[ ! -e "$output" && ! -L "$output" ]] || die "output already exists: $output"

for program in curl tar xz gcc make bc bison flex perl awk grep mktemp realpath \
               nproc install ln cp sha256sum; do
    command -v "$program" >/dev/null 2>&1 || die "missing host command: $program"
done
[[ -n $jobs ]] || jobs=$(nproc)
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "invalid MICROVM_KERNEL_JOBS: $jobs"

outdir=$(realpath -e -- "$(dirname -- "$output")") || die 'output directory does not exist'
[[ -w "$outdir" ]] || die "output directory is not writable: $outdir"
output=$outdir/$(basename -- "$output")

# Store the source/build cache on disk rather than /tmp (which might be tmpfs).
build_root=$(realpath -m -- "${MICROVM_BUILD_DIR:-build}")
work=$build_root/kernel-$version
marker=$work/.built-by-microvm-kernel-script
if [[ -e "$work" || -L "$work" ]]; then
    [[ -d "$work" && ! -L "$work" && -f "$marker" ]] || \
        die "refusing to use existing, unmanaged build directory: $work"
    [[ $(<"$marker") == "$version" ]] || die "unexpected version marker in $work"
else
    mkdir -p -- "$work"
    printf '%s\n' "$version" >"$marker"
fi

archive=$work/linux-$version.tar.xz
source_dir=$work/linux-$version
build_dir=$work/build
firecracker_config=$work/firecracker-6.18.config
major=${version%%.*}
url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${version}.tar.xz"

# Firecracker's tested x86-64 guest config, pinned to a specific git commit.
# Source: https://github.com/firecracker-microvm/firecracker
# Firecracker builds its CI kernels from Amazon Linux trees; we translate the
# options with olddefconfig and verify the essentials for upstream Linux.
firecracker_commit=84df490625763d98eb21edfe24858ce2aa46cfc4
firecracker_sha256=ba22401a0c7292a4c024ebcd10a562d4a1f1bfd2faed671406d3b159c0cf5215
firecracker_url="https://raw.githubusercontent.com/firecracker-microvm/firecracker/${firecracker_commit}/resources/guest_configs/microvm-kernel-ci-x86_64-6.18.config"

download_tmp=
publish_tmp=
cleanup() {
    [[ -z $download_tmp ]] || rm -f -- "$download_tmp"
    [[ -z $publish_tmp ]] || rm -f -- "$publish_tmp"
}
trap cleanup EXIT

if [[ ! -s "$archive" ]]; then
    log "Downloading Linux $version from kernel.org"
    download_tmp=$(mktemp "$work/.download.XXXXXXXX")
    curl --fail --location --show-error --retry 3 --output "$download_tmp" "$url"
    mv -- "$download_tmp" "$archive"
    download_tmp=
else
    log "Reusing cached Linux $version archive"
fi

if [[ ! -s "$firecracker_config" ]]; then
    log 'Downloading pinned Firecracker Linux 6.18 guest configuration'
    download_tmp=$(mktemp "$work/.download.XXXXXXXX")
    curl --fail --location --show-error --retry 3 --output "$download_tmp" \
        "$firecracker_url"
    printf '%s  %s\n' "$firecracker_sha256" "$download_tmp" | sha256sum -c --status || \
        die 'Firecracker configuration checksum mismatch'
    mv -- "$download_tmp" "$firecracker_config"
    download_tmp=
else
    printf '%s  %s\n' "$firecracker_sha256" "$firecracker_config" | \
        sha256sum -c --status || die 'cached Firecracker configuration checksum mismatch'
    log 'Reusing pinned Firecracker configuration'
fi

if [[ ! -f "$source_dir/.microvm-extraction-complete" ]]; then
    [[ ! -e "$source_dir" ]] || \
        die "incomplete source tree at $source_dir; inspect it before retrying"
    log "Extracting Linux $version"
    mkdir -- "$source_dir"
    tar -xJf "$archive" -C "$source_dir" --strip-components=1
    touch -- "$source_dir/.microvm-extraction-complete"
else
    log 'Reusing existing Linux source tree'
fi

mkdir -p -- "$build_dir"
log 'Starting from Firecracker Linux 6.18 guest configuration (not defconfig)'
cp -- "$firecracker_config" "$build_dir/.config"

config=$source_dir/scripts/config
[[ -x "$config" ]] || die "missing kernel config helper: $config"

# Keep the Firecracker x86 KVM/ACPI platform settings. Unlike Firecracker,
# QEMU uses hvc0 here and needs VirtIO-MMIO command-line support as a fallback.
# All boot-essential drivers must be built in, since we have no initramfs.
"$config" --file "$build_dir/.config" \
    --enable KVM_GUEST \
    --enable ACPI \
    --enable PCI \
    --enable VIRTIO \
    --enable VIRTIO_MENU \
    --enable VIRTIO_MMIO \
    --enable VIRTIO_MMIO_CMDLINE_DEVICES \
    --enable VIRTIO_BLK \
    --enable VIRTIO_NET \
    --enable VIRTIO_CONSOLE \
    --enable HVC_DRIVER \
    --enable BTRFS_FS \
    --enable BTRFS_FS_POSIX_ACL \
    --enable DEVTMPFS \
    --enable DEVTMPFS_MOUNT \
    --enable UNIX \
    --enable PACKET \
    --enable INET \
    --enable CGROUPS \
    --enable NAMESPACES \
    --enable TMPFS \
    --enable TMPFS_POSIX_ACL \
    --enable PROC_FS \
    --enable SYSFS \
    --enable FHANDLE \
    --enable SECCOMP \
    --enable SECCOMP_FILTER \
    --enable BINFMT_ELF \
    --enable BINFMT_SCRIPT \
    --enable EPOLL \
    --enable SIGNALFD \
    --enable TIMERFD \
    --enable EVENTFD \
    --enable INOTIFY_USER \
    --enable SERIAL_8250_CONSOLE \
    --enable PRINTK \
    --enable UNIX98_PTYS \
    --disable CC_OPTIMIZE_FOR_PERFORMANCE \
    --enable CC_OPTIMIZE_FOR_SIZE \
    --disable MODULES \
    --disable BLK_DEV_INITRD \
    --disable SCSI \
    --disable USB_SUPPORT \
    --disable EXT4_FS \
    --disable XFS_FS \
    --disable NFS_FS \
    --disable OVERLAY_FS \
    --disable NETWORK_FILESYSTEMS \
    --disable NETFILTER \
    --disable VIRTIO_PCI \
    --disable VIRTIO_PMEM \
    --disable VIRTIO_BALLOON \
    --disable VIRTIO_MEM \
    --disable VIRTIO_VSOCKETS \
    --disable VSOCKETS \
    --disable KEXEC \
    --disable KEXEC_FILE \
    --disable SLUB_DEBUG \
    --disable BTRFS_DEBUG \
    --disable BTRFS_FS_RUN_SANITY_TESTS \
    --disable DEBUG_INFO_BTF \
    --enable DEBUG_INFO_NONE \
    --set-str LOCALVERSION -microvm

log 'Resolving Kconfig dependencies'
make -C "$source_dir" O="$build_dir" ARCH=x86_64 olddefconfig

# Kconfig sometimes silently changes an option because of dependencies.
# Reject the build if any of our boot-critical features are not built in.
for option in KVM_GUEST ACPI PCI VIRTIO VIRTIO_MMIO \
              VIRTIO_MMIO_CMDLINE_DEVICES VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE \
              BTRFS_FS BTRFS_FS_POSIX_ACL ZSTD_COMPRESS ZSTD_DECOMPRESS DEVTMPFS \
              DEVTMPFS_MOUNT HVC_DRIVER UNIX PACKET INET CGROUPS NAMESPACES \
              TMPFS TMPFS_POSIX_ACL PROC_FS SYSFS FHANDLE SECCOMP \
              SECCOMP_FILTER SERIAL_8250_CONSOLE PRINTK UNIX98_PTYS \
              BINFMT_ELF BINFMT_SCRIPT EPOLL SIGNALFD TIMERFD EVENTFD \
              INOTIFY_USER CC_OPTIMIZE_FOR_SIZE; do
    grep -Fqx "CONFIG_${option}=y" "$build_dir/.config" || \
        die "CONFIG_${option}=y was not selected; inspect $build_dir/.config"
done
grep -Fqx '# CONFIG_MODULES is not set' "$build_dir/.config" || \
    die 'expected a self-contained kernel with CONFIG_MODULES=n'
for option in BLK_DEV_INITRD SCSI USB_SUPPORT EXT4_FS XFS_FS NFS_FS OVERLAY_FS \
              NETFILTER VIRTIO_PCI VIRTIO_VSOCKETS VSOCKETS; do
    # A disabled parent menu may remove the option from .config entirely.
    if grep -Eq "^CONFIG_${option}=[ym]$" "$build_dir/.config"; then
        die "CONFIG_${option} is still enabled; inspect $build_dir/.config"
    fi
done

log "Compiling bzImage using $jobs parallel jobs"
make -C "$source_dir" O="$build_dir" ARCH=x86_64 -j"$jobs" bzImage

bzimage=$build_dir/arch/x86/boot/bzImage
[[ -s "$bzimage" ]] || die "kernel build finished without $bzimage"

# Publish atomically and never overwrite another kernel, even if OUTPUT is
# created concurrently while the (potentially long) compilation is running.
[[ ! -e "$output" && ! -L "$output" ]] || die "output appeared during build: $output"
publish_tmp=$(mktemp "$outdir/.microvm-bzImage.XXXXXXXX")
install -m 644 -- "$bzimage" "$publish_tmp"
ln -- "$publish_tmp" "$output" || die "cannot create $output (does it already exist?)"
rm -- "$publish_tmp"
publish_tmp=

printf '\nBuilt kernel: %s\n' "$output"
printf 'Build config: %s/.config\n' "$build_dir"
printf 'Source and build cache: %s\n' "$work"
printf '\nBoot with: ./boot-ubuntu-microvm.sh %q ./image.raw\n' "$output"
