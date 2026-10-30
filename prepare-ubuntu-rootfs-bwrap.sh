#!/usr/bin/env bash
# Run prepare-ubuntu-rootfs.sh with the host filesystem read-only.
# Only a private directory under the host's /tmp is writable in the sandbox.
# After a successful build, publish the image as the invoking (non-root) user.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  prepare-ubuntu-rootfs-bwrap.sh UBUNTU_BASE.tar.gz OUTPUT.raw [SIZE] [SSH_PUBLIC_KEY]

SIZE defaults to 2G; SSH_PUBLIC_KEY defaults to ~/.ssh/id_ed25519.pub.
Run this wrapper as your normal user, without sudo or fakeroot.

The privileged provisioning runs inside Bubblewrap. The host filesystem is
read-only there, apart from a newly created private directory mapped to /tmp.
The finished Btrfs raw image is copied to OUTPUT.raw *after* the sandbox exits, as
your normal user, and an existing output will never be overwritten.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
(( $# >= 2 && $# <= 4 )) || { usage >&2; exit 2; }

(( EUID != 0 )) || die 'run the wrapper as a normal user, not with sudo'
[[ -z ${FAKEROOTKEY:-} ]] || die 'do not run the wrapper under fakeroot'

for program in bwrap sudo realpath mktemp cp chown touch rm rmdir; do
    command -v "$program" >/dev/null || die "missing command: $program"
done

script=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")/prepare-ubuntu-rootfs.sh") \
    || die 'prepare-ubuntu-rootfs.sh must be next to this wrapper'
archive=$(realpath -e -- "$1") || die "archive does not exist: $1"
key=$(realpath -e -- "${4:-$HOME/.ssh/id_ed25519.pub}") \
    || die 'SSH public key not found (supply the fourth argument)'
[[ -f "$script" && -r "$script" ]] || die 'preparation script is not readable'
[[ -f "$archive" && -r "$archive" ]] || die 'Ubuntu Base archive is not readable'
[[ -f "$key" && -r "$key" && -s "$key" ]] || die 'SSH public key is empty or unreadable'

size=${3:-2G}
[[ $size =~ ^[1-9][0-9]*[KMGTP]?$ ]] || die "invalid size: $size"

output_name=$(basename -- "$2")
[[ $output_name != . && $output_name != .. ]] || die 'invalid output filename'
output_dir=$(realpath -e -- "$(dirname -- "$2")") \
    || die "output directory does not exist: $(dirname -- "$2")"
output=$output_dir/$output_name
[[ -d "$output_dir" && -w "$output_dir" ]] || die "output directory is not writable: $output_dir"
[[ ! -e "$output" && ! -L "$output" ]] || die "refusing to overwrite: $output"

umask 077
stage=$(mktemp -d /tmp/ubuntu-rootfs-bwrap.XXXXXXXX) || die 'cannot create /tmp staging directory'
staged_image=$stage/image.raw

# The source archive, public key, and script may themselves reside under
# the host's /tmp. Mount them separately into the private /tmp so they are
# still readable when the host /tmp is hidden by the staging directory.
touch -- "$stage/prepare.sh" "$stage/base.tar.gz" "$stage/key.pub"

printf 'Building image inside Bubblewrap (staging: %s)\n' "$stage" >&2

# Bubblewrap drops capabilities by default. mount/unshare, chroot and tar
# require real root capabilities for this provisioning stage. This is an
# accidental-write guard, NOT a security boundary for malicious root code.
# No --unshare-net: apt-get inside chroot needs Internet access.
if ! sudo -- bwrap \
    --die-with-parent \
    --unshare-pid --unshare-ipc --unshare-uts \
    --cap-add ALL \
    --ro-bind / / \
    --bind "$stage" /tmp \
    --ro-bind "$script" /tmp/prepare.sh \
    --ro-bind "$archive" /tmp/base.tar.gz \
    --ro-bind "$key" /tmp/key.pub \
    --dev /dev \
    --proc /proc \
    --setenv TMPDIR /tmp \
    --setenv HOME /tmp \
    --chdir /tmp \
    -- /bin/bash -c '
        set -Eeuo pipefail
        /bin/bash /tmp/prepare.sh /tmp/base.tar.gz /tmp/image.raw "$1" /tmp/key.pub
        chown -- "$2:$3" /tmp/image.raw
    ' _ "$size" "$(id -u)" "$(id -g)"; then
    printf 'Build failed; staging files were kept at %s\n' "$stage" >&2
    exit 1
fi

[[ -f "$staged_image" && ! -L "$staged_image" && -s "$staged_image" ]] || \
    die "no valid image was produced (staging: $stage)"

# Publish outside sudo/bwrap, using ordinary user permissions. Copy to a
# temporary file in the destination directory first, then hard-link it into
# place. Unlike `cp --no-clobber`, `ln` fails if the output appeared meanwhile,
# and publication is atomic even when /tmp and OUTPUT are different filesystems.
[[ ! -e "$output" && ! -L "$output" ]] || die "output appeared during build: $output (image: $staged_image)"
publish_tmp=$(mktemp "$output_dir/.ubuntu-image-publish.XXXXXXXX") || \
    die "cannot create temporary output in $output_dir"
trap 'rm -f -- "$publish_tmp"' EXIT
cp --reflink=auto --sparse=always -- "$staged_image" "$publish_tmp" || \
    die "could not copy image (staging: $staged_image)"
ln -- "$publish_tmp" "$output" || \
    die "could not publish image without overwriting (staging: $staged_image)"
rm -- "$publish_tmp"
trap - EXIT

rm -- "$staged_image" "$stage/prepare.sh" "$stage/base.tar.gz" "$stage/key.pub"
if ! rmdir -- "$stage"; then
    printf 'Note: nonempty staging directory retained: %s\n' "$stage" >&2
fi

printf '\nCreated: %s\n' "$output"
