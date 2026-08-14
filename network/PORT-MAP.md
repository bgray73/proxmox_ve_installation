# Nexus 9K port map

Review and replace interface numbers before applying `nexus9k.example.cfg`.

| Port | Description | Mode | VLANs |
|---|---|---|---|
| E1/1–4 | PVE01–04 iDRAC | access | 10 |
| E1/5 | PBS01 BMC | access | 10 |
| E1/11–14 | PVE01–04 data | trunk | 20,21,31,100; native 20 |
| E1/15 | PBS01 data | trunk | 30,31; native 30 |
| E1/46–47 | Tailscale router 1–2 | access | 40 |
| E1/48 | firewall/router uplink | trunk | 10,20,21,30,31,40,100,998 |

## VLAN intent

| VLAN | Purpose | Suggested CIDR | Routed? |
|---:|---|---|---|
| 10 | iDRAC/BMC and restricted switch management | 10.10.10.0/24 | only through firewall/ACL |
| 20 | PVE management | 10.10.20.0/24 | restricted |
| 21 | Corosync ring A | 10.10.21.0/24 | no gateway |
| 30 | PBS management | 10.10.30.0/24 | restricted |
| 31 | PVE-to-PBS backup data | 10.10.31.0/24 | PVE↔PBS only |
| 40 | DNS/NTP/monitoring/automation/Tailscale routers | 10.10.40.0/24 | service-specific policy |
| 100 | VM networks/trunk | site-defined | firewall-defined |
| 998 | unused/native blackhole | none | no |

The single Nexus is a failure domain and the iDRAC network is logically isolated, not true physical out-of-band. Prioritize moving iDRAC/BMC and switch management to a modest dedicated managed switch when practical. A second production switch and dual-homed server links are the later high-availability improvement. Keep Nexus `mgmt0` on a separate management path if possible.

VLAN 20 is native on PVE trunks and VLAN 30 is native on the PBS trunk because the automated installer creates the initial management interface untagged. Backup, Corosync, and VM VLANs remain tagged. If management later moves to tagged subinterfaces, change both host networking and switch native VLANs in the same maintenance window.

An optional second Corosync ring should use another NIC and preferably another physical switch. Two Corosync VLANs on this one Nexus provide traffic separation, not physical redundancy, so VLAN 22 is intentionally not preconfigured.

Apply in a maintenance window: paste VLANs first, then one interface at a time; verify with `show interface status`, `show vlan brief`, `show interface trunk`, and save only after connectivity tests.
