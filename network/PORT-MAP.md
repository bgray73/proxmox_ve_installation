# Network port maps

Review and replace interface numbers before applying the example configs.

## Cisco Nexus N9K-C9372TX — high-speed data underlay

The Nexus carries the 40Gb primary data plane, 10Gb failover, Corosync, PBS backup, and Proxmox SDN/VXLAN transport. iDRAC/IPMI and 1Gb management have moved to the Catalyst 2960-X OOB switch.

| Port | Description | Mode | VLANs |
|---|---|---|---|
| E1/11 | PVE01 R640 primary data | trunk | 20,21,31,100; native 20 |
| E1/12 | PVE02 R640 primary data | trunk | 20,21,31,100; native 20 |
| E1/13 | PVE03 R440 primary data | trunk | 20,21,31,100; native 20 |
| E1/15 | PBS01 Supermicro primary data | trunk | 30,31; native 30 |
| E1/21 | PVE01 10Gb failover | trunk | 20,21,31,100; native 20 |
| E1/22 | PVE02 10Gb failover | trunk | 20,21,31,100; native 20 |
| E1/23 | PVE03 10Gb failover | trunk | 20,21,31,100; native 20 |
| E1/48 | firewall/router uplink | trunk | 20,21,30,31,40,100,998 |

> The exact Nexus interfaces used by the four 40Gb QSFP+ server links must be verified on the installed N9K-C9372TX before deployment. The table above is a logical placeholder map, not a claim that E1/11–15 are QSFP ports.

## Cisco Catalyst 2960-X — OOB and 1Gb management

| Port | Description | Mode | VLAN |
|---|---|---|---:|
| Gi1/0/1 | PVE01 R640 iDRAC | access | 10 |
| Gi1/0/2 | PVE02 R640 iDRAC | access | 10 |
| Gi1/0/3 | PVE03 R440 iDRAC | access | 10 |
| Gi1/0/4 | PBS01 Supermicro IPMI | access | 10 |
| Gi1/0/5 | PVE01 1Gb management | access | 20 |
| Gi1/0/6 | PVE02 1Gb management | access | 20 |
| Gi1/0/7 | PVE03 1Gb management | access | 20 |
| Gi1/0/8 | PBS01 1Gb management, optional | access | 30 |
| Gi1/0/9 | UPS management | access | 40 |
| Gi1/0/10 | PDU management | access | 40 |
| Gi1/0/11 | Tailscale subnet router 1 | access | 40 |
| Gi1/0/12 | Tailscale subnet router 2, optional | access | 40 |
| Gi1/0/48 | firewall/router OOB uplink | trunk | 10,20,30,40,998 |

The 2960-X remains Layer 2 in this design. Its management SVI can live in VLAN 10 with `ip default-gateway` pointing at the firewall/router. Inter-VLAN routes for VLANs 10/20/30/40 belong on the firewall/router, not on the OOB switch.

## VLAN intent

| VLAN | Purpose | Suggested CIDR | Routing policy |
|---:|---|---|---|
| 10 | iDRAC/BMC and restricted switch management | 10.10.10.0/24 | firewall/ACL only |
| 20 | PVE management | 10.10.20.0/24 | restricted management |
| 21 | Corosync ring A | 10.10.21.0/24 | no gateway; never through Tailscale |
| 30 | PBS management | 10.10.30.0/24 | restricted management |
| 31 | PVE-to-PBS backup/restore over 40Gb | 10.10.31.0/24 | PVE↔PBS only; never through Tailscale |
| 40 | DNS/NTP/monitoring/automation/Tailscale routers | 10.10.40.0/24 | service-specific policy |
| 100 | Proxmox SDN / VXLAN transport underlay | site-defined | underlay transport; overlay VNets above it |
| 998 | unused/native blackhole | none | no |

## Remote-management routing

The intended path is:

```text
Remote device
   |
Tailscale
   |
Subnet router on VLAN 40
   |
Firewall / routed policy
   +--> VLAN 10  iDRAC / IPMI / switch management
   +--> VLAN 20  PVE management
   +--> VLAN 30  PBS management
```

Advertise only the management prefixes needed by Tailscale. Do not advertise VLAN 21 Corosync or VLAN 31 PBS backup. Use firewall policy to allow only required management destinations and ports.

## Proxmox SDN model

Use the physical VLANs above as the underlay. Keep management, Corosync, and PBS backup on normal VLANs. Use VLAN 100 as the transport underlay for Proxmox SDN/VXLAN VNets such as DEV, TEST, LAB, or DMZ.

## HA improvements

1. Add a second production switch and dual-home the 40Gb/10Gb data plane.
2. Add a second independently powered Tailscale subnet router.
3. If adding Corosync ring B, use a second NIC and preferably a second physical switch.
4. Keep explicit allow-lists for VLAN 31 and default-deny inter-VLAN firewall policy.

See `network/nexus9k.example.cfg` and `network/catalyst2960x-oob.example.cfg` for configuration examples.
