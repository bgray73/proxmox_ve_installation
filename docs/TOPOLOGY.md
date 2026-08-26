# Proxmox homelab logical topology

This diagram reflects the current planned homelab design:

- 3-node Proxmox VE cluster: 2 × Dell PowerEdge R640 + 1 × Dell PowerEdge R440
- Proxmox Backup Server: Supermicro 6028R-E1CR24N
- Cisco Nexus N9K-C9372TX for 40Gb primary and 10Gb failover/data traffic
- Cisco Catalyst 2960-X for iDRAC, IPMI, and 1Gb management
- Mellanox ConnectX-3 Pro MCX314A-BCCT 40Gb NICs
- Cisco QSFP-H40G-CU5M 5 m passive DAC cables
- Tailscale subnet-router capability for secure remote management from authorized devices anywhere

![Proxmox homelab logical topology](./proxmox_homelab_logical_topology.svg)

## Link roles

- **40Gb QSFP+** — primary high-speed server connectivity for VM, migration, storage, and PBS backup/restore traffic.
- **10Gb RJ45** — secondary/failover path on the Dell Proxmox nodes.
- **1Gb / OOB** — Catalyst 2960-X path for iDRAC, IPMI, and management.
- **Tailscale remote management** — encrypted remote access through a dedicated subnet router; no Proxmox, PBS, iDRAC/IPMI, or switch-management service is exposed directly to the Internet.

## Remote-management path

```text
Authorized remote device
(iPhone / Mac / laptop)
          |
      Tailscale
          |
Dedicated subnet router
(prefer physical Linux appliance)
          |
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

Advertise only the management prefixes needed for administration. Do **not** advertise Corosync or PBS backup-data VLANs through Tailscale. Keep at least one recovery path that does not depend on the Proxmox cluster itself.

For resilience, a second subnet router can be added later. The preferred design is at least one independently powered physical Linux appliance so a PVE cluster outage does not remove remote iDRAC/IPMI access.

See [../remote-access/README.md](../remote-access/README.md) for the Tailscale deployment, ACL/grant guidance, and WireGuard alternatives.

See also [RACK-LAYOUT.md](./RACK-LAYOUT.md) for the physical front/rear rack layout and cable-routing plan.
