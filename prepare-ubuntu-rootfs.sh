#!/usr/bin/env bash
# Provision Ubuntu Base 26.04 with systemd, DHCP, DNS, SSH and a serial login,
# then pack a partitionless, Zstd-compressed Btrfs filesystem into a sparse raw image.
#
# Does not change host networking or start QEMU.
# Privileges: sudo is used only for extraction/provisioning/configuration;
#             fakeroot is used for unprivileged final filesystem creation.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  prepare-ubuntu-rootfs.sh UBUNTU_BASE.tar.gz OUTPUT.raw [SIZE] [SSH_PUBLIC_KEY]

Examples:
  ./prepare-ubuntu-rootfs.sh ubuntu-base-26.04-base-amd64.tar.gz image.raw
  ./prepare-ubuntu-rootfs.sh ubuntu-base-26.04-base-amd64.tar.gz image.raw 16G ~/.ssh/id_ed25519.pub

SIZE defaults to 2G. SSH_PUBLIC_KEY defaults to ~/.ssh/id_ed25519.pub.
The sparse raw image contains a Btrfs filesystem, precompressed with Zstd
level 3; the kernel also mounts it with compress=zstd:3 for future writes.
The guest SSH user is "alice", with public-key-only SSH.
The hvc0 console autologs in as root; "alice" has passwordless sudo.
This is intended for an isolated development VM. The image has a Btrfs
filesystem directly on /dev/vda (no partitions).

Host dependencies: unshare, mount, chroot, systemctl, sudo (unless run as
real root), fakeroot, tar, gzip, mkfs.btrfs (btrfs-progs), and coreutils.

The script does not configure or modify any host network interface or service.
It does not boot QEMU. The output must not exist already.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*" >&2; }

has_real_root() {
    # Avoid treating an outer fakeroot environment as true root.
    [[ -z ${FAKEROOTKEY:-} && ${EUID:-1} -eq 0 && -r /proc/self/uid_map ]] &&
        [[ $(awk 'NR==1 {print $2}' /proc/self/uid_map) == 0 ]]
}

as_root() {
    if has_real_root; then
        "$@"
    else
        sudo -- "$@"
    fi
}

pack_image() {
    # This mode is entered through one fakeroot process, so GNU tar's simulated
    # chown/mknod metadata remains visible to mkfs.btrfs --rootdir.
    local input_tar=$1 output=$2 size=$3 outdir work rootfs raw

    [[ $(id -u) -eq 0 ]] || die "internal packing mode requires fakeroot"
    outdir=$(dirname -- "$output")
    # The EXIT trap runs after this function returns, so its target must not
    # be a local variable that has already gone out of scope.
    pack_tmpdir=$(mktemp -d "$outdir/.ubuntu-fakeroot.XXXXXXXX")
    trap 'rm -rf -- "$pack_tmpdir"' EXIT
    work=$pack_tmpdir

    rootfs=$work/rootfs
    raw=$work/image.raw
    mkdir -p -- "$rootfs"

    log 'Extracting provisioned filesystem under fakeroot'
    tar --extract --gzip --file "$input_tar" --directory "$rootfs" \
        --numeric-owner --same-owner --preserve-permissions \
        --no-acls --xattrs --xattrs-include='*' --xattrs-exclude='system.posix_acl_*'

    # mkfs.btrfs --rootdir copies the source directory inode as the filesystem
    # root. A restrictive umask (the Bubblewrap wrapper uses 077) must not
    # result in a guest / with mode 0700: non-root system services would fail.
    chown 0:0 "$rootfs"
    chmod 755 "$rootfs"

    [[ -x "$rootfs/sbin/init" ]] || die 'systemd /sbin/init is absent'
    mkdir -p "$rootfs/dev"
    if [[ ! -e "$rootfs/dev/console" ]]; then
        mknod -m 600 "$rootfs/dev/console" c 5 1
    fi
    if [[ ! -e "$rootfs/dev/null" ]]; then
        mknod -m 666 "$rootfs/dev/null" c 1 3
    fi

    log "Creating $size sparse Btrfs filesystem (Zstd level 3)"
    truncate --size "$size" "$raw"
    mkfs.btrfs --force --label ubuntu-root \
        --rootdir "$rootfs" --compress zstd:3 "$raw"

    # Atomic creation, without overwriting an existing image.
    ln -- "$raw" "$output" || die "could not create output: $output"
    printf '\nCreated %s\n' "$output"
    du -h -- "$output"
}

if [[ ${1:-} == --pack-internal ]]; then
    [[ $# == 4 ]] || die 'invalid internal packing arguments'
    pack_image "$2" "$3" "$4"
    exit 0
fi

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
if (( $# < 2 || $# > 4 )); then
    usage >&2
    exit 2
fi

input=$1
output=$2
size=${3:-2G}
pubkey=${4:-${HOME}/.ssh/id_ed25519.pub}

[[ -r "$input" && -f "$input" ]] || die "cannot read Ubuntu Base archive: $input"
[[ -r "$pubkey" && -s "$pubkey" ]] || die "missing SSH public key: $pubkey (pass a .pub file as the fourth argument)"
[[ ! -e "$output" && ! -L "$output" ]] || die "output already exists: $output"
[[ $size =~ ^[1-9][0-9]*[KMGTP]?$ ]] || die "invalid filesystem size: $size"

for program in unshare mount chroot systemctl fakeroot tar gzip mkfs.btrfs du \
               mktemp truncate install tee ln awk grep realpath; do
    command -v "$program" >/dev/null || die "missing host command: $program"
done
if ! has_real_root; then
    command -v sudo >/dev/null || die 'sudo is required for the provisioning stage'
fi

outdir=$(dirname -- "$output")
[[ -d "$outdir" && -w "$outdir" ]] || die "output directory is unavailable: $outdir"

# Use absolute paths for commands running in root/chroot subprocesses.
input=$(realpath -- "$input")
pubkey=$(realpath -- "$pubkey")
outdir=$(realpath -- "$outdir")
output=$outdir/$(basename -- "$output")
self=$(realpath -- "$0")

work=$(mktemp -d "$outdir/.ubuntu-provision.XXXXXXXX")
rootfs=$work/rootfs
packed=$work/provisioned.tar.gz

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "${work:-}" && -d "$work" && "$work" == "$outdir"/.ubuntu-provision.* ]]; then
        # Files installed by chroot are truly root-owned. Clean up only this
        # exact mktemp-created rootfs, never any caller-provided path.
        if [[ -d "$rootfs" ]]; then
            as_root rm -rf -- "$rootfs" || true
        fi
        rm -rf -- "$work" || true
    fi
    exit "$status"
}
trap cleanup EXIT

log 'Extracting Ubuntu Base (preserving real numeric ownership)'
mkdir -p "$rootfs"
as_root tar --extract --gzip --file "$input" --directory "$rootfs" \
    --numeric-owner --same-owner --preserve-permissions \
    --no-acls --xattrs --xattrs-include='*' --xattrs-exclude='system.posix_acl_*'

# Normalize the root inode independently of archive contents and host umask.
# This also makes the chroot accessible to unprivileged package helpers.
as_root chown 0:0 "$rootfs"
as_root chmod 755 "$rootfs"

# This file is executed INSIDE the chroot, never in the host root filesystem.
cat >"$work/provision-inside.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The inherited host locale (such as en_US.UTF-8) may not exist in Ubuntu Base.
unset LANGUAGE
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Keep Ubuntu Base's dpkg path-exclude rules for manuals and documentation.
# sudo's maintainer script may warn about absent manual-page alternatives;
# those warnings are expected and do not affect the installed executable.

# Prevent maintainer scripts from attempting to start services during build.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT

# APT's _apt helper must be able to traverse every parent directory and
# create downloads in the partial directories. Normalize both ownership and
# permissions before the first apt-get invocation, avoiding its root fallback.
id _apt >/dev/null 2>&1 || { echo 'Ubuntu Base has no _apt user' >&2; exit 1; }
for dir in /var /var/cache /var/cache/apt /var/cache/apt/archives \
           /var/lib /var/lib/apt /var/lib/apt/lists; do
    install -d -o root -g root -m 755 "$dir"
done
install -d -o _apt -g root -m 700 \
    /var/cache/apt/archives/partial /var/lib/apt/lists/partial

apt-get update
apt-get install -y --no-install-recommends \
    systemd-sysv udev systemd-resolved systemd-timesyncd \
    openssh-server iproute2 sudo ca-certificates passwd login util-linux \
    btrfs-progs

[[ -x /usr/bin/sudo && -u /usr/bin/sudo ]] || {
    echo 'sudo is missing or its setuid bit was lost' >&2
    exit 1
}
[[ -x /usr/sbin/useradd ]] || { echo 'passwd did not install /usr/sbin/useradd' >&2; exit 1; }
if ! id alice >/dev/null 2>&1; then
    /usr/sbin/useradd -m -s /bin/bash alice
fi
/usr/sbin/usermod -aG sudo alice
ssh-keygen -A

# Use the UTF-8 locale shipped by the minimal base image by default.
printf 'LANG=C.UTF-8\n' >/etc/default/locale

apt-get clean
rm -rf /var/lib/apt/lists/*
GUEST

as_root install -m 755 "$work/provision-inside.sh" "$rootfs/tmp/provision-inside.sh"
log 'Installing systemd, SSH, networking tools, and login packages'

# Provide DNS during apt installation. Remove a possible symlink first, so
# copying the resolver configuration cannot follow it outside the rootfs.
as_root rm -f -- "$rootfs/etc/resolv.conf"
as_root install -m 644 /etc/resolv.conf "$rootfs/etc/resolv.conf"
as_root install -d -m 755 "$rootfs/proc" "$rootfs/dev"

# The mounts exist only inside the temporary mount namespace. Even if apt or
# chroot fails, they disappear when unshare exits, before our EXIT cleanup
# recursively removes the rootfs. No host cgroups or mount settings change.
as_root unshare --mount --propagation private -- /bin/bash -c '
    set -Eeuo pipefail
    rootfs=$1
    mount --rbind /dev "$rootfs/dev"
    mount -t proc proc "$rootfs/proc"
    exec chroot "$rootfs" /bin/bash /tmp/provision-inside.sh
' _ "$rootfs"
as_root rm -f -- "$rootfs/tmp/provision-inside.sh"

log 'Configuring guest services, networking, SSH and console login'
as_root install -d -m 755 "$rootfs/etc/systemd/network"
printf '%s\n' '[Match]' 'Type=ether' '' '[Network]' 'DHCP=yes' |
    as_root tee "$rootfs/etc/systemd/network/10-virtio.network" >/dev/null
as_root chmod 644 "$rootfs/etc/systemd/network/10-virtio.network"

as_root ln -sfn /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
printf '%s\n' 'ubuntu-microvm' | as_root tee "$rootfs/etc/hostname" >/dev/null

# Keep compression enabled for later worktrees and other guest writes.
printf '%s\n' 'LABEL=ubuntu-root / btrfs defaults,compress=zstd:3 0 0' |
    as_root tee "$rootfs/etc/fstab" >/dev/null
as_root chmod 644 "$rootfs/etc/fstab"

# sudo resolves the machine's own hostname. Ubuntu Base might not have a
# corresponding /etc/hosts entry, causing "unable to resolve host" warnings.
# Preserve existing entries; never follow a symlink while provisioning as root.
[[ ! -L "$rootfs/etc/hosts" ]] || die 'refusing to modify symlinked guest /etc/hosts'
if [[ ! -e "$rootfs/etc/hosts" ]]; then
    printf '%s\n' '127.0.0.1 localhost' '127.0.1.1 ubuntu-microvm' |
        as_root tee "$rootfs/etc/hosts" >/dev/null
elif ! as_root grep -Eq \
        '^[[:space:]]*127[.]0[.]1[.]1[[:space:]]+ubuntu-microvm([[:space:]]|$)' \
        "$rootfs/etc/hosts"; then
    printf '%s\n' '127.0.1.1 ubuntu-microvm' |
        as_root tee -a "$rootfs/etc/hosts" >/dev/null
fi
as_root chmod 644 "$rootfs/etc/hosts"

as_root install -d -m 700 "$rootfs/home/alice/.ssh"
as_root install -m 600 "$pubkey" "$rootfs/home/alice/.ssh/authorized_keys"
as_root chroot "$rootfs" chown -R alice:alice /home/alice/.ssh

# SSH access remains key-only; local QEMU console and sudo are deliberately
# passwordless for development purposes.
as_root install -d -m 755 "$rootfs/etc/sudoers.d"
printf '%s\n' 'alice ALL=(ALL) NOPASSWD:ALL' |
    as_root tee "$rootfs/etc/sudoers.d/90-alice-microvm" >/dev/null
as_root chmod 440 "$rootfs/etc/sudoers.d/90-alice-microvm"
as_root chroot "$rootfs" /usr/sbin/visudo -cf /etc/sudoers.d/90-alice-microvm

as_root install -d -m 755 "$rootfs/etc/systemd/system/serial-getty@hvc0.service.d"
printf '%s\n' '[Service]' 'ExecStart=' \
    'ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 vt100' |
    as_root tee "$rootfs/etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf" >/dev/null
as_root chmod 644 "$rootfs/etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf"

# The microVM kernel is compiled with CONFIG_MODULES=n. No kmod package is
# installed, so skip systemd's optional modprobe@ jobs instead of trying to
# execute a missing modprobe binary. If kmod is installed later, they can run.
as_root install -d -m 755 "$rootfs/etc/systemd/system/modprobe@.service.d"
printf '%s\n' '[Unit]' 'ConditionPathExists=/usr/sbin/modprobe' |
    as_root tee "$rootfs/etc/systemd/system/modprobe@.service.d/10-require-modprobe.conf" >/dev/null
as_root chmod 644 "$rootfs/etc/systemd/system/modprobe@.service.d/10-require-modprobe.conf"

as_root install -d -m 755 "$rootfs/etc/ssh/sshd_config.d"
printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' |
    as_root tee "$rootfs/etc/ssh/sshd_config.d/90-microvm.conf" >/dev/null

as_root systemctl --root="$rootfs" enable \
    systemd-networkd.service \
    systemd-resolved.service \
    systemd-timesyncd.service \
    ssh.service \
    serial-getty@hvc0.service
as_root systemctl --root="$rootfs" set-default multi-user.target

# Give each newly booted VM a new machine ID.
as_root truncate --size 0 "$rootfs/etc/machine-id"

log 'Packing provisioned filesystem with numeric ownership and xattrs'
as_root tar --create --file - --directory "$rootfs" \
    --numeric-owner --no-acls --xattrs --xattrs-include='*' --xattrs-exclude='system.posix_acl_*' . |
    gzip -1 > "$packed"

# fakeroot does NOT perform the package-install/chroot stage: it is for the
# unprivileged Btrfs/raw-image creation step, including device-node metadata.
fakeroot bash "$self" --pack-internal "$packed" "$output" "$size"
