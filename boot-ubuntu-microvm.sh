#!/usr/bin/env bash
# Launch the partitionless Btrfs raw disk built by prepare-ubuntu-rootfs.sh.
# No sudo, TAP devices, bridges, or host network changes are required.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: boot-ubuntu-microvm.sh KERNEL IMAGE.raw [SSH_PORT]

Examples:
  ./boot-ubuntu-microvm.sh ./vmlinux ./image.raw
  ./boot-ubuntu-microvm.sh ./bzImage ./image.raw 2223

SSH_PORT defaults to MICROVM_SSH_PORT, or 2222. QEMU's user-mode network
forwards only the host loopback address 127.0.0.1:SSH_PORT to port 22 in the VM.

Optional environment variables:
  MICROVM_MEMORY=8G  Guest RAM
  MICROVM_CPUS=4      Number of vCPUs
  MICROVM_CONSOLE=virtio  Console: virtio (default) or serial (early boot logs)
  MICROVM_DAEMON=1    Background execution (default); use 0 for foreground
  MICROVM_RUNTIME_DIR=PATH  Private directory for daemon socket, PID and log
  MICROVM_USER=NAME   Guest user shown in the SSH hints (default: your user)

Requires a KVM-capable x86-64 host and a kernel with Btrfs, virtio-mmio,
virtio-blk, and virtio-mmio command-line discovery built in. The serial
console needs CONFIG_SERIAL_8250_CONSOLE=y and CONFIG_EARLY_PRINTK=y;
the virtio console needs CONFIG_VIRTIO_CONSOLE=y.

The Btrfs filesystem is directly on /dev/vda, mounted with Zstd compression;
the guest boots systemd as PID 1.
In daemon mode, the console is available over a Unix socket (connect with
socat) and its output is logged. The default private runtime directory is
under XDG_RUNTIME_DIR (if set) or the current directory, named
ubuntu-microvm-SSH_PORT. The SSH port is used to distinguish VMs.
In foreground mode, QEMU uses stdin/stdout for the selected console.
Keep x-option-roms=on: QEMU's direct -kernel boot requires its linuxboot ROM,
because the raw root disk intentionally has no bootloader.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
if (( $# < 2 || $# > 3 )); then
    usage >&2
    exit 2
fi

kernel=$1
disk=$2
ssh_port=${3:-${MICROVM_SSH_PORT:-2222}}
memory=${MICROVM_MEMORY:-8G}
cpus=${MICROVM_CPUS:-4}
console=${MICROVM_CONSOLE:-virtio}
daemon=${MICROVM_DAEMON:-1}
guest_user=${MICROVM_USER:-$(id -un)}

[[ -r $kernel && -f $kernel ]] || die "cannot read kernel: $kernel"
[[ -r $disk && -f $disk ]] || die "cannot read raw Btrfs image: $disk"
[[ $ssh_port =~ ^[0-9]+$ ]] || die 'SSH_PORT must be an integer'
(( 10#$ssh_port >= 1024 && 10#$ssh_port <= 65535 )) || die 'SSH_PORT must be between 1024 and 65535'
[[ $cpus =~ ^[1-9][0-9]*$ ]] || die 'MICROVM_CPUS must be a positive integer'
[[ $memory =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || die 'MICROVM_MEMORY must be a size like 512M or 1G'
[[ $daemon == 0 || $daemon == 1 ]] || die 'MICROVM_DAEMON must be 0 or 1'

case $console in
    serial)
        machine='microvm,x-option-roms=on,pit=off,pic=off,isa-serial=on,rtc=off'
        kernel_append='earlyprintk=ttyS0,115200 console=ttyS0,115200 root=/dev/vda rootfstype=btrfs rootflags=compress=zstd:3 rw rootwait init=/sbin/init loglevel=7 reboot=t'
        ;;
    virtio)
        machine='microvm,x-option-roms=on,pit=off,pic=off,isa-serial=off,rtc=off'
        kernel_append='console=hvc0 root=/dev/vda rootfstype=btrfs rootflags=compress=zstd:3 rw rootwait init=/sbin/init reboot=t'
        ;;
    *) die "invalid MICROVM_CONSOLE: $console (expected serial or virtio)" ;;
esac

command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'qemu-system-x86_64 is not installed'
[[ -r /dev/kvm && -w /dev/kvm ]] || die 'no access to /dev/kvm (check KVM availability and permissions)'

if [[ $daemon == 1 ]]; then
    runtime_dir=${MICROVM_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-$PWD}/ubuntu-microvm-$ssh_port}
    [[ $runtime_dir == /* ]] || runtime_dir=$PWD/$runtime_dir
    [[ ! -L $runtime_dir ]] || die "runtime directory is a symlink: $runtime_dir"
    if [[ ! -d $runtime_dir ]]; then
        [[ ! -e $runtime_dir ]] || die "runtime path is not a directory: $runtime_dir"
        (umask 077; mkdir -m 700 -- "$runtime_dir") || die "cannot create runtime directory: $runtime_dir"
    fi
    runtime_dir=$(realpath -- "$runtime_dir")
    [[ $(stat -c %u -- "$runtime_dir") == "$EUID" ]] || die 'runtime directory must be owned by the current user'
    mode=$(stat -c %a -- "$runtime_dir")
    (( (8#$mode & 077) == 0 )) || die 'runtime directory must not be accessible to group or others'
    [[ $runtime_dir != *,* ]] || die 'runtime directory must not contain commas (QEMU option separator)'

    pidfile=$runtime_dir/qemu.pid
    console_socket=$runtime_dir/console.sock
    console_log=$runtime_dir/console.log
    for path in "$pidfile" "$console_socket"; do
        [[ ! -e $path && ! -L $path ]] || die "path already exists: $path (is a VM already running?)"
    done
    [[ ! -L $console_log && ( ! -e $console_log || -f $console_log ) ]] || \
        die "invalid or symlinked console log: $console_log"

    qemu_display=(-display none -daemonize -monitor none -pidfile "$pidfile")
    console_backend="socket,id=virtiocon0,path=$console_socket,server=on,wait=off,logfile=$console_log,logappend=on"
else
    qemu_display=(-nographic)
    console_backend='stdio,id=virtiocon0,signal=off'
fi

case $console in
    serial)
        if [[ $daemon == 1 ]]; then
            console_args=(-chardev "$console_backend" -serial chardev:virtiocon0)
        else
            console_args=(-serial mon:stdio)
        fi
        ;;
    virtio)
        console_args=(
            -chardev "$console_backend"
            -device virtio-serial-device
            -device virtconsole,chardev=virtiocon0
        )
        ;;
esac

printf 'Starting Ubuntu microVM: %s\n' "$disk"
printf 'SSH after boot: ssh -p %s %s@127.0.0.1\n' "$ssh_port" "$guest_user"
printf 'Console: %s\n' "$console"
if [[ $daemon == 1 ]]; then
    printf 'Mode: daemon (background)\n'
    printf 'PID file: %s\n' "$pidfile"
    printf 'Console log: %s\n' "$console_log"
    printf 'Connect: socat -,rawer,escape=0x1d UNIX-CONNECT:%q\n' "$console_socket"
    printf 'Detach from console: Ctrl+]\n'
    printf 'Stop VM: ssh -p %s %s@127.0.0.1 sudo poweroff\n\n' "$ssh_port" "$guest_user"
else
    printf 'Mode: foreground\n'
    [[ $console != serial ]] || printf 'QEMU exit shortcut: Ctrl+A, then X\n'
    printf '\n'
fi

exec qemu-system-x86_64 \
    -M "$machine" \
    -enable-kvm -cpu host -m "$memory" -smp "$cpus" \
    -kernel "$kernel" \
    -append "$kernel_append" \
    -nodefaults -no-user-config "${qemu_display[@]}" -no-reboot \
    "${console_args[@]}" \
    -drive "id=rootdisk,file=$disk,format=raw,if=none,discard=unmap,detect-zeroes=unmap" \
    -device virtio-blk-device,drive=rootdisk \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
    -device virtio-net-device,netdev=net0
