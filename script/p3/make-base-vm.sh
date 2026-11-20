#!/usr/bin/env bash
# Makes the Tart test VM `mastbound-base` again (deleted to free disk space).
#
#   script/p3/make-base-vm.sh
#
# Downloads the Cirrus macos-tahoe-vanilla image (about 25 GB; it needs
# about 30 GB free), starts it once without a window, and adds the test key
# ~/.ssh/mastbound_vm. ssh-copy-id asks for the VM's password once: the
# Cirrus image's default user is admin/admin. That image already gives
# `admin` sudo without a password.
#
# The other scripts in script/p3 clone their own disposable copies from it.
set -euo pipefail
VM="${VM:-mastbound-base}"
IMAGE="${IMAGE:-ghcr.io/cirruslabs/macos-tahoe-vanilla:latest}"
KEY="$HOME/.ssh/mastbound_vm"

[[ -f "$KEY" ]] || ssh-keygen -t ed25519 -N "" -f "$KEY" -C mastbound-vm-test
if tart list | awk '{print $2}' | grep -qx "$VM"; then
  echo "$VM already exists"; exit 0
fi
tart clone "$IMAGE" "$VM"
tart run --no-graphics "$VM" >/dev/null 2>&1 &
trap 'tart stop "$VM" >/dev/null 2>&1 || true' EXIT
ip=""
for _ in $(seq 1 60); do ip="$(tart ip "$VM" 2>/dev/null)" && break; sleep 3; done
[[ -n "$ip" ]] || { echo "the VM did not get an address" >&2; exit 1; }
for _ in $(seq 1 60); do nc -z "$ip" 22 2>/dev/null && break; sleep 3; done
ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new "admin@$ip"
ssh -i "$KEY" -o BatchMode=yes "admin@$ip" 'sudo -n true && echo "key and sudo work"'
echo "made $VM"
