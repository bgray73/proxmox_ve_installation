# Disk health: ZFS scrubs, zed alerts, SMART monitoring

`scripts/disk_health.sh` manages all three on each PVE node and the PBS host:

```bash
scripts/disk_health.sh --mode check                      # report only (default)
scripts/disk_health.sh --mode apply --yes \
  --ntfy-url http://10.10.41.14 --ntfy-topic proxmox-alerts
```

Check mode exits 1 if anything needs attention, so it is cron-friendly.

## ZFS scrub scheduling: systemd timer, monthly

The `zfsutils-linux` package ships per-pool template units — no custom cron
needed:

- `zfs-scrub@.service` — runs `zpool scrub -w <pool>` (waits for completion)
- `zfs-scrub-weekly@.timer` / `zfs-scrub-monthly@.timer` — `OnCalendar=weekly|monthly`,
  `Persistent=true`, `RandomizedDelaySec=1h`

Enable per pool:

```bash
systemctl enable zfs-scrub-monthly@rpool.timer --now
```

**Why a timer instead of cron:** it ships with the package (nothing to invent),
it is per-pool, the service waits on an already-running scrub instead of
stacking a second one, missed runs catch up via `Persistent=true`, and output
lands in the journal.

**Why monthly for a homelab:** a scrub reads every block, so on multi-TB HDD
pools a weekly scrub can take days and fight VM I/O the whole time. Monthly
catches bit-rot and latent sector errors well inside any redundancy window.
Use `--scrub weekly` only for small, fast (SSD/NVMe) pools, or `--scrub off`
to disable.

> Note: stock Debian additionally auto-scrubs all online pools on the second
> Sunday of each month (controlled by the `org.debian:periodic-scrub` pool
> property). Proxmox VE ships its own ZFS builds, so don't rely on that —
> this script enables the explicit per-pool timers instead, which work
> identically on PVE and PBS.

## zed: ZFS Event Daemon alerts to ntfy

`zed` (package `zfs-zed`, service `zed`) runs "zedlets" from `/etc/zfs/zed.d/`
for kernel zevents. A zedlet runs when the event's class (or subclass) string
is a filename prefix followed by a non-alphabetic character; the prefix `all`
matches every event. Zedlets must be root-owned, executable, with no
group/other write bits.

The script installs `/etc/zfs/zed.d/all-ntfy.sh`, which filters to the events
worth waking up for and POSTs them to ntfy:

| Event class | Priority | Meaning |
|---|---|---|
| `ereport.fs.zfs.checksum` / `.io` / `.data` / `.delay` / `.probe_failure` | max | real fault: bad blocks, failing I/O |
| `statechange` | high | vdev degraded, faulted, removed |
| `scrub.finish` / `resilver.finish` | default | informational completion notice |

The stock email-based notifiers (`ZED_EMAIL_ADDR` in `/etc/zfs/zed.d/zed.rc`)
are left alone; ntfy is additive. Verify zed sees the hook with
`systemctl status zed` and trigger a real event any time with
`zpool scrub <pool>` (fires `scrub.finish` → info-level ntfy).

## smartd: SMART monitoring to ntfy

Package `smartmontools`, config `/etc/smartd.conf`, service `smartd`.
The script writes (backing up any existing config first):

```
DEVICESCAN -H -f -t -l error -l selftest -C 197 -U 198 -W 4,50,60 \
  -s (S/../.././02|L/../../6/03) \
  -m <nomailer> -M exec /usr/local/bin/smartd-ntfy
```

What that means:

- `DEVICESCAN` — monitor every detected disk, including NVMe (smartmontools
  7.x handles NVMe natively; no special directive needed).
- `-H -f -t -l error -l selftest` — overall health, failure attributes,
  prefail/usage attribute changes, error and self-test logs.
- `-C 197 -U 198` — watch Current Pending Sector Count and Offline
  Uncorrectable.
- `-W 4,50,60` — log temperature swings ≥ 4 °C; warn at 50 °C, critical at 60 °C.
- `-s (S/../.././02|L/../../6/03)` — short self-test daily 02:00–03:00, long
  self-test Saturdays 03:00–04:00. Format is `T/MM/DD/d/HH` with day-of-week
  1=Monday..7=Sunday.
- `-m <nomailer> -M exec /usr/local/bin/smartd-ntfy` — instead of email, run
  the hook with `SMARTD_*` env vars set (`SMARTD_DEVICE`, `SMARTD_MESSAGE`,
  …). The hook POSTs to ntfy and stays completely silent on stdout/stderr
  (smartd treats any output as an internal error).

**SATA/SAS behind a Dell PERC in RAID mode:** those disks are invisible to
`DEVICESCAN`. Prefer the controller in HBA/non-RAID mode (this repo already
requires that for ZFS). If you must monitor through the PERC, add one line
per physical disk instead of relying on DEVICESCAN:

```
/dev/sda -d megaraid,0 -H -f -t -l error -l selftest -C 197 -U 198 \
  -s (S/../.././02|L/../../6/03) -m <nomailer> -M exec /usr/local/bin/smartd-ntfy
```

(`-d megaraid,N` for disk N behind the controller; `-d sat` for USB/SATA
bridges that need a nudge.)

## What "healthy" looks like

- `zpool status` shows `ONLINE`, no `DEGRADED`/`FAULTED` vdevs.
- `scan: scrub repaired 0B ... with 0 errors on <recent date>` — and
  `zpool status -v` shows no permanent errors.
- `smartctl -H /dev/sdX` → `SMART overall-health self-assessment test result: PASSED`.
- `smartctl -A`: Reallocated_Sector_Ct (5), Current_Pending_Sector (197),
  Offline_Uncorrectable (198) all at 0 and not climbing.
- NVMe: `Percentage Used` well under 100, `Media and Data Integrity Errors: 0`.
- `--mode check` prints `OK: all disk-health checks passed.`

## When to replace a disk

- `smartctl -H` says FAILED — replace now, don't wait.
- Any of 5/197/198 nonzero **and increasing** across checks — the disk is
  reallocating around bad media; order a replacement and swap it.
- ZFS checksum or read errors climbing on one specific disk
  (`zpool status` / `zpool events -v`) while its siblings stay clean —
  the disk, not the pool, is the problem.
- NVMe `Percentage Used` over ~90 or any media/data-integrity errors —
  plan the swap.
- A disk that drops out of the pool repeatedly (transport/link resets in
  `dmesg`) even with clean SMART — replace; the electronics are dying.

After swapping: `zpool replace <pool> <old> <new>`, watch the resilver
(`zpool status`), and you'll get an ntfy when `resilver.finish` fires.

## Where logs live

- Scrub runs: `journalctl -u 'zfs-scrub@*'`
- zed: `journalctl -u zed`; raw kernel events: `zpool events -v`
- smartd: `journalctl -u smartd`
- Pool history (scrubs, replaces, errors): `zpool history <pool> | tail`
- ntfy hook failures: `journalctl -t zed-ntfy` / `journalctl -t smartd-ntfy`
