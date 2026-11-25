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
| Claude Code (sandboxed) | `ted` | Talk to the session libvirtd over its socket (`virsh`, `virt-install`); ssh to the VMs (`vm-ssh`) |
| `vm-ssh` (`/usr/local/bin`, root-owned) | `ted` | Only ssh to `192.168.130.2`-`254`, with fixed options and its own key |

Why the session libvirtd runs as a user service, and not started by `virsh` (the default for session mode): Claude's
sandbox hides `/dev/kvm` and has its own network, so a libvirtd started from the sandbox couldn't run VMs. The user
service runs outside the sandbox; Claude only gets its socket.


## Security boundary

The dedicated Linux account is the primary security boundary. The session libvirt daemon runs outside Claude's sandbox, so access to its socket may allow Claude to indirectly access files, devices and network resources available to the dedicated account but restricted by the sandbox.

This is accepted by design. The objective is to prevent host privilege escalation, not to restrict Claude to a particular directory or set of VM management commands.

Claude's `virsh`, `virt-install` and `vm-ssh` commands run outside the sandbox (see step 3). A command line with a
pipe or redirect (`virsh list | grep x`, `virsh dumpxml x > file`) didn't match the exclusion and ran inside the
sandbox (seen 2026-11-25). Still, check unusual command lines before approving them.

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
| 5 | `bin/vm-ssh` installed as `/usr/local/bin/vm-ssh`, `root:root 755` | Claude runs it outside the sandbox, so Claude must not be able to change it (see "ssh to the VMs"). Needs `dig`. |

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
| 2 | Storage pools `vms` in `~/vms` and `images` in `~/images` | VM disks and downloaded cloud images, owned by `ted` |
| 3 | ssh key `~/.ssh/pgv_ed25519` | Used only by `vm-ssh`; the `.pub` goes into VMs with `virt-install --cloud-init ssh-key=...` |

### 3. Claude Code settings

In `~/.claude/settings.json` (Claude's sandbox can't write this file; Robert edits it or approves Claude's edit):

```json
{
  "sandbox": {
    "excludedCommands": ["virsh *", "virt-install *", "vm-ssh *"]
  },
  "env": {
    "LIBVIRT_DEFAULT_URI": "qemu:///session",
    "LIBVIRT_AUTOSTART": "0"
  }
}
```

- `excludedCommands`: `virsh` and `virt-install` run outside the sandbox, so they can reach the session socket.
  This only matches a command line that starts with them: not a pipe (`virsh list | grep x`), not a script that
  calls `virsh`.
- Why not `allowUnixSockets`: on Linux the sandbox blocks creating *any* unix socket (seccomp, at `socket()`, before
  a path is known), so a per-path allow has no effect. `allowAllUnixSockets` would open every socket `ted` has,
  including the systemd user manager.
- `vm-ssh *`: see "ssh to the VMs". Not `ssh *`: that would run any ssh command line outside the sandbox.
- `LIBVIRT_DEFAULT_URI`: `virsh` and `virt-install` use the session without `-c`.
- `LIBVIRT_AUTOSTART=0`: when the user service isn't running, `virsh` fails instead of starting a libvirtd inside the
  sandbox.

No file access is needed: disks are created through libvirt (`vol-create`, `vol-upload`), which writes them as the
session libvirtd.

### 4. Check

```bash
./check.sh
```

Run it as `ted` outside the sandbox after step 2. It checks the limits (not in the `libvirt` group, no access to
`qemu:///system`) and the setup, and starts and removes a test VM on `virbr-pgv`.

From Claude (after step 3), `check.sh` passes the limits and setup checks but fails the libvirt ones: the `virsh`
calls inside the script run in the sandbox. Claude runs those one by one instead:

```bash
virsh uri
virsh domcapabilities --virttype kvm
virsh pool-info vms
virt-install --name claude-check --memory 256 --vcpus 1 --virt-type kvm --pxe --disk none \
  --network bridge=virbr-pgv --graphics none --noautoconsole --osinfo detect=on,require=off
virsh destroy claude-check
virsh undefine claude-check
```

## ssh to the VMs

Claude's sandbox has its own network, so a plain `ssh` from Claude can't reach `virbr-pgv`. And `ssh` itself can't go
on the `excludedCommands` list: outside the sandbox it reaches any host, and options such as
`-o ProxyCommand=<command>`, `LocalCommand` or `-F <config>` run any command on the host.

So Claude uses `vm-ssh`, which runs outside the sandbox but only does this:

```bash
vm-ssh <user>@<vm> [command ...]    # <vm>: hostname in pgv.internal, or 192.168.130.2-254
```

- It accepts no ssh options. It always runs ssh with `-F /dev/null` (no ssh config), its own key
  `~/.ssh/pgv_ed25519`, no agent, no forwarding, `BatchMode`.
- It refuses any address outside `192.168.130.2`-`254`. Hostnames are looked up at the network's DNS
  (`192.168.130.1`), because the host's own resolver doesn't know `pgv.internal`.
- It puts `--` before the destination: ssh also parses options *after* the destination, so without it a "command"
  like `-oProxyCommand=...` would become an option.
- It keeps no host keys: VMs are recreated often, and the network is only reachable from this host.
- It is root-owned in `/usr/local/bin`. Claude can change `bin/vm-ssh` in this repo, so review a change to it before
  running `install-root.sh` again. `check.sh` checks that both are the same.

A VM that `vm-ssh` can reach, from a cloud image in `~/images` (tested with Rocky 9 GenericCloud):

```bash
virsh pool-refresh images
virsh vol-create-as vms node1.qcow2 20G --format qcow2 \
  --backing-vol /home/ted/images/<image> --backing-vol-format qcow2
virt-install --name node1 --memory 2048 --vcpus 2 --virt-type kvm --import \
  --disk vol=vms/node1.qcow2 --network bridge=virbr-pgv --graphics none --video vga --noautoconsole \
  --osinfo <os> --cloud-init ssh-key=/home/ted/.ssh/pgv_ed25519.pub
vm-ssh <default user of the image>@node1 uname -a
```

`--video vga` is needed: without a video card, the Rocky 9 kernel resets the VM straight after GRUB, before it
prints anything. For your own users (e.g. `sa-ted` with sudo), pass `--cloud-init user-data=<file>` instead of `ssh-key=`.

## Not (yet) covered

- **Downloading cloud images** from Claude: the image sites aren't on the sandbox's allowed domains.
- **Seeing the VMs in virt-manager as another user**: they are `ted`'s VMs. virt-manager can connect to
  `qemu+ssh://ted@localhost/session`, if `ted` accepts ssh logins.

## Undo

```bash
# as ted
systemctl --user disable --now libvirtd-session.service
rm ~/.config/systemd/user/libvirtd-session.service
rm ~/.ssh/pgv_ed25519 ~/.ssh/pgv_ed25519.pub
# as root
rm /usr/local/bin/vm-ssh
sed -i '/^allow virbr-pgv$/d' /etc/qemu/bridge.conf
dpkg-statoverride --remove /usr/lib/qemu/qemu-bridge-helper
chown root:root /usr/lib/qemu/qemu-bridge-helper && chmod 0755 /usr/lib/qemu/qemu-bridge-helper
gpasswd -d ted vm-bridge && groupdel vm-bridge
virsh -c qemu:///system net-destroy pgvillage; virsh -c qemu:///system net-undefine pgvillage
loginctl disable-linger ted
```

Remove the settings of step 3. The VMs and disks in `~/vms` are `ted`'s; remove them with `virsh` before the user
service.
