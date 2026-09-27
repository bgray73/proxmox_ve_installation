# PBS self-protection: verify, prune, GC, and config backup

pbs01 is a single point of failure with two weak spots this runbook closes:

1. **Silent datastore corruption** — bitrot or bad sectors you only discover
   during a restore. Fixed with scheduled verify jobs.
2. **Lost PBS configuration** — `/etc/proxmox-backup` (datastores, users,
   tokens, ACLs) is local to pbs01 and is *not* replicated by the cluster
   filesystem. A dead OS disk takes it with it. Fixed with
   `scripts/pbs_config_backup.sh`.

Examples below use the real datastore names from `docs/PBS-STORAGE.md`
(`vm-ssd`, `bulk`, `scratch`).

## Verify jobs

A verify job re-reads every chunk of the selected snapshots and re-checks
their SHA-256 checksums against the index. It detects bitrot, bad sectors,
and transmission corruption *before* you need a restore. It is read-only —
it never modifies backup data.

Recommended: one job per datastore, weekly in a low-traffic window,
re-verifying anything whose last verification is older than 30 days.

```bash
# Run on pbs01. Command syntax verified against the official PBS docs
# (pbs.proxmox.com/docs/proxmox-backup-manager).
# Shown for vm-ssd; repeat per datastore on the schedule in the
# per-datastore table under "Prune jobs (retention)".
proxmox-backup-manager verify-job create verify-vm-ssd \
  --store vm-ssd \
  --schedule "sat 03:00" \
  --ignore-verified true \
  --outdated-after 30 \
  --comment "weekly re-verify; managed manually, see docs/PBS-MAINTENANCE.md"
```

- `--ignore-verified true` (the default) skips snapshots that are already
  verified and not outdated, so weekly runs stay cheap after the first pass.
- `--outdated-after 30` marks verifications older than 30 days as stale, so
  each snapshot gets fully re-checked roughly monthly.
- UI path: PBS web UI → Datastore → Verify Jobs → Add (same fields).

Also enable immediate verification of new uploads — a checksum comparison
right after every chunk upload, catching transmission errors before the
backup job even finishes:

```bash
proxmox-backup-manager datastore update vm-ssd --verify-new true
```

Verify failures appear in the PBS task log (`Administration → Tasks`).
Treat any verify failure as an incident: the affected chunks are
untrustworthy until a fresh backup replaces them.

## Prune jobs (retention)

Prune decides which snapshots to *keep*. It only removes index entries —
disk space is not freed until garbage collection runs (next section).
Thinning ladder: dense recent, sparse historical. Overlapping keep-*
rules union — a snapshot kept by any rule survives.

UI path: Datastore → Prune & GC → Prune Jobs → Add.

**Retention authority: PBS prune jobs. Decided.** PVE backup jobs have their
own `keep-*` retention settings, and PBS prune jobs have theirs. Running both
with different policies is the classic way to discover — during an
incident — that the snapshot you wanted was pruned by the other side.
The rule in this repo: **PBS prune jobs own retention; every PVE backup job
runs at `keep-all`** (see `docs/BACKUP-JOBS.md` and
`post-deploy/configure_backup_jobs.sh`, whose default is `keep-all`).
Never set `keep-*` retention on the PVE side.

## Per-datastore schedules

One prune job and one verify job per datastore (datastores are cheap;
per-datastore schedules keep the critical tier on SSD fast and the bulk
tier out of the way). Retention values match `docs/PBS-STORAGE.md`.

| Datastore | Prune job | Verify job | GC |
|---|---|---|---|
| `vm-ssd` | daily 21:30 — `keep-daily=7,keep-weekly=4,keep-monthly=6` | weekly `sat 03:00`, re-verify stale > 30 days | `sun 04:00` |
| `bulk` | daily 21:45 — `keep-weekly=4,keep-monthly=6` | monthly `sun 03:00`, re-verify stale > 30 days | `sun 05:00` |
| `scratch` | daily 22:00 — `keep-daily=3` | monthly `sun 03:30`, re-verify stale > 30 days | `sun 05:30` |

```bash
# Example for vm-ssd; repeat per datastore with the schedule above.
proxmox-backup-manager prune-job create prune-vm-ssd \
  --store vm-ssd --schedule "21:30" \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
proxmox-backup-manager verify-job create verify-vm-ssd \
  --store vm-ssd --schedule "sat 03:00" \
  --ignore-verified true --outdated-after 30
proxmox-backup-manager datastore update vm-ssd --verify-new true
```

Ordering that still matters: **backup → prune → GC → verify**. Prune without GC
frees nothing; verify before prune wastes effort re-checking snapshots
you are about to drop. GC is I/O heavy; keep it out of the backup window
(02:00–04:00) and off the verify slots.

## Garbage collection

GC walks the chunk store and deletes chunks no snapshot references anymore,
after a deliberate 24-hour grace period (so a backup job currently running
can't have its chunks pulled out from under it — do not try to work
around it).

```bash
# Per-datastore GC, scheduled AFTER that datastore's prune job and OUTSIDE
# the backup window. GC is I/O heavy; do not overlap it with backups or
# verify jobs.
proxmox-backup-manager datastore update vm-ssd --gc-schedule "sun 04:00"
```

(Or set `--gc-schedule` at creation time:
`proxmox-backup-manager datastore create vm-ssd /fast/vm-ssd --gc-schedule "sun 04:00"`.)

UI path: Datastore → Prune & GC → set the GC schedule.

## Config backup: what must be captured

`scripts/pbs_config_backup.sh` (run on pbs01, cron-friendly) archives all
of this into a timestamped, root-only tarball, keeps the N most recent
locally, and pushes a copy to a PVE node:

| Captured | Why | Restore |
|---|---|---|
| `/etc/proxmox-backup/` (`datastore.cfg`, `user.cfg`, `acl.cfg`, token/user configs) | Without it, a rebuilt PBS forgets its datastores, users, and API tokens | Reinstall PBS, restore the directory, restart `proxmox-backup` services |
| `/etc/network/interfaces` (+ `interfaces.d/`) | Static IPs, VLANs, bridges | Re-apply to the rebuilt host |
| `zpool status` / `zpool list` output | Pool layout reference | Manual — pools are re-imported, not restored from backup |
| `proxmox-backup-manager datastore list` | Datastore → path mapping | Cross-check during rebuild |
| PBS certificate fingerprint (`cert info`) | PVE needs the fingerprint when re-registering PBS storage | Paste into the PVE storage definition |

Two things the script deliberately notes but **cannot** back up from pbs01:

- **Client-side encryption keys** live on the PVE nodes
  (`/etc/pve/priv/storage/*.enc`), not on PBS. Without the key, encrypted
  backups are unrecoverable. This is the single most loss-sensitive item in
  the whole setup — the procedure below is mandatory, not optional.
- **The datastore data itself** — that is what verify/prune/GC and the
  offsite story protect, not this script.

## Backup encryption keys: export, store, and prove recovery

Do this once when encryption is first enabled, again whenever a key
changes, and re-verify annually. Untested key backups are not backups.

1. **Export.** On any PVE node, copy each key out of the cluster filesystem:
   ```bash
   # one .enc file per PBS storage that uses client-side encryption
   ls /etc/pve/priv/storage/
   cp /etc/pve/priv/storage/<store>.enc /root/pbs-<store>.enc
   ```
   Copy the file off the node (USB stick, password manager file attachment —
   never email, never chat).
2. **Store in two independent locations.** Minimum: (a) password manager
   attachment, (b) offline copy (encrypted USB in a different building, or
   printed as base64 in a sealed envelope). The offsite PBS location counts
   as one of the two once `docs/OFFSITE-PBS.md` is deployed — until then it
   does not exist, so use two you control today.
3. **Set up a PBS master key.** PBS supports a master key that can recover
   backup encryption keys. Create one, store it with the same two-location
   rule, and record that it exists in `docs/DISASTER-RECOVERY.md` Phase 7.
4. **Prove it works — annually.** Restore one encrypted backup using *only*
   the saved key file (not the live `/etc/pve/priv` copy):
   ```bash
   # on a scratch PVE node or a test VM with the PBS storage registered:
   # temporarily move the live key aside, place ONLY the saved copy,
   # and restore a small guest. If the restore succeeds, the saved key
   # is good. Restore the live key immediately afterward.
   ```
   Log the date and result next to the Phase 7 checklist. A key that has
   never restored anything is a hope, not a recovery path.

Install the script at `/usr/local/sbin/pbs_config_backup.sh` on pbs01 and
let `--mode apply` install its own cron line (`/etc/cron.d/pbs-config-backup`,
daily 03:00). `check` mode verifies the archive is fresh, the cron line is
present, and an offsite destination is configured — wire it into whatever
watches pbs01, or just eyeball it monthly.

## Health checks

- `proxmox-backup-manager verify-job list` — jobs exist and are enabled.
- PBS task log — last verify/GC/prune runs show OK, not warnings.
- Datastore usage trend — GC is actually reclaiming (usage drops after
  Sunday); a monotonically growing store means prune or GC is misconfigured.
- `/var/backups/pbs-config/` on pbs01 — fresh archive (< 48 h old); the
  offsite copy on the PVE node matches.
