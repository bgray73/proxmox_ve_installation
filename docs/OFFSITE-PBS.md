# Offsite PBS — second copy outside the house

**Threat model:** PVE, PBS, and all backup disks live in one rack in one
house. Fire, theft, flooding, a panel-level electrical event, or ransomware
that reaches the cluster can take out every copy at once. This runbook adds
the second copy.

Three options, in order of preference:

| # | Option | Protects against | Cost/effort |
|---|---|---|---|
| 1 | **Second PBS, pull sync** (recommended) | Total site loss, ransomware (pull design) | One small server + disks at a trusted location |
| 2 | **S3-compatible storage** | Total site loss | No hardware; ongoing storage/request/egress fees |
| 3 | **Rotating encrypted USB drives** | Total site loss, ransomware (air gap) | Two large USB drives; manual rotation |

All three are better than the current state, which is zero offsite copies.

## Option 1 (recommended): second PBS with pull sync

### Placement and hardware

- A trusted second location: relative's house, office, anywhere with power
  and internet you don't share a roof with.
- Hardware: used mini-PC or small server, mirrored large HDDs (capacity ≥
  the `vm-ssd` datastore it will receive — ~2TB today, size for growth).
  It does not need SSDs; it is a restore source, not a daily-workhorse.
- Network: Tailscale on the offsite PBS (or WireGuard). No inbound firewall
  holes at either end.

### Why pull, not push

The **offsite** PBS initiates a scheduled **pull** sync from the home PBS.
Compromising the home PVE/PBS environment does not give an attacker control
over the offsite copy — there is no credential on the home side that can
reach out and delete offsite snapshots. PBS supports scheduled incremental
sync between separate PBS installations natively.

### Setup

1. **Seed locally.** Build the offsite PBS at home first, on the LAN. Run
   the first full sync over gigabit — do not push terabytes over Fios on
   day one. Then move it offsite; subsequent syncs are incremental.
2. **Sync only `vm-ssd` initially.** That is the critical tier
   (production guests). `bulk` (ISOs, media) and `scratch` can follow once
   the pipeline is proven — or never, if bandwidth makes it silly.
3. **Least-privilege sync credential.** On the home PBS, create a dedicated
   user (e.g. `offsite-sync@pbs`) with read-only access to the `vm-ssd`
   datastore only (`Datastore.Read`). The offsite sync job authenticates as
   this user via API token. It can read snapshots; it cannot prune, delete,
   or touch anything else.
4. **Sync job on the offsite PBS** (pull direction), nightly, after the home
   backup window:
   - `remove-vanished = false` — if the home side ever shows empty (outage,
     misconfiguration, attacker), the offsite copy keeps everything instead
     of faithfully deleting it too. This is the single most important sync
     setting.
   - Consider verified-only sync once verify jobs are green on the home side.
5. **Independent retention on the offsite PBS.** Longer than home — e.g.
   keep-monthly=12. The offsite copy is the archive; home is the working set.
6. **Separate admin credentials + MFA.** The offsite PBS gets its own admin
   password and TOTP, stored in the password manager. Never reuse the home
   PBS credentials — credential reuse across sites collapses the two
   failure domains into one.
7. **Offsite PBS config backup.** The offsite machine gets the same
   `pbs_config_backup.sh` treatment (docs/PBS-MAINTENANCE.md), pushed to
   *its* local location. Each site's config must be recoverable without the
   other site.

### Operating

- Monitor the nightly sync job like any backup job: failure → ntfy alert.
  A sync that silently stops is the same as no offsite copy.
- **Quarterly:** restore one guest directly from the offsite PBS (not via
  the home copy) to prove the chain works end to end.
- **Annually:** clean-room drill — pretend the rack is gone and walk
  `docs/DISASTER-RECOVERY.md` against the offsite copy.

### What else rides the offsite link

- **PBS config archive:** the encrypted `pbs_config_backup.sh` tarball gets
  copied offsite (it is small). Losing the rack must not lose the config
  needed to rebuild from the offsite data.
- **Backup encryption keys:** `/etc/pve/priv/storage/*.enc` and the PBS
  master key belong offsite too, per docs/PBS-MAINTENANCE.md. Data without
  keys is noise.

## Option 2: S3-compatible object storage

PBS natively supports S3-compatible storage as a datastore backend. No
second server to maintain. Good fit if there is no trusted second location.

- Create a dedicated S3-backed datastore for the critical tier only
  (`vm-ssd` contents) — not ISOs, media, scratch guests, or easily rebuilt
  lab VMs.
- **Caveats, all real:**
  - Requires a persistent local cache; budget **64–128 GB** for it.
  - You pay for storage, requests, bandwidth, and **restore egress**.
    Price the restore, not just the backup — the bill that matters arrives
    during a disaster.
  - The S3 credentials and the datastore recovery procedure are offline
    essentials (docs/DISASTER-RECOVERY.md Phase 7). Lose them and the S3
    copy is unusable.
  - One S3-backed datastore cannot be operated by multiple PBS instances
    simultaneously.
  - This is a defined datastore with its own credentials, cache, retention,
    and recovery workflow — not a checkbox on the existing datastore.
- Candidate providers: Backblaze B2 (default pick for the critical tier),
  Cloudflare R2 (if predictable restore egress matters more). Verify current
  pricing, retention, object lock/immutability, egress, and PBS
  compatibility before committing — do not buy on old notes.

## Option 3: rotating encrypted USB drives

Cheapest strong protection, and the air gap is genuinely excellent against
ransomware. Costs discipline instead of money.

1. Two large encrypted USB drives, A and B.
2. Attach drive A, sync critical backups to it, disconnect, store away from
   the rack.
3. Next cycle: attach drive B, sync, disconnect, take it offsite; bring A
   home. Rotate monthly (or on whatever schedule you will actually keep).
4. PBS supports sync jobs triggered when a removable datastore is mounted
   and can unmount it afterward — the window of exposure is minutes.

The failure mode is human: rotations get skipped. Put it on the calendar
with the same seriousness as the quarterly restore test.

## Decision log

- _<date>_: chosen option — <1/2/3>, location/provider, seeding date.
- Record the offsite PBS address, Tailscale identity, admin credential
  location, and sync schedule here when deployed.
