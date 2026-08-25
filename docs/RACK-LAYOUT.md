# Dell 42U rack layout

Physical rack plan for the Proxmox home lab.

## Hardware in scope

- Dell PowerEdge R640 #1 — Proxmox VE
- Dell PowerEdge R640 #2 — Proxmox VE
- Dell PowerEdge R440 — Proxmox VE
- Supermicro 6028R-E1CR24N — Proxmox Backup Server
- Cisco Nexus N9K-C9372TX — primary high-speed/data switch
- Cisco Catalyst 2960-X — out-of-band and 1Gb management switch
- 24-port keystone patch panel
- 1U brush pass-through panel
- CCNA lab equipment
- CyberPower OR1500LCDRTXL2U UPS

## Recommended rack elevation

The servers are intentionally mounted high enough that 2 m (6.6 ft) QSFP+ DAC cables can reach from the front-facing Nexus QSFP+ ports, through the brush panel, down the rear cable-management path, and into the server NICs without being stretched.

```text
FRONT VIEW — Dell 42U

U42  24-port Keystone Patch Panel
U41  Catalyst 2960-X
U40  Cisco Nexus N9K-C9372TX
U39  1U Brush Pass-Through Panel
U38  1U Horizontal Cable Manager

U37  CCNA Lab Equipment
U36  CCNA Lab Equipment
U35  CCNA Lab Equipment
U34  CCNA Lab Equipment
U33  Reserved / Cable Management

U32  Dell R640 #1 — Proxmox VE
U31  Dell R640 #2 — Proxmox VE
U30  Dell R440    — Proxmox VE
U29  Supermicro 6028R-E1CR24N — Proxmox Backup Server
U28  Supermicro 6028R-E1CR24N — Proxmox Backup Server

U27  Reserved
U26  Reserved
U25  Reserved
U24  Reserved
U23  Reserved
U22  Reserved
U21  Reserved
U20  Reserved
U19  Reserved
U18  Reserved
U17  Reserved
U16  Reserved
U15  Reserved
U14  Reserved
U13  Reserved
U12  Reserved
U11  Reserved
U10  Reserved
U09  Reserved
U08  Reserved
U07  Reserved

U06  CyberPower OR1500LCDRTXL2U UPS
U05  CyberPower OR1500LCDRTXL2U UPS
U04  Reserved / future UPS
U03  Reserved / future UPS
U02  Reserved
U01  Reserved

BOTTOM
```

> Keep heavy equipment such as UPS units at the bottom of the cabinet. Final UPS U positions can be adjusted to match rail requirements and any second UPS added later.

## 40Gb server network

Planned 40Gb adapters are Mellanox ConnectX-3 Pro MCX314A-BCCT dual-port QSFP+ NICs.

Use one 40Gb port initially on each server and leave the second NIC port available for future use.

```text
Nexus 9372TX QSFP+ 40G ports

40G-1  -> 2 m QSFP+ DAC -> R640 #1 MCX314A-BCCT Port 1
40G-2  -> 2 m QSFP+ DAC -> R640 #2 MCX314A-BCCT Port 1
40G-3  -> 2 m QSFP+ DAC -> R440    MCX314A-BCCT Port 1
40G-4  -> 2 m QSFP+ DAC -> Supermicro PBS MCX314A-BCCT Port 1
40G-5  -> Spare
40G-6  -> Spare
```

### DAC routing

```text
Nexus QSFP+ ports (front)
        |
        v
U39 brush pass-through
        |
        v
rear vertical cable-management path
        |
        +--> R640 #1
        +--> R640 #2
        +--> R440
        +--> Supermicro PBS
```

Use 2 m passive QSFP+ DAC cables. Avoid tight bends and do not leave the cables under tension.

## 10Gb failover path

The Dell Proxmox nodes keep their existing 10Gb RJ45 interfaces as a secondary/failover path to the Nexus 9372TX.

```text
R640 #1 40G QSFP+ -> Nexus  PRIMARY
         10G RJ45  -> Nexus  FAILOVER

R640 #2 40G QSFP+ -> Nexus  PRIMARY
         10G RJ45  -> Nexus  FAILOVER

R440    40G QSFP+ -> Nexus  PRIMARY
         10G RJ45  -> Nexus  FAILOVER
```

For Proxmox, use active-backup bonding if automatic interface failover is desired. Do not use mismatched 40G and 10G links in a normal load-balancing bond.

## Management network

Use the Catalyst 2960-X for out-of-band and 1Gb management traffic.

```text
2960-X
  -> R640 #1 iDRAC
  -> R640 #2 iDRAC
  -> R440 iDRAC
  -> Supermicro IPMI
  -> R640 #1 1Gb management
  -> R640 #2 1Gb management
  -> R440 1Gb management
  -> UPS management
  -> PDU management (when installed)
```

The Nexus remains the primary high-speed switch for 10Gb/40Gb Proxmox, VM, migration, backup, and storage traffic.

## Patch panel

The 24-port keystone panel is primarily for structured copper cabling rather than direct server-to-switch links.

Suggested uses:

- House Ethernet drops
- Access points
- Cameras
- Workbench/lab connections
- Infrastructure management devices
- Future permanent Cat6/Cat6A runs

Direct server 10Gb/40Gb connections should normally run directly to the Nexus.

## Rear cable-management plan

Keep power and network bundles separated where practical.

```text
REAR VIEW

Left vertical path:   AC power / PDU cabling
Right vertical path:  Ethernet / DAC / management cabling
```

If two PDUs are installed, mount one along each rear side of the cabinet where possible.

## Power notes

Current UPS:

- CyberPower OR1500LCDRTXL2U
- 1500 VA / 1125 W
- 120 V / 15 A input

The current design should start with two separate 15 A branch circuits and two UPSs if available. Measure actual server load before deciding whether a third circuit/UPS is necessary.

For dual-PSU equipment, an eventual A/B layout can be used when each power path has sufficient capacity:

```text
PSU A -> PDU A -> UPS A -> Circuit A
PSU B -> PDU B -> UPS B -> Circuit B
```

Do not assume two wall outlets are separate circuits; verify them at the breaker panel.

## Physical installation order

1. Install UPS equipment at the bottom.
2. Install rear PDUs and vertical cable management.
3. Install the three Dell servers and Supermicro.
4. Install Nexus, Catalyst, brush panel, cable manager, and patch panel.
5. Install CCNA lab equipment.
6. Route power first, keeping it on its designated side.
7. Route QSFP+ DACs through the brush panel and rear cable path.
8. Route 10Gb, 1Gb, iDRAC, and IPMI cables.
9. Label both ends of every cable.
10. Verify DAC reach and rail movement before final Velcro dressing.

## Suggested cable labels

```text
PVE01-40G-A
PVE01-10G-A
PVE01-MGMT
PVE01-IDRAC

PVE02-40G-A
PVE02-10G-A
PVE02-MGMT
PVE02-IDRAC

PVE03-40G-A
PVE03-10G-A
PVE03-MGMT
PVE03-IDRAC

PBS01-40G-A
PBS01-IPMI
```

Use Velcro rather than zip ties around DAC and fiber-style cabling so cables are not pinched and can be serviced easily.
