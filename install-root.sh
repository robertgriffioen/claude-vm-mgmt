#!/bin/bash
# The root part of the setup: run once with sudo. Running it again is safe.
# See README.md for what each step does and why.
#
#   sudo ./install-root.sh
#
# CLAUDE_USER is the user Claude Code runs as (default: ted).
set -euo pipefail

CLAUDE_USER=${CLAUDE_USER:-ted}
NETWORK=pgvillage
BRIDGE=virbr-pgv
HELPER=/usr/lib/qemu/qemu-bridge-helper
DIR=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = 0 ] || { echo "Run this with sudo" >&2; exit 1; }
id "${CLAUDE_USER}" >/dev/null

echo "1. Groups of ${CLAUDE_USER}: kvm (to run VMs), not libvirt (full access to qemu:///system)"
usermod -aG kvm "${CLAUDE_USER}"
if id -nG "${CLAUDE_USER}" | tr ' ' '\n' | grep -qx libvirt; then
  gpasswd -d "${CLAUDE_USER}" libvirt
fi

echo "2. Lingering for ${CLAUDE_USER}: its user services (libvirtd, the VMs) keep running without a login"
loginctl enable-linger "${CLAUDE_USER}"

echo "3. The ${NETWORK} network in qemu:///system (bridge ${BRIDGE})"
if ! virsh -c qemu:///system net-info "${NETWORK}" >/dev/null 2>&1; then
  virsh -c qemu:///system net-define "${DIR}/network/${NETWORK}.xml"
fi
virsh -c qemu:///system net-autostart "${NETWORK}"
if ! virsh -c qemu:///system net-info "${NETWORK}" | grep -Eq '^Active:\s+yes'; then
  virsh -c qemu:///system net-start "${NETWORK}"
fi

echo "4. qemu-bridge-helper may attach VMs of any user to ${BRIDGE}, and only to that bridge"
mkdir -p /etc/qemu
touch /etc/qemu/bridge.conf
grep -qx "allow ${BRIDGE}" /etc/qemu/bridge.conf || echo "allow ${BRIDGE}" >>/etc/qemu/bridge.conf
chown root:root /etc/qemu/bridge.conf
chmod 0644 /etc/qemu/bridge.conf
# setuid root, registered with dpkg so a qemu update keeps it
if ! dpkg-statoverride --list "${HELPER}" >/dev/null; then
  dpkg-statoverride --update --add root root 4755 "${HELPER}"
fi

echo
echo "Done. The group changes apply to new logins of ${CLAUDE_USER}: restart its user manager"
echo "(sudo systemctl restart user@$(id -u "${CLAUDE_USER}").service) when no Claude session runs, or reboot."
echo "Next: ./install-user.sh as ${CLAUDE_USER} (see README.md)."
