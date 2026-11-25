#!/bin/bash
# The user part of the setup: run as the user Claude Code runs as, outside Claude's sandbox. Running it again is safe.
# See README.md for what each step does and why.
#
#   sudo -u ted XDG_RUNTIME_DIR=/run/user/$(id -u ted) ./install-user.sh
#
# VM_IMAGES is the directory of the storage pool for VM disks (default: ~/vms), IMAGES the one for downloaded cloud
# images (default: ~/images).
set -euo pipefail

VM_IMAGES=${VM_IMAGES:-${HOME}/vms}
IMAGES=${IMAGES:-${HOME}/images}
UNIT=libvirtd-session.service
URI=qemu:///session
KEY=${HOME}/.ssh/pgv_ed25519

# A dir storage pool <name> in <dir>, autostarted and running
pool() {
  local name=$1 dir=$2
  if ! virsh -c ${URI} pool-info "${name}" >/dev/null 2>&1; then
    virsh -c ${URI} pool-define-as "${name}" dir --target "${dir}"
    virsh -c ${URI} pool-build "${name}"
  fi
  virsh -c ${URI} pool-autostart "${name}"
  if ! virsh -c ${URI} pool-info "${name}" | grep -Eq '^State:\s+running'; then
    virsh -c ${URI} pool-start "${name}"
  fi
}

[ "$(id -u)" != 0 ] || { echo "Run this as the user Claude runs as, not as root" >&2; exit 1; }
[ -n "${XDG_RUNTIME_DIR:-}" ] || { echo "XDG_RUNTIME_DIR is not set (see the usage at the top)" >&2; exit 1; }

echo "1. A user service that runs libvirtd for ${URI}"
mkdir -p ~/.config/systemd/user
cat >~/.config/systemd/user/${UNIT} <<'EOF'
# Installed by claude-vm-mgmt/install-user.sh
[Unit]
Description=libvirt session daemon (qemu:///session), outside Claude's sandbox

[Service]
# Without --timeout it keeps running (when virsh starts it, it stops after 120 s without VMs)
ExecStart=/usr/sbin/libvirtd
# Stopping or restarting libvirtd leaves the VMs (qemu processes) running
KillMode=process
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now ${UNIT}
# Wait for the socket
for _ in $(seq 1 10); do
  [ -S "${XDG_RUNTIME_DIR}/libvirt/libvirt-sock" ] && break
  sleep 1
done

echo "2. The storage pools vms in ${VM_IMAGES} (VM disks) and images in ${IMAGES} (cloud images)"
pool vms "${VM_IMAGES}"
pool images "${IMAGES}"

echo "3. The ssh key for the VMs: ${KEY} (used by vm-ssh; virt-install puts the .pub into a VM with --cloud-init)"
mkdir -p -m 0700 ~/.ssh
[ -e "${KEY}" ] || ssh-keygen -q -t ed25519 -N '' -C claude-vm-mgmt -f "${KEY}"

echo
echo "Done. Next: the Claude Code settings and ./check.sh (see README.md)."
