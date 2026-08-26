# Proxmox homelab logical topology

This diagram reflects the current planned homelab design:

- 3-node Proxmox VE cluster: 2 × Dell PowerEdge R640 + 1 × Dell PowerEdge R440
- Proxmox Backup Server: Supermicro 6028R-E1CR24N
- Cisco Nexus N9K-C9372TX for 40Gb primary and 10Gb failover/data traffic
- Cisco Catalyst 2960-X for iDRAC, IPMI, 1Gb management, and Tailscale subnet-router attachment
- Mellanox ConnectX-3 Pro MCX314A-BCCT 40Gb NICs
- Cisco QSFP-H40G-CU5M 5 m passive DAC cables
- Tailscale subnet-router capability for secure remote management from authorized devices anywhere
- Traditional VLAN underlay with Proxmox SDN/VXLAN overlay transport on VLAN 100

![Proxmox homelab logical topology](./proxmox_homelab_logical_topology.svg)

## VLAN map

| VLAN | Role | Network intent |
|---:|---|---|
| 10 | OOB / iDRAC / IPMI / switch management | Restricted management only |
| 20 | PVE management | GUI, API and SSH management |
| 21 | Corosync | Cluster membership/quorum; low latency; no Tailscale route |
| 30 | PBS management | PBS GUI/API/SSH |
| 31 | PBS backup/restore | Primary PVE↔PBS backup path over 40Gb; no Tailscale route |
| 40 | Infrastructure / Tailscale | DNS/NTP/monitoring/automation and subnet routers |
| 100 | Proxmox SDN / VXLAN transport | Physical underlay for overlay VNets |
| 998 | Blackhole/native | Unused ports/native safety VLAN |

## Link roles

- **40Gb QSFP+** — primary high-speed server connectivity for VM traffic, migration, storage, and PBS backup/restore traffic.
- **10Gb RJ45** — secondary/failover data path on the Dell Proxmox nodes.
- **1Gb / OOB** — Catalyst 2960-X path for iDRAC, IPMI, PVE management fallback, infrastructure management, and Tailscale subnet routers.
- **Tailscale remote management** — encrypted remote access through a dedicated subnet router; no Proxmox, PBS, iDRAC/IPMI, or switch-management service is exposed directly to the Internet.

## Remote-management path

```text
Authorized remote device
(iPhone / Mac / laptop)
          |
      Tailscale
          |
Dedicated subnet router
       VLAN 40
          |
  Firewall / routed policy
          |
   +------+------+----------------+
   |             |                |
VLAN 10       VLAN 20          VLAN 30
OOB/BMC       PVE mgmt         PBS mgmt
   |             |                |
iDRAC/IPMI   PVE GUI/SSH      PBS GUI/SSH
Switch mgmt
```

The Catalyst 2960-X remains Layer 2. The firewall/router owns the gateways and routes between VLANs 10, 20, 30, and 40. The switch itself uses a VLAN 10 management SVI and an `ip default-gateway` toward the firewall/router.

Advertise only the management prefixes needed for administration. Do **not** advertise VLAN 21 Corosync or VLAN 31 PBS backup through Tailscale.

## SDN model

Use traditional VLANs as the physical underlay. Keep management, Corosync, and PBS backup on normal VLANs. Use VLAN 100 as the Proxmox SDN/VXLAN transport so overlay VNets can span PVE01, PVE02, and PVE03 without creating a new physical VLAN for every test network.

See [../network/PORT-MAP.md](../network/PORT-MAP.md), [../network/nexus9k.example.cfg](../network/nexus9k.example.cfg), and [../network/catalyst2960x-oob.example.cfg](../network/catalyst2960x-oob.example.cfg) for the matching switch design.

See [../remote-access/README.md](../remote-access/README.md) for the Tailscale deployment, ACL/grant guidance, and WireGuard alternatives.

See also [RACK-LAYOUT.md](./RACK-LAYOUT.md) for the physical front/rear rack layout and cable-routing plan.
