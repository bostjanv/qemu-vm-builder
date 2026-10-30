#!/usr/bin/env bash

set -euo pipefail

ARCH=x86_64
S3=https://s3.amazonaws.com/spec.ccfc.min

# Find the latest CI artifacts.
CI_ARTIFACTS_PREFIX=$(
    curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" |
    grep -oP '(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)' |
    sort |
    tail -1
)

# Find the latest kernel.
KERNEL_KEY=$(
    curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-" |
    grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" |
    sort -V |
    tail -1
)

# Download it.
wget "$S3/$KERNEL_KEY"
