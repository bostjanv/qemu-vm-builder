#!/usr/bin/env bash
# Build everything needed to boot a microVM: download the Debian root
# filesystem, build the kernel, and build the root filesystem image. Steps
# whose output already exists are skipped.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: build.sh [CONFIG]

Reads settings from CONFIG (default: ./vm.conf, if it exists). See
vm.conf.example for every setting. Environment variables override the file.

Outputs that already exist (kernel, image, Debian download) are reused;
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
        # setting is NAME=value.
        # shellcheck disable=SC2163
        export "$setting"
    done
elif (( $# == 1 )); then
    die "config file not found: $config"
fi

export MICROVM_DEBIAN_RELEASE=${MICROVM_DEBIAN_RELEASE:-trixie}
export MICROVM_KERNEL_VERSION=${MICROVM_KERNEL_VERSION:-6.18.63}
export MICROVM_BUILD_DIR=${MICROVM_BUILD_DIR:-build}
export MICROVM_KERNEL=${MICROVM_KERNEL:-$MICROVM_BUILD_DIR/bzImage}
export MICROVM_IMAGE=${MICROVM_IMAGE:-$MICROVM_BUILD_DIR/image.raw}
export MICROVM_IMAGE_SIZE=${MICROVM_IMAGE_SIZE:-8G}
export MICROVM_SSH_KEY=${MICROVM_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}
export MICROVM_SSH_PORT=${MICROVM_SSH_PORT:-2222}

if ! [[ $MICROVM_SSH_PORT =~ ^[0-9]+$ ]] ||
        (( 10#$MICROVM_SSH_PORT < 1024 || 10#$MICROVM_SSH_PORT > 65535 )); then
    die "MICROVM_SSH_PORT must be between 1024 and 65535: $MICROVM_SSH_PORT"
fi

release=$MICROVM_DEBIAN_RELEASE
[[ $release =~ ^[a-z]+$ ]] || die "invalid MICROVM_DEBIAN_RELEASE: $release"
# The root filesystem of Debian's official Docker image, built by debuerreotype.
# The OCI manifest next to it holds its SHA256 digest.
base_url=https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-amd64/$release/oci/blobs
archive=$MICROVM_BUILD_DIR/debian-$release-amd64-rootfs.tar.gz

mkdir -p -- "$MICROVM_BUILD_DIR"
if [[ -s $archive ]]; then
    log "Reusing $archive"
else
    log "Downloading Debian $release root filesystem"
    download=$(mktemp "$MICROVM_BUILD_DIR/.download.XXXXXXXX")
    trap 'rm -f -- "$download"' EXIT
    manifest=$(curl --fail --location --silent --show-error "$base_url/image-manifest.json") || \
        die "cannot download $base_url/image-manifest.json (is $release a Debian release?)"
    checksum=$(sed -n 's/.*"layers":\[[^]]*"digest":"sha256:\([0-9a-f]\{64\}\)".*/\1/p' <<<"$manifest")
    [[ $checksum =~ ^[0-9a-f]{64}$ ]] || die "no layer digest in $base_url/image-manifest.json"
    curl --fail --location --show-error --retry 3 --output "$download" "$base_url/rootfs.tar.gz"
    printf '%s  %s\n' "$checksum" "$download" | sha256sum -c --status || \
        die "checksum mismatch for the Debian $release root filesystem"
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
    "$scripts/prepare-debian-rootfs.sh" "$archive" "$MICROVM_IMAGE" \
        "$MICROVM_IMAGE_SIZE" "$MICROVM_SSH_KEY"
fi

printf '\nBoot with: %q %q %q %q\n' "$scripts/boot-debian-microvm.sh" \
    "$MICROVM_KERNEL" "$MICROVM_IMAGE" "$MICROVM_SSH_PORT"
printf 'SSH with:  ssh -p %s %s@127.0.0.1\n' "$MICROVM_SSH_PORT" "${MICROVM_USER:-$(id -un)}"
