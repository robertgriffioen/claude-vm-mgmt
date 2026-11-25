#!/bin/bash
# Checks that the setup works and that its limits hold. Run as the user Claude runs as, outside the sandbox (after
# install-user.sh). From Claude, the libvirt checks fail because the virsh calls in this script run inside the
# sandbox; see README, step 4. Changes nothing, except a short-lived test VM (claude-check) that it removes again.
set -uo pipefail

BRIDGE=virbr-pgv
POOL=vms
URI=qemu:///session
TEST_VM="claude-check-$(cat /proc/sys/kernel/random/uuid)"
FAILED=0

ok() { echo "OK    $1"; }
fail() {
  echo "FAIL  $1"
  FAILED=1
}
check() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "${what}"; else fail "${what}"; fi
}
check_not() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "${what}"; else ok "${what}"; fi
}

echo "== Limits"
# From the group database, not `id -nG`: inside Claude's sandbox the process shows no groups
check_not "not in the libvirt group" bash -c "getent group libvirt | cut -d: -f4 | tr ',' '\n' | grep -qx \"$(id -un)\""
check_not "no access to qemu:///system" virsh -c qemu:///system list --all
check_not "not root" test "$(id -u)" = 0

echo "== Setup"
check "/etc/qemu/bridge.conf allows ${BRIDGE}" grep -qx "allow ${BRIDGE}" /etc/qemu/bridge.conf
check "qemu-bridge-helper is setuid" test -u /usr/lib/qemu/qemu-bridge-helper
check "in the vm-bridge group (may run the bridge helper)" bash -c "getent group vm-bridge | cut -d: -f4 | tr ',' '\n' | grep -qx \"$(id -un)\""
check "${URI} answers" virsh -c ${URI} uri
check "KVM is available to ${URI}" virsh -c ${URI} domcapabilities --virttype kvm
for pool in ${POOL} images; do
  check "storage pool ${pool} is running" bash -c "virsh -c ${URI} pool-info ${pool} | grep -Eq '^State:\s+running'"
done
check "/usr/local/bin/vm-ssh is root:root 755" test "$(stat -c '%U %G %a' /usr/local/bin/vm-ssh 2>&1)" = "root root 755"
check "/usr/local/bin/vm-ssh is the same as bin/vm-ssh" cmp -s "$(dirname "$0")/bin/vm-ssh" /usr/local/bin/vm-ssh
check "ssh key ~/.ssh/pgv_ed25519 exists" test -s "${HOME}/.ssh/pgv_ed25519" -a -s "${HOME}/.ssh/pgv_ed25519.pub"
check_not "vm-ssh refuses a host outside the network" /usr/local/bin/vm-ssh nobody@github.com true

echo "== A test VM on ${BRIDGE} (no disk; it only tries a network boot)"
virsh -c ${URI} destroy ${TEST_VM} >/dev/null 2>&1
virsh -c ${URI} undefine ${TEST_VM} >/dev/null 2>&1
if virt-install --connect ${URI} --name ${TEST_VM} --memory 256 --vcpus 1 --virt-type kvm --pxe --disk none \
  --network bridge=${BRIDGE} --graphics none --noautoconsole --osinfo detect=on,require=off >/dev/null 2>&1; then
  ok "test VM starts with KVM, attached to ${BRIDGE}"
else
  fail "test VM starts with KVM, attached to ${BRIDGE} (run the virt-install command by hand to see why)"
fi
virsh -c ${URI} destroy ${TEST_VM} >/dev/null 2>&1
virsh -c ${URI} undefine ${TEST_VM} >/dev/null 2>&1

echo
if [ ${FAILED} = 0 ]; then echo "All checks passed"; else echo "Some checks failed"; fi
exit ${FAILED}
