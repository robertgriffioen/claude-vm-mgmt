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
BRIDGE_GROUP=vm-bridge
HELPER=/usr/lib/qemu/qemu-bridge-helper
DIR=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = 0 ] || { echo "Run this with sudo" >&2; exit 1; }
id "${CLAUDE_USER}" >/dev/null


echo "0. Verify security prerequisites for ${CLAUDE_USER}"

GROUPS_LIST=$(id -nG "${CLAUDE_USER}" | tr ' ' '\n')

for group in sudo libvirt docker lxd disk; do
  if grep -qx "${group}" <<< "${GROUPS_LIST}"; then
    echo "ERROR: ${CLAUDE_USER} belongs to privileged group ${group}" >&2
    exit 1
  fi
done

SUDO_PERMISSIONS=$(LC_ALL=C sudo -l -U "${CLAUDE_USER}" 2>&1 || true)

if ! grep -Fq "User ${CLAUDE_USER} is not allowed to run sudo" <<< "${SUDO_PERMISSIONS}"; then
  echo "ERROR: Cannot confirm that ${CLAUDE_USER} has no sudo privileges" >&2
  echo "${SUDO_PERMISSIONS}" >&2
  exit 1
fi

echo "1. Groups of ${CLAUDE_USER}: kvm (to run VMs) and ${BRIDGE_GROUP} (to run the QEMU bridge helper)."
# Not libvirt (full access to qemu:///system): step 0 stops when ${CLAUDE_USER} is in it.
usermod -aG kvm "${CLAUDE_USER}"

if ! getent group "${BRIDGE_GROUP}" >/dev/null; then
  groupadd --system "${BRIDGE_GROUP}"
fi
usermod -aG "${BRIDGE_GROUP}" "${CLAUDE_USER}"


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

echo "4. qemu-bridge-helper may attach VMs of ${BRIDGE_GROUP} members to ${BRIDGE}, and only to that bridge"

mkdir -p /etc/qemu

# Create the bridge configuration or validate the existing one.
if [ ! -e /etc/qemu/bridge.conf ]; then
  echo "allow ${BRIDGE}" >/etc/qemu/bridge.conf
elif [ "$(cat /etc/qemu/bridge.conf)" != "allow ${BRIDGE}" ]; then
  echo "ERROR: Unexpected configuration in /etc/qemu/bridge.conf" >&2
  exit 1
fi

chown root:root /etc/qemu/bridge.conf
chmod 0644 /etc/qemu/bridge.conf

# Setuid root, registered with dpkg so a qemu update keeps it.
if ! dpkg-statoverride --list "${HELPER}" >/dev/null; then
  dpkg-statoverride --update --add root "${BRIDGE_GROUP}" 4750 "${HELPER}"
elif [ "$(dpkg-statoverride --list "${HELPER}")" != "root ${BRIDGE_GROUP} 4750 ${HELPER}" ]; then
  echo "ERROR: Unexpected dpkg-statoverride for ${HELPER}" >&2
  exit 1
fi

# Verify the actual ownership and permissions.
if [ "$(stat -c '%U %G %a' "${HELPER}")" != "root ${BRIDGE_GROUP} 4750" ]; then
  echo "ERROR: Unexpected ownership or permissions on ${HELPER}" >&2
  exit 1
fi

echo "5. vm-ssh in /usr/local/bin, root-owned: Claude runs it outside its sandbox, so Claude must not be able to change it"
command -v dig >/dev/null || { echo "ERROR: dig is missing (apt install bind9-dnsutils)" >&2; exit 1; }
install -o root -g root -m 0755 "${DIR}/bin/vm-ssh" /usr/local/bin/vm-ssh

echo
echo "Done. The group changes apply to new logins of ${CLAUDE_USER}: restart its user manager"
echo "(sudo systemctl restart user@$(id -u "${CLAUDE_USER}").service) when no Claude session runs, or reboot."
echo "Next: ./install-user.sh as ${CLAUDE_USER} (see README.md)."
