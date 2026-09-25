# Backup restore tests

Backups you never restore are hopes, not backups. `scripts/pbs_restore_test.sh`
automates the quarterly restore test: it restores a small canary guest's latest
PBS backup to a throwaway VMID, boots it with the network detached (so it can
never conflict with production), verifies it runs, tears it down, and reports
PASS/FAIL.

## The canary

Pick one small, unimportant guest — the `ntfy` or `uptime` LXC is ideal. It
only needs a daily backup; its restored copy is never given network access,
so IP/MAC conflicts are impossible by construction.

## Usage

Run on any PVE node (needs `pvesh`, `qm`/`pct`, `python3`):

```bash
# Audit: latest backup per guest, flags stale/missing (default mode)
scripts/pbs_restore_test.sh --mode check

# Full restore -> boot -> verify -> teardown cycle for the canary
scripts/pbs_restore_test.sh --mode test --vmid 204
```

Useful flags: `--pbs-storage ID` (auto-detected when unambiguous),
`--test-vmid 9999`, `--target-storage ID` (auto-detected),
`--max-age-days 2`, `--timeout 300`, `--yes` to skip confirmation.

## Notifications

Point the script at ntfy (the `ntfy` LXC this repo deploys) to get PASS/FAIL
push alerts:

```bash
export NTFY_URL="http://10.10.41.14" NTFY_TOPIC="proxmox-alerts"
scripts/pbs_restore_test.sh --mode test --vmid 204 --yes
```

Without ntfy configured, results go to stdout and the exit code (0 = PASS).

## Quarterly schedule

On one PVE node, as root:

```cron
# Quarterly restore test, first day of Jan/Apr/Jul/Oct at 09:00
0 9 1 1,4,7,10 * /root/proxmox_ve_installation/scripts/pbs_restore_test.sh --mode test --vmid 204 --yes
```

Set `NTFY_URL`/`NTFY_TOPIC` in root's environment or in the cron line if you
want push reports.

## Interpreting results

- **PASS**: the backup extracted, the guest booted to `running`, the deep
  check (guest-agent ping for VMs, `pct exec` for LXCs) result is logged, and
  the throwaway guest was destroyed. Nothing is left behind.
- **FAIL**: the guest never reached `running` within the timeout, or the
  restore itself errored. The throwaway guest is still torn down automatically
  (the script traps exits). Investigate the backup chain for the canary before
  the next cycle — and treat it as a production backup problem, because it is.
- **STALE** (check mode): a guest's newest backup is older than
  `--max-age-days`. Fix the backup job, not the test.

## Safety notes

- The test never touches the original VMID; restores always go to a fresh
  `--test-vmid` that must be unused (the script refuses otherwise).
- `net0` is detached before first boot, so the copy cannot ARP, DHCP, or
  answer on any production network.
- Cleanup runs on every exit path, including failures and Ctrl-C.
