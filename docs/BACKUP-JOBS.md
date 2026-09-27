# Backup jobs as code

Backup schedules used to live only in `/etc/pve/jobs.cfg` — recreate the
cluster and you recreate them from memory. `post-deploy/configure_backup_jobs.sh`
declares the intended backup jobs in git and converges the cluster to them
(check-first, idempotent, `--apply` with confirmation).

## The policy

Two jobs, split by guest importance so each PBS datastore gets the right
guests (see `docs/PBS-STORAGE.md`). Guest pools are the selection
mechanism: create PVE pools `prod` and `scratch`, assign every guest to
one, and the jobs never need editing when guests come and go.

| Job | Selection | Target datastore | Schedule | Why |
|---|---|---|---|---|
| `nightly-prod` | `--pool prod` | `vm-ssd` (PVE storage id pointing at the `vm-ssd` datastore) | `02:00` daily | Production VMs/LXCs on fast SSD storage |
| `nightly-scratch` | `--pool scratch` | `scratch` | `03:30` daily | Dev/test guests on bulk HDD; staggered 90 min so the jobs don't contend for PBS bandwidth |

Both jobs: `snapshot` mode (no guest downtime), `zstd` compression,
`mailnotification=failure` (failures surface through the PVE notification
system → ntfy, see `docs/NOTIFICATIONS.md`; successes stay quiet).

**Retention authority: PBS prune jobs, not PVE.** Both PVE jobs run with
`keep-all` — the PVE side never prunes. Retention lives in the PBS prune
jobs defined per datastore in `docs/PBS-MAINTENANCE.md`. Running two
different retention policies (one on each side) is how you discover during
an incident that the snapshot you wanted was pruned by the other side.

> Every guest must belong to exactly one pool. A guest in no pool is
> backed up by **neither** job. After adding a guest, assign its pool;
> `pvesh get /cluster/resources --type vm --output-format json` piped
> through a pool-membership check is the audit — or simply eyeball the
> pool column in the PVE UI monthly.

## Usage

Run on any PVE node (jobs are cluster-wide). Create the pools first
(Datacenter → Pools in the UI, or `pvesh create /pools -poolid prod`),
assign every guest to one, then create both jobs:

```bash
# Check: what would change? (default, read-only)
post-deploy/configure_backup_jobs.sh --job-id nightly-prod \
  --pool prod --pbs-storage pbs-vm-ssd --schedule 02:00

# Apply with confirmation
post-deploy/configure_backup_jobs.sh --job-id nightly-prod \
  --pool prod --pbs-storage pbs-vm-ssd --schedule 02:00 --apply

# Second job: scratch guests to the scratch datastore, staggered later
post-deploy/configure_backup_jobs.sh --job-id nightly-scratch \
  --pool scratch --pbs-storage pbs-scratch --schedule 03:30 --apply

# Apply without prompting (automation)
SCHEDULE=02:00 JOB_ID=nightly-prod POOL=prod PBS_STORAGE=pbs-vm-ssd \
  post-deploy/configure_backup_jobs.sh --apply --yes
```

(Adjust the `--pbs-storage` ids to whatever you named the PVE storage
entries pointing at each PBS datastore. Auto-detection only works when
exactly one active PBS storage exists, so with three datastores the id
must be explicit.)

If a job is missing it is created; if it exists with different settings it
is updated field-by-field (only the differing fields are sent); if it matches,
the script reports "up to date" and does nothing.

## Customizing

All settings are flags or environment variables:

```bash
# Back up only two guests, keep it simple
post-deploy/configure_backup_jobs.sh --job-id adhoc --vmids 200,204 --apply

# Skip a scratch guest inside the prod pool, pin the job to pve01, run at 03:30
post-deploy/configure_backup_jobs.sh --job-id nightly-prod \
  --pool prod --exclude 9999 --node pve01 --schedule 03:30 --apply

# Longer retention lives in the PBS prune jobs, not here —
# see docs/PBS-MAINTENANCE.md. The PVE jobs stay at keep-all.
```

Notes:

- `--pool` switches selection from `--all` to the named pool. `--vmids`
  and `--pool` are mutually exclusive. Prefer pools over `--vmids` so the
  job definition never changes when guests come and go — but remember: a
  guest in no pool is backed up by nothing.
- The schedule accepts any systemd calendar spec (`02:00`, `sun 03:00`,
  `*-*-* 02:00:00`). Stagger jobs so they don't overlap on the PBS server.
- `--prune` overrides the `keep-all` default per job if you ever need the
  PVE side to prune (not recommended — keep PBS prune jobs authoritative).

## How it ties together

- **Restore tests** (`docs/BACKUP-RESTORE-TESTS.md`): the nightly jobs produce
  the backups that `pbs_restore_test.sh` audits and restore-tests. If a job
  is broken or missing, the check mode flags stale/missing backups.
- **Retention** (`docs/PBS-MAINTENANCE.md`): PBS prune jobs own retention;
  the PVE jobs are `keep-all` by design.
- **Alerting** (`docs/NOTIFICATIONS.md`): job failures arrive via ntfy because
  `mailnotification=failure` routes them into the PVE notification system.
- **Disaster recovery** (`docs/DISASTER-RECOVERY.md`): after rebuilding the
  cluster, re-run this script with `--apply` to restore the backup schedule —
  one command instead of clicking through the GUI from memory.
