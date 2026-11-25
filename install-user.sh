#!/bin/bash
# The user part of the setup: run as the user Claude Code runs as, outside Claude's sandbox. Running it again is safe.
# See README.md for what each step does and why.
#
#   sudo -u ted XDG_RUNTIME_DIR=/run/user/$(id -u ted) ./install-user.sh
#
# VM_IMAGES is the directory of the storage pool (default: ~/vms).
set -euo pipefail

VM_IMAGES=${VM_IMAGES:-${HOME}/vms}
POOL=vms
UNIT=libvirtd-session.service
URI=qemu:///session

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

echo "2. The storage pool ${POOL} in ${VM_IMAGES}"
if ! virsh -c ${URI} pool-info ${POOL} >/dev/null 2>&1; then
  virsh -c ${URI} pool-define-as ${POOL} dir --target "${VM_IMAGES}"
  virsh -c ${URI} pool-build ${POOL}
fi
virsh -c ${URI} pool-autostart ${POOL}
if ! virsh -c ${URI} pool-info ${POOL} | grep -Eq '^State:\s+running'; then
  virsh -c ${URI} pool-start ${POOL}
fi

echo
echo "Done. Next: the Claude Code settings and ./check.sh (see README.md)."
