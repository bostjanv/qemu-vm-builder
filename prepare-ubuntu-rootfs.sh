#!/usr/bin/env bash
# Provision Ubuntu Base 26.04 with systemd, DHCP, DNS, SSH and a console login,
# then pack a partitionless, Zstd-compressed Btrfs filesystem into a sparse raw image.
#
# Runs entirely as your normal user: provisioning happens inside an
# unprivileged user namespace that maps your subordinate UID/GID range, so
# no sudo, fakeroot, or host network changes are needed.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  prepare-ubuntu-rootfs.sh UBUNTU_BASE.tar.gz OUTPUT.raw [SIZE] [SSH_PUBLIC_KEY]

Examples:
  ./prepare-ubuntu-rootfs.sh ubuntu-base-26.04.1-base-amd64.tar.gz image.raw
  MICROVM_PACKAGES='git vim' ./prepare-ubuntu-rootfs.sh ubuntu-base-26.04.1-base-amd64.tar.gz image.raw 16G

SIZE defaults to 2G. SSH_PUBLIC_KEY defaults to ~/.ssh/id_ed25519.pub.

Optional environment variables:
  MICROVM_USER=NAME        Guest user (default: your host user name)
  MICROVM_HOSTNAME=NAME    Guest hostname (default: ubuntu-microvm)
  MICROVM_PACKAGES='A B'   Extra Ubuntu packages to install
  MICROVM_PROVISION_DIR=PATH
                           Directory of *.sh scripts to run as root inside the
                           guest, in name order, after everything else is set up
  MICROVM_BUILD_DIR=PATH   Directory for temporary build files
                           (default: ./build)

Provisioning scripts run with network access, so they can use apt-get. They
receive MICROVM_USER and MICROVM_HOSTNAME in the environment.

The sparse raw image contains a Btrfs filesystem directly on /dev/vda (no
partitions), precompressed with Zstd level 3; the guest also mounts it with
compress=zstd:3 for future writes. The guest user logs in with SSH public keys
only and has passwordless sudo. The hvc0 console autologs in as root. This is
intended for an isolated development VM.

Run as your normal user. Your user needs a subordinate UID/GID range in
/etc/subuid and /etc/subgid (usually created with the account).
Host dependencies: unshare (util-linux 2.38+), newuidmap/newgidmap (shadow or
uidmap), chroot, systemctl, tar, gzip, mkfs.btrfs (btrfs-progs), coreutils.

The output must not exist already. The script does not boot QEMU.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*" >&2; }

# Run as root of the user namespace. Root there is your own user; guest
# system accounts map to your subordinate IDs.
in_userns() { unshare --user --map-auto --map-root-user -- "$@"; }

# Run a command in the guest with /dev and /proc mounted. The mounts exist only
# in a private mount namespace and disappear when it exits, before mkfs.btrfs
# reads the tree.
run_chroot() {
    unshare --mount --propagation private --pid --fork -- /bin/bash -c '
        set -Eeuo pipefail
        rootfs=$1 user=$2 hostname=$3
        shift 3
        mount --rbind /dev "$rootfs/dev"
        mount -t proc proc "$rootfs/proc"
        exec chroot "$rootfs" /usr/bin/env -i \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            HOME=/root LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
            MICROVM_USER="$user" MICROVM_HOSTNAME="$hostname" "$@"
    ' _ "$@"
}

provision() {
    local input=$1 rootfs=$2 image=$3 size=$4 pubkey=$5 user=$6 hostname=$7 hooks=$8
    shift 8

    log 'Extracting Ubuntu Base (preserving numeric ownership)'
    mkdir -p -- "$rootfs"
    tar --extract --gzip --file "$input" --directory "$rootfs" \
        --numeric-owner --same-owner --preserve-permissions \
        --no-acls --xattrs --xattrs-include='*' --xattrs-exclude='system.posix_acl_*'

    # mkfs.btrfs --rootdir copies this inode as the filesystem root. Normalize
    # it independently of archive contents and the host umask.
    chown 0:0 "$rootfs"
    chmod 755 "$rootfs"
    install -d -m 755 "$rootfs/proc" "$rootfs/dev"

    # Provide DNS while provisioning (remove a possible symlink first), and
    # prevent maintainer scripts from starting services.
    rm -f -- "$rootfs/etc/resolv.conf"
    install -m 644 /etc/resolv.conf "$rootfs/etc/resolv.conf"
    printf '#!/bin/sh\nexit 101\n' >"$rootfs/usr/sbin/policy-rc.d"
    chmod 755 "$rootfs/usr/sbin/policy-rc.d"

    # This file is executed INSIDE the chroot.
    cat >"$rootfs/tmp/provision-inside.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail

# APT's _apt helper must be able to traverse every parent directory and
# create downloads in the partial directories.
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
    btrfs-progs "$@"

[[ -x /usr/bin/sudo && -u /usr/bin/sudo ]] || {
    echo 'sudo is missing or its setuid bit was lost' >&2
    exit 1
}
if ! id "$MICROVM_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$MICROVM_USER"
fi
usermod -aG sudo "$MICROVM_USER"
ssh-keygen -A

# Use the UTF-8 locale shipped by the minimal base image by default.
printf 'LANG=C.UTF-8\n' >/etc/default/locale
GUEST

    log 'Installing systemd, SSH, networking tools, and login packages'
    run_chroot "$rootfs" "$user" "$hostname" /bin/bash /tmp/provision-inside.sh "$@"
    rm -f -- "$rootfs/tmp/provision-inside.sh"

    log 'Configuring guest services, networking, SSH and console login'
    install -d -m 755 "$rootfs/etc/systemd/network"
    printf '%s\n' '[Match]' 'Type=ether' '' '[Network]' 'DHCP=yes' \
        >"$rootfs/etc/systemd/network/10-virtio.network"

    printf '%s\n' "$hostname" >"$rootfs/etc/hostname"

    # Keep compression enabled for later guest writes.
    printf '%s\n' 'LABEL=ubuntu-root / btrfs defaults,compress=zstd:3 0 0' \
        >"$rootfs/etc/fstab"

    # sudo resolves the machine's own hostname; make sure /etc/hosts has it.
    touch -- "$rootfs/etc/hosts"
    if ! grep -Eq '^[[:space:]]*127[.]0[.]0[.]1[[:space:]]+(.*[[:space:]])?localhost([[:space:]]|$)' \
            "$rootfs/etc/hosts"; then
        printf '127.0.0.1 localhost\n' >>"$rootfs/etc/hosts"
    fi
    if ! grep -Eq "^[[:space:]]*127[.]0[.]1[.]1[[:space:]]+${hostname}([[:space:]]|\$)" \
            "$rootfs/etc/hosts"; then
        printf '127.0.1.1 %s\n' "$hostname" >>"$rootfs/etc/hosts"
    fi

    install -d -m 700 "$rootfs/home/$user/.ssh"
    install -m 600 "$pubkey" "$rootfs/home/$user/.ssh/authorized_keys"
    chroot "$rootfs" chown -R "$user:$user" "/home/$user/.ssh"

    # SSH access remains key-only; local QEMU console and sudo are deliberately
    # passwordless for development purposes.
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"$rootfs/etc/sudoers.d/90-microvm-user"
    chmod 440 "$rootfs/etc/sudoers.d/90-microvm-user"
    chroot "$rootfs" /usr/sbin/visudo -cf /etc/sudoers.d/90-microvm-user

    install -d -m 755 "$rootfs/etc/systemd/system/serial-getty@hvc0.service.d"
    printf '%s\n' '[Service]' 'ExecStart=' \
        'ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 vt100' \
        >"$rootfs/etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf"

    # The microVM kernel is compiled with CONFIG_MODULES=n. Skip systemd's
    # optional modprobe@ jobs unless kmod is installed later.
    install -d -m 755 "$rootfs/etc/systemd/system/modprobe@.service.d"
    printf '%s\n' '[Unit]' 'ConditionPathExists=/usr/sbin/modprobe' \
        >"$rootfs/etc/systemd/system/modprobe@.service.d/10-require-modprobe.conf"

    install -d -m 755 "$rootfs/etc/ssh/sshd_config.d"
    printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' \
        >"$rootfs/etc/ssh/sshd_config.d/90-microvm.conf"

    systemctl --root="$rootfs" enable \
        systemd-networkd.service \
        systemd-resolved.service \
        systemd-timesyncd.service \
        ssh.service \
        serial-getty@hvc0.service
    systemctl --root="$rootfs" set-default multi-user.target

    if [[ -n $hooks ]]; then
        local hook_dir=$rootfs/tmp/microvm-provision.d
        install -d -m 755 "$hook_dir"
        cp -- "$hooks"/*.sh "$hook_dir/"
        local hook
        for hook in "$hook_dir"/*.sh; do
            log "Running provisioning script $(basename -- "$hook")"
            run_chroot "$rootfs" "$user" "$hostname" \
                /bin/bash "/tmp/microvm-provision.d/$(basename -- "$hook")"
        done
        rm -rf -- "$hook_dir"
    fi

    run_chroot "$rootfs" "$user" "$hostname" apt-get clean
    rm -rf -- "$rootfs"/var/lib/apt/lists/*
    rm -f -- "$rootfs/usr/sbin/policy-rc.d"
    ln -sfn /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"

    # Give each newly booted VM a new machine ID.
    truncate --size 0 "$rootfs/etc/machine-id"

    # /dev stays empty: the kernel mounts devtmpfs there at boot.
    log "Creating $size sparse Btrfs filesystem (Zstd level 3)"
    truncate --size "$size" "$image"
    mkfs.btrfs --force --label ubuntu-root \
        --rootdir "$rootfs" --compress zstd:3 "$image"
}

if [[ ${1:-} == --provision-internal ]]; then
    shift
    umask 022
    provision "$@"
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

(( EUID != 0 )) || die 'run as your normal user, without sudo'
[[ -z ${FAKEROOTKEY:-} ]] || die 'do not run under fakeroot'

input=$1
output=$2
size=${3:-2G}
pubkey=${4:-${HOME}/.ssh/id_ed25519.pub}
user=${MICROVM_USER:-$(id -un)}
hostname=${MICROVM_HOSTNAME:-ubuntu-microvm}
hooks=${MICROVM_PROVISION_DIR:-}
read -r -a packages <<<"${MICROVM_PACKAGES:-}"

[[ -r "$input" && -f "$input" ]] || die "cannot read Ubuntu Base archive: $input"
[[ -r "$pubkey" && -s "$pubkey" ]] || die "missing SSH public key: $pubkey (pass a .pub file as the fourth argument)"
[[ ! -e "$output" && ! -L "$output" ]] || die "output already exists: $output"
[[ $size =~ ^[1-9][0-9]*[KMGTP]?$ ]] || die "invalid filesystem size: $size"
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $user != root ]] || die "invalid MICROVM_USER: $user"
[[ $hostname =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || \
    die "invalid MICROVM_HOSTNAME: $hostname"
for package in "${packages[@]}"; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.:=~-]*$ ]] || die "invalid package name: $package"
done
if [[ -n $hooks ]]; then
    [[ -d $hooks ]] || die "MICROVM_PROVISION_DIR is not a directory: $hooks"
    compgen -G "$hooks/*.sh" >/dev/null || die "no *.sh scripts in MICROVM_PROVISION_DIR: $hooks"
    hooks=$(realpath -- "$hooks")
fi

for program in unshare newuidmap newgidmap chroot systemctl tar gzip mkfs.btrfs \
               du mktemp truncate install ln grep realpath; do
    command -v "$program" >/dev/null || die "missing host command: $program"
done
in_userns true 2>/dev/null || \
    die "cannot create a user namespace with your subordinate IDs; check /etc/subuid and /etc/subgid for $(id -un)"

outdir=$(dirname -- "$output")
[[ -d "$outdir" && -w "$outdir" ]] || die "output directory is unavailable: $outdir"

input=$(realpath -- "$input")
pubkey=$(realpath -- "$pubkey")
outdir=$(realpath -- "$outdir")
output=$outdir/$(basename -- "$output")
self=$(realpath -- "$0")
build_root=$(realpath -m -- "${MICROVM_BUILD_DIR:-build}")

mkdir -p -- "$build_root"
work=$(mktemp -d "$build_root/rootfs.XXXXXXXX")
image=$(mktemp "$outdir/.ubuntu-image.XXXXXXXX")

cleanup() {
    local status=$?
    trap - EXIT
    # Guest files are owned by subordinate IDs; delete them inside the namespace.
    in_userns rm -rf -- "$work" || true
    rm -f -- "$image"
    exit "$status"
}
trap cleanup EXIT

in_userns /bin/bash "$self" --provision-internal \
    "$input" "$work/rootfs" "$image" "$size" "$pubkey" "$user" "$hostname" "$hooks" \
    "${packages[@]}"

# Atomic creation, without overwriting an existing image.
ln -- "$image" "$output" || die "could not create output: $output"
printf '\nCreated %s (guest user: %s)\n' "$output" "$user"
du -h -- "$output"
