# claude-vm-mgmt

Lets Claude Code create, run and remove KVM virtual machines using an unprivileged, dedicated Linux account, without granting root-equivalent access to the physical host or system libvirt management.

## The idea

Claude Code runs as its own user (here: `ted`) in a sandbox. It gets VMs through **libvirt in session mode**
(`qemu:///session`): a libvirtd that runs as that user, with VMs that run as that user.

The session libvirt daemon and its QEMU processes run with the privileges of the dedicated Linux user. Arbitrary VM configurations do not inherently grant additional host privileges. The QEMU bridge helper is an explicitly delegated privileged operation.

The alternative, the system libvirt (`qemu:///system`, via the `libvirt` group), is effectively root: a VM's XML can
pass any host disk or device to the VM. Polkit rules can limit which VMs and networks a user may manage, but not what
a VM's XML contains, so they don't close that.

| Part | Runs as | Can do |
|------|---------|--------|
| The `pgvillage` network (bridge `virbr-pgv`) | root (system libvirt) | NAT, DHCP and DNS for the VMs. Only root changes it. |
| `qemu-bridge-helper` (setuid root) | root | Only one thing: attach a VM's network card to a bridge in `/etc/qemu/bridge.conf` |
| libvirtd (session), as a user service | `ted` | Manage `ted`'s VMs, networks of its own (none needed), storage pool `vms` |
| The VMs (qemu) | `ted` | What `ted` can: its own files, `/dev/kvm` |
| Claude Code (sandboxed) | `ted` | Talk to the session libvirtd over its socket |

Why the session libvirtd runs as a user service, and not started by `virsh` (the default for session mode): Claude's
sandbox hides `/dev/kvm` and has its own network, so a libvirtd started from the sandbox couldn't run VMs. The user
service runs outside the sandbox; Claude only gets its socket.


## Security boundary

The dedicated Linux account is the primary security boundary. The session libvirt daemon runs outside Claude's sandbox, so access to its socket may allow Claude to indirectly access files, devices and network resources available to the dedicated account but restricted by the sandbox.

This is accepted by design. The objective is to prevent host privilege escalation, not to restrict Claude to a particular directory or set of VM management commands.

## Setup

### 1. As root: `install-root.sh`

```bash
sudo ./install-root.sh
```

| Step | What | Why |
|------|------|-----|
| 1 | `ted` into the `kvm` and `vm-bridge` groups | `/dev/kvm` for the VMs; `vm-bridge` may run the bridge helper (step 4) |
| 2 | `loginctl enable-linger ted` | `ted`'s user services (libvirtd, and so the VMs) keep running without a login |
| 3 | Network `pgvillage` from `network/pgvillage.xml`, started and autostarted | The VMs' network: `192.168.130.0/24`, NAT, DHCP `.100`-`.199`, DNS `<hostname>.pgv.internal`. `.2`-`.99` are free for static addresses and VIPs. Not bridged to the LAN. |
| 4 | `allow virbr-pgv` in `/etc/qemu/bridge.conf`, `qemu-bridge-helper` setuid root and only executable for `vm-bridge` (`root:vm-bridge 4750`, with `dpkg-statoverride`, so updates keep it) | Session VMs can't create network devices themselves; the helper does it for them, only for allowed bridges |

The group changes apply to new logins: restart `ted`'s user manager when no Claude session runs
(`sudo systemctl restart user@$(id -u ted).service`), or reboot.

Note: step 4 allows the members of `vm-bridge` to attach VMs to `virbr-pgv`. That is the only thing it allows.

### 2. As `ted`, outside the sandbox: `install-user.sh`

```bash
sudo -u ted XDG_RUNTIME_DIR=/run/user/$(id -u ted) ./install-user.sh
```

| Step | What | Why |
|------|------|-----|
| 1 | User service `libvirtd-session.service` (`~/.config/systemd/user/`) | The session libvirtd, outside the sandbox. `KillMode=process`: restarting libvirtd doesn't stop the VMs. |
| 2 | Storage pool `vms` in `~/vms` | Where the VM disks and images live, owned by `ted` |

### 3. Claude Code settings

In `~/.claude/settings.json` (Claude can't change this file):

```json
{
  "sandbox": {
    "network": {
      "allowUnixSockets": ["/run/user/1001/libvirt/libvirt-sock"]
    }
  },
  "env": {
    "LIBVIRT_DEFAULT_URI": "qemu:///session",
    "LIBVIRT_AUTOSTART": "0"
  }
}
```

- `allowUnixSockets`: only the socket of `ted`'s session libvirtd (1001 is `ted`'s uid).
- `LIBVIRT_DEFAULT_URI`: `virsh` and `virt-install` use the session without `-c`.
- `LIBVIRT_AUTOSTART=0`: when the user service isn't running, `virsh` fails instead of starting a libvirtd inside the
  sandbox.

No file access is needed: disks are created through libvirt (`vol-create`, `vol-upload`), which writes them as the
session libvirtd.

### 4. Check

```bash
./check.sh
```

Run it as `ted` outside the sandbox after step 2, and let Claude run it after step 3. It checks the limits (not in the
`libvirt` group, no access to `qemu:///system`) and the setup, and starts and removes a test VM on `virbr-pgv`.

## Not (yet) covered

- **ssh from Claude to the VMs**: the sandbox's network can't reach `virbr-pgv`.
- **Downloading cloud images** from Claude: the image sites aren't on the sandbox's allowed domains.
- **Seeing the VMs in virt-manager as another user**: they are `ted`'s VMs. virt-manager can connect to
  `qemu+ssh://ted@localhost/session`, if `ted` accepts ssh logins.

## Undo

```bash
# as ted
systemctl --user disable --now libvirtd-session.service
rm ~/.config/systemd/user/libvirtd-session.service
# as root
sed -i '/^allow virbr-pgv$/d' /etc/qemu/bridge.conf
dpkg-statoverride --remove /usr/lib/qemu/qemu-bridge-helper
chown root:root /usr/lib/qemu/qemu-bridge-helper && chmod 0755 /usr/lib/qemu/qemu-bridge-helper
gpasswd -d ted vm-bridge && groupdel vm-bridge
virsh -c qemu:///system net-destroy pgvillage; virsh -c qemu:///system net-undefine pgvillage
loginctl disable-linger ted
```

Remove the settings of step 3. The VMs and disks in `~/vms` are `ted`'s; remove them with `virsh` before the user
service.
