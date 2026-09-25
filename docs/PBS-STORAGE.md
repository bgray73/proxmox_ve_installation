# PBS storage design checklist

## Known hardware (pbs01 — confirmed 2026-09-25)

- Chassis: **Supermicro 6028R-E1CR24N**, 2U, 24× 3.5" LFF hot-swap bays on a
  SAS3 expander backplane, plus 2× rear 2.5" flex bays. Board: X10DRi.
- Controller: **Broadcom 3108 HW RAID mezzanine (AOC-S3108M-H8L)** — this is
  a hardware RAID card, not an HBA. Decision (2026-09-25): **replace it
  with an LSI 9300-8i in IT mode** (or the Supermicro-branded
  AOC-S3008L-L8i — same SAS3008 chip). The 3108 comes out entirely; one
  SFF-8643→SFF-8643 cable connects the HBA to the single SAS3 expander
  backplane and fans out to all 24 bays. Card needs a low-profile bracket
  for the 2U chassis. Never put ZFS on a hardware RAID virtual disk.
- Disks on hand (2026-09-25): **12× 512GB SSD, 3× 4TB HDD, 11× 1TB HDD.**

## Finalized topology (2026-09-25)

All 26 bays are spoken for. 2.5" SSDs in the front LFF bays need
2.5"→3.5" adapter trays; the rear flex bays are 2.5" native.

| Bays | Disks | Use |
|------|-------|-----|
| Rear flex ×2 | 2× 512GB SSD | PBS OS mirror |
| Front ×2 | 2× 512GB SSD | ZFS **special vdev** mirror (metadata) |
| Front ×8 | 8× 512GB SSD | Pool `fast`: 4× mirrored pairs striped, ≈2TB usable |
| Front ×11 | 11× 1TB HDD | Pool `tank` vdev 1: RAIDZ2, 9TB usable |
| Front ×3 | 3× 4TB HDD | Pool `tank` vdev 2: 3-way mirror, 4TB usable |

- **Pool `tank`** (bulk backups, one PBS datastore, ≈13TB usable): mixed
  vdevs are legal in ZFS — an 11-wide RAIDZ2 of 1TB disks plus a 3-way
  mirror of 4TB disks. Never mix disk sizes *within* a vdev (capacity
  clamps to the smallest disk); separate vdevs per size avoids that.
  The mirrored SSD special vdev is attached to this pool — PBS
  garbage-collection, prune, and verify are metadata-heavy, and this is
  the single biggest performance win. The special vdev **must stay
  mirrored**: losing it loses the pool, and it cannot be removed later.
  (RAIDZ1 on the 3× 4TB would give 8TB usable instead of 4TB, at only
  single-disk redundancy — not taken.)
- **Pool `fast`** (second PBS datastore, ≈2TB usable): striped mirrors on
  SSD for the most critical VMs — faster backup, verify, and restore.
  Assign per-guest in the PVE backup jobs.
- **Not used:** SLOG (PBS does almost no sync writes) and L2ARC (write-heavy
  workload — spend the budget on RAM for ARC instead). PBS chunks are 4MB,
  so they stay on the HDDs; only metadata and small blocks land on the
  special vdev. No `special_small_blocks` tuning needed.
- **Spares:** no SSD or HDD spares on hand after this layout. Buy at least
  one spare 512GB SSD and keep the 3108's old cables labeled; HDD spares
  can follow when the 1TB disks age out (that pool is the natural
  upgrade target: replace 1TB disks with larger ones later).

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
6. Run `post-deploy/create_pbs_datastore.sh NAME /mount/path`. The script refuses
   unless the mount is persistent (fstab, an enabled systemd `.mount` unit, or a
   ZFS dataset); override only deliberately with `ALLOW_TRANSIENT_MOUNT=1`.
7. Create a least-privilege backup API token and register PBS in PVE.
8. Run a backup, verification, and full test restore before considering the system production-ready.

## Sources

[2] https://pbs.proxmox.com/docs/installation.html — Proxmox Backup Server Installation
[6] https://pbs.proxmox.com/docs/storage.html — Proxmox Backup Server Backup Storage
[7] https://pbs.proxmox.com/docs/sysadmin.html — Proxmox Backup Server Host Administration
[8] https://pbs.proxmox.com/docs/system-requirements.html — Proxmox Backup Server System Requirements
