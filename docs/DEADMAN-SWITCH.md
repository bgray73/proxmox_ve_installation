# Offsite dead-man's switch (Healthchecks.io)

Every other alert in this repo — the self-hosted ntfy, Uptime Kuma, the PVE
notification webhooks — runs **inside the rack**. If the whole site goes dark
(power, ISP, fire), those die silently, and silence looks exactly like "all
good". This switch inverts that: the lab must regularly prove it is alive to
an offsite watcher. No proof, no pings → you get paged.

The watcher and the alert path both live offsite **on purpose**. That is the
entire design.

## The two checks

Healthchecks.io free tier allows 20 checks; we use 2.

| Check | Schedule | Period | Grace | What it proves |
|---|---|---|---|---|
| `lab-heartbeat` | Simple | 5 minutes | 15 minutes | a PVE node is up and Corosync quorum is healthy |
| `nightly-backups` | Simple | 1 day | 6 hours | every guest got a fresh PBS backup after the backup window |

If no ping arrives within Period + Grace, the check goes down and the alert
integrations fire.

## Setup

1. Create a free account at [healthchecks.io](https://healthchecks.io).
2. Add check `lab-heartbeat`: Simple schedule, Period **5 minutes**, Grace
   **15 minutes**.
3. Add check `nightly-backups`: Simple schedule, Period **1 day**, Grace
   **6 hours**.
4. Copy each check's ping URL (`https://hc-ping.com/<uuid>`).

## Install on ONE PVE node (pve01)

```bash
# Ping URLs live in a root-only env file — never in the repo, never in cron.
cat > /root/.hc.env <<'EOF'
HC_HEARTBEAT_URL="https://hc-ping.com/<lab-heartbeat-uuid>"
HC_BACKUPS_URL="https://hc-ping.com/<nightly-backups-uuid>"
EOF
chmod 600 /root/.hc.env

install -m 755 scripts/hc_ping.sh /usr/local/bin/hc_ping.sh

cat > /etc/cron.d/hc-lab <<'EOF'
# Healthchecks.io dead-man's switch — run on ONE node only
*/5 * * * * root . /root/.hc.env; /usr/local/bin/hc_ping.sh --check heartbeat
0 6 * * *   root . /root/.hc.env; /usr/local/bin/hc_ping.sh --check backups
EOF
```

One node only: if two nodes ping the same check it still works (Healthchecks
records the latest ping), but a single reporter keeps the failure signal
unambiguous. Optional hardening: run the heartbeat from a second node too —
then pve01 dying alone won't page you while the other two nodes are fine.

## Alert integrations

In each check's settings → Integrations, add **Email** and install the
**Healthchecks mobile app** for push. Those are your primary alert paths.

Do **not** point these checks at the self-hosted ntfy. When the site is dark,
ntfy is dark too, and the page would never arrive — which defeats the one job
this switch has.

## What each check verifies

**lab-heartbeat** (`--check heartbeat`): runs `pvecm status` and requires all
three — `Quorate: Yes`, `Total votes` == `Expected votes`, and every expected
member present in the membership list. Anything else pings the check's `/fail`
endpoint with the reason and exits nonzero (cron mails root as well, if an
MTA is configured).

**nightly-backups** (`--check backups`): lists the latest PBS backup per guest
(same parsing as `scripts/pbs_restore_test.sh`). If any guest's latest backup
is older than 30h — or there are no backups at all — it pings `/fail` with the
stale list and exits nonzero. Note: a guest that was *never* backed up has no
row to be stale; run `scripts/pbs_restore_test.sh --mode check` for the full
audit including never-backed-up guests.

## Testing

1. Manual success: `/usr/local/bin/hc_ping.sh --check heartbeat` → prints
   "heartbeat OK" and the check shows green in the Healthchecks dashboard.
2. Failure path: `curl https://hc-ping.com/<uuid>/fail` → the check goes red
   and the alert arrives via email/app within a minute or two.
3. Full drill: comment out the cron lines, wait Period + Grace (20 minutes for
   the heartbeat), confirm the page arrives, then uncomment.

## It paged you at 3am — triage

- **Which check fired?** `lab-heartbeat` means the site itself may be dark:
  try Tailscale, then the iDRACs on VLAN 10. If nodes are up but quorum is
  broken, see the "node doesn't come back" notes in `docs/UPDATES.md`. If
  everything is dead, go to `docs/DISASTER-RECOVERY.md`.
- `nightly-backups` means the site is alive but backups failed: check the PBS
  storage state and last night's vzdump logs, then `docs/BACKUP-JOBS.md`.

## Maintenance

- **Planned power work / UPS test / ISP maintenance:** pause both checks in
  the Healthchecks dashboard first, or you *will* be paged. That is the system
  working as designed.
- **Rotating a ping URL:** update `/root/.hc.env`, run both checks once by
  hand, confirm green in the dashboard.
