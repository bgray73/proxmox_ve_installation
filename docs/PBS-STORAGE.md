# PBS storage design checklist

Finalize this only after the Supermicro disk inventory and controller mode are known.

## Recommended physical layout

- Use two small mirrored SSDs for the PBS operating system.
- Put backup data on a separate redundant datastore.
- Choose exactly one storage model:
  - **ZFS** with disks directly exposed by an HBA/IT/JBOD controller; or
  - **ext4/XFS** on a hardware RAID controller with protected write cache.
- Never put ZFS on top of a hardware RAID virtual disk. Proxmox recommends either redundant ZFS or hardware RAID with protected write cache, and explicitly identifies the two as separate designs.[2][7]
- For HDD datastores, strongly consider a mirrored enterprise-SSD ZFS special device for metadata. A special device must be redundant because losing it can lose the pool, and adding one cannot be undone.[7][8]

## Memory and network

- Baseline PBS sizing is at least 4 GiB for the OS, cache, and daemons, plus roughly 1 GiB per TiB of storage.[8]
- For ZFS, start with at least 8 GiB and prefer ECC RAM.[7]
- Use the dedicated backup VLAN and the fastest practical server/switch links. Keep management traffic separate from backup data.

## Datastore requirements and cautions

- Normal PBS datastores are directories on ext4, XFS, or ZFS.[6]
- Do not operate one datastore concurrently from multiple PBS instances.[6]
- Keep the default garbage-collection atime safety check enabled, especially with nonstandard storage.[6]
- Do not treat the local PBS as the only backup copy. Plan periodic synchronization to another/off-site PBS, tape, or another independent medium as part of a 3-2-1 strategy.[6]
- Schedule pruning, garbage collection, verification, and regular test restores.

## Safe commissioning order

1. Record every disk model, serial, size, slot, and controller presentation.
2. Decide HBA/JBOD + ZFS versus hardware RAID + ext4/XFS.
3. Install PBS only onto the mirrored OS devices.
4. Create and mount the backup filesystem separately.
5. Confirm the intended mount with `findmnt` and disk serials.
6. Run `post-deploy/create_pbs_datastore.sh NAME /mount/path`.
7. Create a least-privilege backup API token and register PBS in PVE.
8. Run a backup, verification, and full test restore before considering the system production-ready.

## Sources

[2] https://pbs.proxmox.com/docs/installation.html — Proxmox Backup Server Installation
[6] https://pbs.proxmox.com/docs/storage.html — Proxmox Backup Server Backup Storage
[7] https://pbs.proxmox.com/docs/sysadmin.html — Proxmox Backup Server Host Administration
[8] https://pbs.proxmox.com/docs/system-requirements.html — Proxmox Backup Server System Requirements
