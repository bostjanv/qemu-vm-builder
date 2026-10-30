#!/usr/bin/env bash
# Example provisioning script. Runs as root inside the guest while the image
# is built, with network access. MICROVM_USER and MICROVM_HOSTNAME are set.
set -Eeuo pipefail

apt-get install -y --no-install-recommends git curl vim less

# Files in the user's home must belong to the user, not root.
home=/home/$MICROVM_USER
cat >>"$home/.bashrc" <<'EOF'

alias ll='ls -l'
export EDITOR=vim
EOF
install -d -o "$MICROVM_USER" -g "$MICROVM_USER" -m 755 "$home/src"
