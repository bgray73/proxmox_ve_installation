# Monthly patch run: PVE cluster + PBS

Routine patching, node by node, without losing quorum or guests. Budget
30–60 minutes. If anything goes badly sideways, stop and open
`docs/DISASTER-RECOVERY.md`.

## 1. Pre-flight (from any PVE node)

- [ ] Quorum healthy: `pvecm status` shows 3 nodes, `Quorate: Yes`.
- [ ] Last night's backups are green (PBS web UI, or on pbs01:
      `proxmox-backup-manager task list --limit 20`).
- [ ] Nothing running right now: no backup, restore, PBS verify/GC, or ZFS
      scrub in progress (`zpool status` on each node shows no scrub).
- [ ] HA guests noted: `ha-manager status` (only if HA is enabled via
      `automation/terraform/ha.tf`).
- [ ] UPS sane: `upsc <ups-name> ups.status` on pbs01 shows `OL`
      (on line) — not `OB` or `LB`. See `docs/POWER-NUT.md`.
- [ ] No storm in the forecast. Do not start a patch window you can't finish.

## 2. Check the apt repos before you touch anything

The installer leaves the **enterprise** repo enabled; without a
subscription key that repo 404s and `apt update` errors out. Homelabs
normally switch to **no-subscription**. Either is fine — what matters is
that every node uses the same one and you never mix them.

```bash
# On every PVE node (pve01..pve03):
grep -rh '^deb' /etc/apt/sources.list.d/ | sort -u
# Enterprise: deb https://enterprise.proxmox.com/debian/pve trixie pve-enterprise
#   (file: /etc/apt/sources.list.d/pve-enterprise.list)
# No-subscription: deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
#   (file: /etc/apt/sources.list.d/pve-no-subscription.list)

# On pbs01:
grep -rh '^deb' /etc/apt/sources.list.d/ | sort -u
# Enterprise: deb https://enterprise.proxmox.com/debian/pbs trixie pbs-enterprise
#   (file: /etc/apt/sources.list.d/pbs-enterprise.list)
# No-subscription: deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription
#   (file: /etc/apt/sources.list.d/pbs-no-subscription.list)
```

To switch a node to no-subscription (one time):

```bash
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list   # or pbs-enterprise.list
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
# PBS equivalent: .../debian/pbs trixie pbs-no-subscription
```

Also confirm disk space for new kernels: `df -h / /boot` — `/boot`
below ~200 MB free means run `apt autoremove` first.

## 3. PBS first: pbs01

PBS is standalone — not a cluster member — so patching it carries zero
quorum risk. Doing it first also means the backup target is current and
healthy before you start cycling the nodes that back up to it.

```bash
ssh root@pbs01
apt update && apt full-upgrade -y
reboot
```

After it comes back:

- [ ] `https://<pbs01>:8007` loads.
- [ ] Datastore mounted and visible: `proxmox-backup-manager datastore list`.
- [ ] `zpool status` shows the datastore pool `ONLINE`.

## 4. PVE nodes, strictly one at a time

Repeat this block for pve01, then pve02, then pve03. Never start the
next node until the current one is fully back and quorate.

```bash
NODE=pve01   # then pve02, then pve03
TARGET=pve02  # a node that is NOT being patched
```

**a. Empty the node.** Relocate every guest off `$NODE`:

```bash
# If HA manages the guest:
ha-manager migrate ct:204 $TARGET     # or vm:<vmid>

# Otherwise, by hand (VMs live-migrate; LXCs restart-migrate):
qm migrate <vmid> $TARGET --online
pct migrate <vmid> $TARGET
```

`qm list` / `pct list` on `$NODE` should show nothing running afterward.

**b. Patch and reboot.**

```bash
ssh root@$NODE
apt update && apt full-upgrade -y
reboot
```

**c. Verify before moving on.**

- [ ] `pvecm status` (from another node): `$NODE` listed, `Quorate: Yes`.
- [ ] `pveversion` on `$NODE` matches the other nodes.
- [ ] Guests are where you expect them (migrate any back if you care
      about placement: `qm migrate <vmid> $NODE --online`).

**If a node doesn't come back:** with 2 of 3 nodes up you still have
quorum, so don't panic. Check iDRAC console, confirm the corosync link
(VLAN 21) is up, and read `journalctl -u corosync -u pve-cluster` on the
sick node. Do **not** run `pvecm expected 1` unless you are certain the
third node is truly dead and you accept the split-brain risk. If the
node is unrecoverable, the rebuild path is `docs/DISASTER-RECOVERY.md`.

## 5. Post-flight

- [ ] `pvecm status`: 3 nodes, quorate. `pveversion` consistent everywhere.
- [ ] Backup jobs still scheduled: Datacenter → Backup shows the expected
      jobs (schedules live in cluster config and must be re-created after
      any rebuild — see `docs/DISASTER-RECOVERY.md`).
- [ ] One manual backup to prove the pipeline: from any PVE node,
      `vzdump <vmid> --storage pbs --mode snapshot`, then confirm it
      lands in the PBS datastore.
- [ ] ntfy still flows: `curl -d "patch window complete" http://10.10.41.14/proxmox-alerts`
      (topic per `docs/NOTIFICATIONS.md`).
- [ ] Optional cleanup on each node: `apt autoremove` (old kernels eat
      `/boot` over time).

## 6. Never

- **Never patch two nodes at once.** Two nodes down = no quorum (2 of 3
  required) = cluster stops making decisions, HA fencing can fire.
- **Never reboot with an active backup, restore, PBS verify/GC, or ZFS
  scrub.** Check first; reschedule the job if needed.
- **Never jump a Debian major version** (trixie → next) as part of
  routine patching. Major upgrades are a project: read the Proxmox
  upgrade wiki, snapshot/back up everything, and do it on a quiet
  weekend — not in this runbook.
- **Never patch on battery power or with a storm warning.** NUT will
  shut the cluster down mid-upgrade if the UPS hits low battery
  (that's its job — see `docs/POWER-NUT.md`).
