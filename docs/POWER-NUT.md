# NUT-based graceful shutdown on power loss

One UPS, five machines, no graceful degradation without monitoring. NUT
(Network UPS Tools) watches the UPS and shuts everything down in the right
order when the battery runs out. Debian 12 (and Proxmox VE) ship NUT 2.8,
which uses `primary`/`secondary` terminology (older guides say master/slave).

## Topology

- **NUT server on `pbs01`** (Supermicro PBS node). The UPS USB cable plugs
  into pbs01; it runs the driver (`usbhid-ups`), `upsd`, and `upsmon` in
  `primary` mode.
- **NUT clients on `pve01`–`pve03`**. Each runs `upsmon` in `secondary` mode
  against `pbs01`.

Why the PBS node and not a PVE node: the NUT server must stay alive until
*last* so it can keep signaling clients. pbs01 runs no guests, so its
shutdown is trivial and it can be sequenced last with no guest-stop delay.
Putting `upsd` on a PVE node would require "shut down last" choreography on
a host that is simultaneously stopping VMs — more moving parts, more failure
modes. If the UPS USB cable cannot physically reach pbs01, put the server
wherever the cable lands and adjust the addresses below.

NUT traffic: TCP 3493 from the PVE management network to pbs01. Allow it in
your firewall policy (Proxmox datacenter firewall and/or UCG rules).

## Install

```bash
# pbs01 (server)
apt update && apt install -y nut-server nut-client

# pve01..pve03 (clients)
apt update && apt install -y nut-client
```

Debian ships everything disabled: nothing runs until `/etc/nut/nut.conf`
sets a mode.

## Discover the driver

```bash
# on pbs01, with the UPS USB cable connected
nut-scanner -U
```

Most USB UPSes use `usbhid-ups`. The driver varies by model — use whatever
`nut-scanner` reports, and pin `serial` (also reported) so the config
survives USB re-enumeration.

## Config — pbs01 (server)

`/etc/nut/nut.conf`:
```
MODE=netserver
```

`/etc/nut/ups.conf`:
```
pollinterval = 2
maxretry = 3

[ups1]
    driver = usbhid-ups
    port = auto
    desc = "Rack UPS"
    # serial = "XXXXXXXXXXXX"   # pin to this exact unit; from nut-scanner -U
```

`/etc/nut/upsd.conf`:
```
LISTEN 0.0.0.0 3493
```
(Restrict with firewall rules rather than a second LISTEN line.)

`/etc/nut/upsd.users` (keep the shipped restrictive permissions; never commit):
```
[upsmon-primary]
    password = CHANGE_ME_NUT_PRIMARY
    upsmon primary

[upsmon-secondary]
    password = CHANGE_ME_NUT_SECONDARY
    upsmon secondary
```

`/etc/nut/upsmon.conf`:
```
RUN_AS_USER nut
MONITOR ups1@localhost 1 upsmon-primary CHANGE_ME_NUT_PRIMARY primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /run/nut/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
NOTIFYFLAG ONLINE   SYSLOG+WALL
NOTIFYFLAG ONBATT   SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG FSD      SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK   SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD  SYSLOG+WALL+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+WALL+EXEC
NOTIFYFLAG REPLBATT SYSLOG+WALL
NOTIFYFLAG NOCOMM   SYSLOG+WALL+EXEC
NOTIFYFLAG NOPARENT SYSLOG+WALL
```

`/etc/nut/upssched.conf` — the timer that turns "on battery too long" into a
shutdown (cancels itself if mains returns):
```
CMDSCRIPT /etc/nut/upssched-cmd.sh
PIPEFN /etc/nut/upssched.pipe
LOCKFN /etc/nut/upssched.lock
AT ONBATT * START-TIMER early-shutdown 300
AT ONLINE * CANCEL-TIMER early-shutdown
AT LOWBATT * EXECUTE lowbatt-shutdown
AT COMMBAD * START-TIMER commbad-timer 300
AT COMMOK * CANCEL-TIMER commbad-timer
AT NOCOMM * EXECUTE commbad-shutdown
AT SHUTDOWN * EXECUTE powerdown-note
```

`/etc/nut/upssched-cmd.sh` (`chmod +x`):
```sh
#!/bin/sh
case "$1" in
    early-shutdown)
        logger -t upssched "UPS on battery 5 min, forcing shutdown"
        /usr/sbin/upsmon -c fsd
        ;;
    lowbatt-shutdown|commbad-shutdown)
        logger -t upssched "UPS critical or comm lost, forcing shutdown"
        /usr/sbin/upsmon -c fsd
        ;;
    powerdown-note)
        logger -t upssched "shutdown proceeding"
        ;;
esac
```

Start and verify on pbs01:
```bash
systemctl enable --now nut-server
upsc ups1@localhost          # must show ups.status: OL
systemctl enable --now nut-monitor
```

## Config — pve01..pve03 (clients)

`/etc/nut/nut.conf`:
```
MODE=netclient
```

`/etc/nut/upsmon.conf` (no upssched needed; the server drives FSD):
```
RUN_AS_USER nut
MONITOR ups1@<pbs01-mgmt-ip> 1 upsmon-secondary CHANGE_ME_NUT_SECONDARY secondary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
POWERDOWNFLAG /run/nut/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
```

```bash
systemctl enable --now nut-monitor
upsc ups1@<pbs01-mgmt-ip>     # verify reachability from each PVE node
```

## Behavior

- **Brief blip** (mains back within 5 min): `upssched` starts the
  `early-shutdown` timer on ONBATT and cancels it on ONLINE. Nothing shuts
  down; the event is only logged.
- **Extended outage**: the timer fires → `upsmon -c fsd` → FSD flag set.
  Secondaries (PVE nodes) shut down first; the primary (pbs01) waits for them
  (HOSTSYNC), then shuts itself down. With POWERDOWNFLAG set, the UPS is
  commanded to cut output power after `ups.delay.shutdown`, so a mains return
  power-cycles everything cleanly.
- **Low battery**: LB flag → immediate FSD regardless of the timer.
- **Lost UPS comms**: `commbad-timer` (5 min) → FSD. A dead USB cable must
  not leave the cluster running blind into a blackout.
- **Guests**: Proxmox stops running guests as part of host shutdown. Confirm
  your guests actually finish shutting down inside the window during testing;
  guests with long shutdowns are the usual surprise.

## Safe testing

Checklist order — each step is safe; stop when uncomfortable:

- [ ] `upsc ups1@localhost` on pbs01 shows `ups.status: OL`.
- [ ] `upsc ups1@<pbs01-ip>` works from each PVE node.
- [ ] `systemctl status nut-server nut-monitor` clean on all five nodes.
- [ ] `journalctl -u nut-monitor -f`, then briefly unplug the UPS *network*
      cable (not mains): expect ONBATT → timer start → plug back → ONLINE →
      timer cancel, no shutdown.
- [ ] Full test in a maintenance window, non-critical guests stopped:
      `sudo upsmon -c fsd` on pbs01. **This shuts down every node for real.**
      Verify order (PVE nodes → pbs01 last) and that guests stopped cleanly.
- [ ] After the test, confirm the UPS outlet power-cycle behaved as expected
      (or disable the killpower path if you prefer the UPS to stay on).

## Power-on order after a full outage

1. **Switches first** (Nexus 9K, Catalyst 2960-X). Everything depends on the
   network: Corosync needs the Nexus, and iDRAC/IPMI come up for remote
   power-on of anything that didn't self-start.
2. **PBS (pbs01)**. The NUT server is back early so power monitoring resumes,
   and the backup datastore is reachable before any PVE backup job runs.
3. **PVE nodes (pve01–pve03)**. Cluster forms, Corosync reaches quorum,
   guests start in their configured order.

Set AC power recovery to **On** (Dell iDRAC: "AC Power Recovery"; Supermicro
BIOS: "Restore on AC Power Loss" → Power On) on all five nodes so they
self-start when mains returns. Anything without that setting gets powered on
via iDRAC/IPMI in the same 1→2→3 order.
