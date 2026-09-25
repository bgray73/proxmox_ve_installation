# Backup jobs as code

Backup schedules used to live only in `/etc/pve/jobs.cfg` — recreate the
cluster and you recreate them from memory. `post-deploy/configure_backup_jobs.sh`
declares the intended backup job in git and converges the cluster to it
(check-first, idempotent, `--apply` with confirmation).

## The policy

One job, id `nightly-all`:

| Setting | Value | Why |
|---|---|---|
| Schedule | `02:00` daily (systemd calendar) | Off-hours; guests idle |
| Selection | `--all` (every guest, every node) | New guests are covered automatically — nothing to remember when you add a VM |
| Mode | `snapshot` | No guest downtime |
| Compression | `zstd` | Best ratio/speed trade on modern CPUs |
| Target | PBS storage (auto-detected) | Deduplicated, verified datastore |
| Retention | `keep-daily=7,keep-weekly=4` | 7 daily restore points + 4 weekly anchors ≈ 5 weeks of coverage. PBS deduplication makes dailies cheap; `keep-last=3` would only cover 3 days, too short to notice a slow-burn problem |
| Failure reporting | `mailnotification=failure` | Failures surface through the PVE notification system → ntfy (see `docs/NOTIFICATIONS.md`); successes stay quiet |

PBS prunes per the job's retention after each run (`remove` defaults to 1),
so old backups are actually deleted, not just unlisted.

## Usage

Run on any PVE node (jobs are cluster-wide):

```bash
# Check: what would change? (default, read-only)
post-deploy/configure_backup_jobs.sh

# Apply with confirmation
post-deploy/configure_backup_jobs.sh --apply

# Apply without prompting (automation)
post-deploy/configure_backup_jobs.sh --apply --yes
```

If the job is missing it is created; if it exists with different settings it
is updated field-by-field (only the differing fields are sent); if it matches,
the script reports "up to date" and does nothing.

## Customizing

All settings are flags or environment variables:

```bash
# Back up only two guests, keep it simple
post-deploy/configure_backup_jobs.sh --vmids 200,204 --apply

# Skip a scratch guest, pin the job to pve01, run at 03:30
post-deploy/configure_backup_jobs.sh --exclude 9999 --node pve01 \
  --schedule 03:30 --apply

# Longer retention for compliance-ish peace of mind
post-deploy/configure_backup_jobs.sh --prune keep-daily=14,keep-weekly=8,keep-monthly=6 --apply
```

Notes:

- `--vmids` switches selection from `--all` to an explicit list. Prefer
  `--all` + `--exclude` so future guests stay covered.
- The schedule accepts any systemd calendar spec (`02:00`, `sun 03:00`,
  `*-*-* 02:00:00`).
- A second job with a different `--job-id` can coexist (e.g. an hourly job
  for one critical VM) — but keep the count low; parallel jobs contend for
  PBS bandwidth.

## How it ties together

- **Restore tests** (`docs/BACKUP-RESTORE-TESTS.md`): the nightly job produces
  the backups that `pbs_restore_test.sh` audits and restore-tests. If the job
  is broken or missing, the check mode flags stale/missing backups.
- **Alerting** (`docs/NOTIFICATIONS.md`): job failures arrive via ntfy because
  `mailnotification=failure` routes them into the PVE notification system.
- **Disaster recovery** (`docs/DISASTER-RECOVERY.md`): after rebuilding the
  cluster, re-run this script with `--apply` to restore the backup schedule —
  one command instead of clicking through the GUI from memory.
