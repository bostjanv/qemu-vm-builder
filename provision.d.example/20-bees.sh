#!/usr/bin/env bash
# Example provisioning script: build and install bees, the Btrfs deduplication
# daemon (https://github.com/Zygo/bees), and run it on the root filesystem.
# Ubuntu has no bees package, so it is built from source. The latest release,
# v0.11, does not compile with Ubuntu 26.04's glibc, so a newer commit is pinned.
set -Eeuo pipefail

commit=2d53565c74d3b1db9e035f55c5d67868147b568f
sha256=1ebfe2fe4cfd50f147c45c370de78308ce1e1e5e94eedd68f16839bfbb092b4c

# beesd needs uuidparse; btrfs-progs is already in the base image.
apt-get install -y --no-install-recommends uuid-runtime

# Install only the build tools that are missing, and remove them afterwards.
build_deps=()
for package in curl g++ make; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' ||
        build_deps+=("$package")
done
if (( ${#build_deps[@]} )); then
    apt-get install -y --no-install-recommends "${build_deps[@]}"
fi

src=$(mktemp -d)
curl --fail --location --silent --show-error --output "$src/bees.tar.gz" \
    "https://github.com/Zygo/bees/archive/$commit.tar.gz"
printf '%s  %s\n' "$sha256" "$src/bees.tar.gz" | sha256sum -c --status
tar -xzf "$src/bees.tar.gz" -C "$src" --strip-components=1

# DEFAULT_MAKE_TARGET=all skips the tests and the documentation.
make -C "$src" -j "$(nproc)" install DEFAULT_MAKE_TARGET=all \
    BEES_VERSION="${commit:0:7}" PREFIX=/usr/local \
    SYSTEMD_SYSTEM_UNIT_DIR=/usr/local/lib/systemd/system
rm -rf -- "$src"

if (( ${#build_deps[@]} )); then
    apt-get purge -y --auto-remove "${build_deps[@]}"
fi

# beesd@UUID.service needs the filesystem UUID, which mkfs.btrfs creates
# after provisioning. This unit writes the bees config and enables the
# service on the first boot.
cat >/usr/local/sbin/bees-enable-root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
uuid=$(findmnt -no UUID /)
size=$(findmnt -bno SIZE /)
# 16 bytes of hash table per 4 KiB block, rounded up to a multiple of 128 KiB.
db_size=$(( (size / 256 + 131071) / 131072 * 131072 ))
udevadm wait --timeout=60 "/dev/disk/by-uuid/$uuid"
install -d -m 755 /etc/bees
printf 'UUID=%s\nDB_SIZE=%s\n' "$uuid" "$db_size" >/etc/bees/root.conf
systemctl enable --now --no-block "beesd@$uuid.service"
EOF
chmod 755 /usr/local/sbin/bees-enable-root

cat >/etc/systemd/system/bees-enable-root.service <<'EOF'
[Unit]
Description=Enable bees deduplication on the root filesystem
ConditionPathExists=!/etc/bees/root.conf
After=local-fs.target systemd-udev-trigger.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bees-enable-root

[Install]
WantedBy=multi-user.target
EOF
systemctl enable bees-enable-root.service
