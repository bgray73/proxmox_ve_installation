# Dual CyberPower UPS graceful Proxmox shutdown

Reviewable config pack for two CyberPower OR1500LCDRTXL2U units, three PVE
nodes (pve01/pve02 R640, pve03 R440), and the Supermicro PBS host pbs01.
Repository changes do not install anything or operate the rack.

## Topology and prerequisites

Both USB cables connect to pve01, which runs two usbhid-ups drivers, upsd,
and primary upsmon. pve02, pve03, and pbs01 run secondary upsmon.
Every host also runs the supplied root policy service for early outage
shutdown and loss of monitoring. Network switches and the management path
must remain battery powered throughout shutdown.

Each protected dual-PSU server has PSU A on UPS A and PSU B on UPS B.
Verify this physically, including PBS, and verify either UPS can sustain the
full failover load. For a single-fed PBS, monitor only its actual supply and
adapt the policy before installation; a single-fed host CAN be protected by NUT,
but a dual-feed rule would be wrong for it.

pve01 is a monitoring single point of failure. An independent NUT appliance is
a later improvement. A fixed stagger does not guarantee that other hosts finish
first. Measure guest and host shutdown durations and reserve sufficient runtime.

## Corrections to the supplied draft

- MINSUPPLIES 1 means at least one usable power supply, including healthy battery
  power. It does not trigger SHUTDOWNCMD merely because both UPS units show OB.
- The independent policy starts a 240-second window only while both feeds show OB.
  Either OL resets it. One OB and one OL does not initiate shutdown.
- Both OB plus either LB requests immediate native shutdown. Native upsmon also
  retains its critical-power/FSD shutdown path.
- Never wait 240 seconds or abort inside SHUTDOWNCMD: once NUT commits to forced
  shutdown, returning from a custom script does not undo that state.
- Unknown/stale/offline states without a confirmed OL feed trigger after a
  separate 60-second grace; one brief query failure is not immediate shutdown.
  This intentionally sacrifices availability during prolonged monitoring loss.
- Primary and secondary credentials are separate. Use primary/secondary names.
- Proxmox's native host shutdown handles guests and configured shutdown ordering.
  Manual concurrent qm/pct loops bypass ordering and can conflict with HA.
- upssched passes its action as argument 1 and UPSNAME/NOTIFYTYPE in the environment.
  The draft ntfy script incorrectly expects two positional arguments.
- upsmon -c fsd on the primary can shut down ALL monitored hosts, not just itself.
- POWERDOWNFLAG can activate distribution shutdown hooks and UPS output cutoff.
  It is omitted here; inspect the installed package hooks before enabling killpower.
  Automatic UPS restart behavior is hardware/config dependent, not guaranteed.

## Files

Templates and the policy service are in [power/nut](../power/nut/).
No real addresses, serial numbers, or passwords are committed.

| Setting | Default | Purpose |
|---|---:|---|
| MINSUPPLIES | 1 | Native NUT redundant supply requirement |
| DELAY | 240 s | Both feeds continuously on battery |
| COMM_DELAY | 60 s | No confirmed mains feed with missing/degraded data |
| POLL | 5 s | Policy poll interval; queries have 4-second timeouts |
| STAGGER | 0 s | Set 60 on pve01 for early outage only |
| Low battery | OB on both, LB on either | Bypass early delay and stagger |

Timers are approximate and include polling/query latency. A policy service restart
resets its timers; native upsmon remains a separate critical-power backstop.

## Manual installation runbook

Do not enable the policy until wiring, HA behavior, guest shutdown, and measured
runtime have been reviewed. These commands are for the operator to run manually.

1. On pve01 install nut-server and nut-client; on the others install nut-client.
   Run apt update first. Confirm installed NUT version and service names with
   systemctl list-unit-files 'nut*'.
2. On pve01 run nut-scanner -U. Verify both units and unique USB serial strings.
   If serials are absent/identical, identify a supported stable USB-port match
   for the installed driver version before proceeding.
3. Copy ups.conf.example, upsd.conf.example, and upsd.users.example to the
   corresponding /etc/nut paths on pve01. Replace every placeholder.
   Generate separate primary and secondary passwords with openssl rand -base64 24.
4. Set MODE=netserver in /etc/nut/nut.conf on pve01, MODE=netclient on clients.
   Copy the primary upsmon template on pve01 and secondary template on clients.
   Secure password-bearing configs root:nut, mode 0640.
5. Allow TCP 3493 only from pve02, pve03, and pbs01 to pve01 through the relevant
   host/inter-VLAN firewalls. Keep credentials and real configuration outside Git.
6. Install nut-policy.sh as /usr/local/sbin/nut-policy.sh, root:root mode 0755,
   policy.conf.example as /etc/nut/policy.conf, root:root mode 0600, and the service
   as /etc/systemd/system/nut-policy.service on every host. Fill UPS addresses
   and set STAGGER=60 only on pve01.
7. On pve01 start the packaged USB driver services and nut-server. Driver unit
   names vary by NUT package; inspect them rather than assuming nut-server
   launches drivers. Verify upsc ups-a@localhost ups.status and ups-b both show OL.
   Start nut-monitor on all four nodes and verify remote upsc queries.
8. Check the Proxmox guest shutdown order/timeouts and guest ACPI/agent behavior.
   If HA is enabled, review the installed-version HA shutdown policy so shutdown
   does not migrate/restart guests onto nodes also powering down. Do not blindly
   disable HA resources using a commented shell loop.
9. Run /usr/local/sbin/nut-policy.sh --dry-run on every node. This makes read-only
   queries and prints one snapshot without modifying guests or powering off.
   It is not an end-to-end shutdown test.
10. Only after review, systemctl daemon-reload and
    systemctl enable --now nut-policy.service. Watch
    journalctl -u nut-policy -u nut-monitor -f.

PBS uses native host shutdown so normal service teardown/filesystem unmounting
occurs. This pack does not coordinate completion of PBS backup/verify/GC tasks,
nor guarantee PBS goes last. Stop scheduled jobs before planned testing.

## Test sequence

Use simulated UPS data first for OL/OL, OB/OL, OB/OB, OB+LB/OB, restoration,
and loss of communications. Validate before attempting a live power-loss test.

During a maintenance window with console access and expendable guests:
- Disconnect one UPS MAINS input briefly; leave its USB/data connection intact.
  Expect ONBATT then ONLINE and no automatic shutdown with the other feed OL.
- A USB/network disconnect produces communication loss, not ONBATT.
- A both-mains test exceeding DELAY really shuts hosts down. pve01 gets an
  additional early-only stagger; critical battery may override that order.
- Never use upsmon -c fsd as a harmless notification test. On pve01 it may shut
  down the entire group. After an FSD test, clear latched FSD by restarting upsd
  when safe and check for leftover killpower flags from any pre-existing config.

Measure total guest/host shutdown time at actual load. Do not rely on the UPS LB
threshold leaving enough runtime for every guest. Adjust DELAY down if necessary.
Native graceful shutdown can still force-stop guests that exceed configured
timeouts; validate application recovery.

## Notifications and recovery

NUT events are logged to the journal. Optional ntfy integration should use the
existing notifications runbook; any upssched hook must use its action argument and
UPSNAME/NOTIFYTYPE environment variables, with bounded curl timeouts and protected
topic credentials. No push endpoint is enabled by this pack.

Hosts shut down while UPS output may remain live. BIOS AC-recovery only helps
after an actual AC loss/restore at the server input; it does not automatically
restart a cleanly powered-off host with live input. Use iDRAC/IPMI/manual power-on
until an independently tested UPS cutoff/restart workflow is added. Restore
networking first, then pve01 for NUT, remaining hosts and PBS, then guests/jobs.

## References

- https://networkupstools.org/docs/man/upsmon.conf.html
- https://networkupstools.org/docs/man/upsmon.html
- https://networkupstools.org/docs/man/upssched.conf.html
- https://networkupstools.org/docs/man/usbhid-ups.html
- https://pve.proxmox.com/pve-docs/chapter-ha-manager.html
