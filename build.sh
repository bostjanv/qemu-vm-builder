#!/usr/bin/env bash
# Build everything needed to boot a microVM: download Ubuntu Base, build the
# kernel, and build the root filesystem image. Steps whose output already
# exists are skipped.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: build.sh [CONFIG]

Reads settings from CONFIG (default: ./vm.conf, if it exists). See
vm.conf.example for every setting. Environment variables override the file.

Outputs that already exist (kernel, image, Ubuntu Base download) are reused;
delete one to rebuild it.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*" >&2; }

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || { usage >&2; exit 2; }

scripts=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")

config=${1:-vm.conf}
if [[ -e $config ]]; then
    # Settings already in the environment take precedence over the file.
    overrides=()
    for name in "${!MICROVM_@}"; do
        overrides+=("$name=${!name}")
    done
    set -a
    # shellcheck source=/dev/null
    source "$config"
    set +a
    for setting in "${overrides[@]}"; do
        export "$setting"
    done
elif (( $# == 1 )); then
    die "config file not found: $config"
fi

export MICROVM_UBUNTU_VERSION=${MICROVM_UBUNTU_VERSION:-26.04.1}
export MICROVM_KERNEL_VERSION=${MICROVM_KERNEL_VERSION:-6.18.59}
export MICROVM_KERNEL=${MICROVM_KERNEL:-bzImage}
export MICROVM_IMAGE=${MICROVM_IMAGE:-image.raw}
export MICROVM_IMAGE_SIZE=${MICROVM_IMAGE_SIZE:-8G}
export MICROVM_SSH_KEY=${MICROVM_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}
export MICROVM_BUILD_DIR=${MICROVM_BUILD_DIR:-.microvm-build}

version=$MICROVM_UBUNTU_VERSION
[[ $version =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?$ ]] || \
    die "invalid MICROVM_UBUNTU_VERSION: $version"
series=${BASH_REMATCH[1]}
base_name=ubuntu-base-$version-base-amd64.tar.gz
base_url=https://cdimage.ubuntu.com/ubuntu-base/releases/$series/release
archive=$MICROVM_BUILD_DIR/$base_name

mkdir -p -- "$MICROVM_BUILD_DIR"
if [[ -s $archive ]]; then
    log "Reusing $archive"
else
    log "Downloading $base_name"
    download=$(mktemp "$MICROVM_BUILD_DIR/.download.XXXXXXXX")
    trap 'rm -f -- "$download"' EXIT
    checksum=$(curl --fail --location --silent --show-error "$base_url/SHA256SUMS" |
        awk -v name="$base_name" '$2 == "*" name || $2 == name { print $1 }')
    [[ $checksum =~ ^[0-9a-f]{64}$ ]] || die "no checksum for $base_name in $base_url/SHA256SUMS"
    curl --fail --location --show-error --retry 3 --output "$download" "$base_url/$base_name"
    printf '%s  %s\n' "$checksum" "$download" | sha256sum -c --status || \
        die "checksum mismatch for $base_name"
    mv -- "$download" "$archive"
    trap - EXIT
fi

if [[ -e $MICROVM_KERNEL ]]; then
    log "Reusing kernel $MICROVM_KERNEL"
else
    log "Building kernel $MICROVM_KERNEL_VERSION"
    "$scripts/build-microvm-kernel.sh" "$MICROVM_KERNEL_VERSION" "$MICROVM_KERNEL"
fi

if [[ -e $MICROVM_IMAGE ]]; then
    log "Reusing image $MICROVM_IMAGE"
else
    log "Building image $MICROVM_IMAGE"
    "$scripts/prepare-ubuntu-rootfs.sh" "$archive" "$MICROVM_IMAGE" \
        "$MICROVM_IMAGE_SIZE" "$MICROVM_SSH_KEY"
fi

printf '\nBoot with: %q %q %q\n' "$scripts/boot-ubuntu-microvm.sh" "$MICROVM_KERNEL" "$MICROVM_IMAGE"
