# Nexus 9K port map

Review and replace interface numbers before applying `nexus9k.example.cfg`.

| Port | Description | Mode | VLANs |
|---|---|---|---|
| E1/1–4 | PVE01–04 iDRAC | access | 10 |
| E1/5 | PBS01 BMC | access | 10 |
| E1/11–14 | PVE01–04 data | trunk | 20,30,40,100; native 20 |
| E1/15 | PBS01 data | trunk | 20,30; native 20 |
| E1/46–47 | Tailscale router 1–2 | access | 20 |
| E1/48 | firewall/router uplink | trunk | 10,20,30,40,100 |

## VLAN intent

| VLAN | Purpose | Suggested CIDR | Routed? |
|---:|---|---|---|
| 10 | iDRAC/BMC | 10.10.10.0/24 | only through firewall/ACL |
| 20 | PVE/PBS management | 10.10.20.0/24 | restricted |
| 30 | PBS backup traffic | 10.10.30.0/24 | restricted |
| 40 | Corosync | 10.10.40.0/24 | no gateway preferred |
| 100 | VM networks/trunk | site-defined | firewall-defined |
| 998 | unused/native blackhole | none | no |

The single Nexus is a failure domain and the iDRAC network is logically isolated, not true physical out-of-band. A second switch and dual-homed server links are the later high-availability improvement. Keep switch `mgmt0` on a separate management path if possible.

VLAN 20 is native on server trunks because the automated installer creates the initial PVE/PBS management interface untagged. VLANs 30, 40, and 100 remain tagged. If you later move management to a tagged subinterface, change both host networking and switch native VLAN in the same maintenance window.

Apply in a maintenance window: paste VLANs first, then one interface at a time; verify with `show interface status`, `show vlan brief`, `show interface trunk`, and save only after connectivity tests.
