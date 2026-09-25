# PBS self-protection: verify, prune, GC, and config backup

pbs01 is a single point of failure with two weak spots this runbook closes:

1. **Silent datastore corruption** — bitrot or bad sectors you only discover
   during a restore. Fixed with scheduled verify jobs.
2. **Lost PBS configuration** — `/etc/proxmox-backup` (datastores, users,
   tokens, ACLs) is local to pbs01 and is *not* replicated by the cluster
   filesystem. A dead OS disk takes it with it. Fixed with
   `scripts/pbs_config_backup.sh`.

`<store>` below is your datastore name (whatever you passed to
`post-deploy/create_pbs_datastore.sh`).

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
proxmox-backup-manager verify-job create verify-main \
  --store main \
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
proxmox-backup-manager datastore update main --verify-new true
```

Verify failures appear in the PBS task log (`Administration → Tasks`).
Treat any verify failure as an incident: the affected chunks are
untrustworthy until a fresh backup replaces them.

## Prune jobs (retention)

Prune decides which snapshots to *keep*. It only removes index entries —
disk space is not freed until garbage collection runs (next section).

```bash
# Thinning ladder: dense recent, sparse historical. Overlapping keep-*
# rules union — a snapshot kept by any rule survives.
proxmox-backup-manager prune-job create prune-main \
  --store main \
  --schedule "daily" \
  --keep-last 3 \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6
```

UI path: Datastore → Prune & GC → Prune Jobs → Add.

**Retention authority: pick one.** PVE backup jobs have their own
`keep-*` retention settings, and PBS prune jobs have theirs. Running both
with different policies is the classic way to discover — during an
incident — that the snapshot you wanted was pruned by the other side.
Recommendation: manage retention in **PBS prune jobs** and leave the PVE
backup job retention policy at keep-all (or document explicitly that the
PVE side is the authority). Whichever you choose, write it down next to
the job definition.

## Garbage collection

GC walks the chunk store and deletes chunks no snapshot references anymore,
after a deliberate 24-hour grace period (so a backup job currently running
can't have its chunks pulled out from under it — do not try to work
around it).

```bash
# Weekly GC, scheduled AFTER the prune job and OUTSIDE the backup window.
# GC is I/O heavy; do not overlap it with backups or verify jobs.
proxmox-backup-manager datastore update main --gc-schedule "sun 04:00"
```

(Or set `--gc-schedule` at creation time:
`proxmox-backup-manager datastore create main /mnt/datastore --gc-schedule "sun 04:00"`.)

UI path: Datastore → Prune & GC → set the GC schedule.

Ordering that matters: **backup → prune → GC → verify**. Prune without GC
frees nothing; verify before prune wastes effort re-checking snapshots
you are about to drop.

## Suggested weekly timetable

| When | What |
|---|---|
| Nightly (PVE backup jobs) | Backups land on PBS |
| Daily 21:30 | Prune job |
| Sunday 04:00 | Garbage collection |
| Saturday 03:00 | Verify job (re-verifies anything stale > 30 days) |

Keep all four out of each other's way and out of the nightly backup
window.

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
  backups are unrecoverable. Keep a copy in your password manager / offline
  vault — this is the single most loss-sensitive item in the whole setup.
- **The datastore data itself** — that is what verify/prune/GC and the
  offsite story protect, not this script.

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
