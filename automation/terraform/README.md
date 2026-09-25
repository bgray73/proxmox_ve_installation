# Terraform — infrastructure as code

Manages the supporting LXC/VM fleet on the cluster with the
[bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
provider. Compatible with both Terraform and OpenTofu.

## What it creates

| Name          | Type | Node  | VMID | IP            | Purpose                              |
|---------------|------|-------|------|---------------|--------------------------------------|
| adguard       | LXC  | pve01 | 200  | 10.10.41.10   | AdGuard Home (DNS + ad blocking)     |
| proxy         | LXC  | pve02 | 201  | 10.10.41.11   | Nginx Proxy Manager (TLS front door) |
| uptime        | LXC  | pve03 | 202  | 10.10.41.12   | Uptime Kuma (monitoring + alerts)    |
| semaphore     | LXC  | pve02 | 203  | 10.10.41.13   | Semaphore (Ansible UI)               |
| ntfy          | LXC  | pve01 | 204  | 10.10.41.14   | ntfy (push notifications)            |
| observability | VM   | pve02 | 300  | 10.10.41.20   | Grafana + Prometheus + Loki          |
| docker        | VM   | pve03 | 301  | 10.10.41.21   | Docker workload host                 |

All guests sit on the infra VLAN (default 30, `10.10.41.0/24`), get static
IPs, have your SSH key injected, and start in dependency order (DNS first).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit it
tofu init        # or: terraform init
tofu plan        # review
tofu apply
```

## Customizing

Everything is driven by the `containers` and `vms` variables — add a service
by adding a map entry (new VMID, IP, node). Shared settings (VLAN, gateway,
storage, template) are variables with defaults in `variables.tf`.

## Notes

- The `lxc_template` volume ID must match a CT template actually present on
  your nodes (`Datacenter -> node -> local -> CT Templates`). Update the
  default if you downloaded a different Debian build.
- `ubuntu_template_vmid` must match the cloud-init template built by
  `templates/cloud-init/create-ubuntu-cloudinit-template.sh`.
- LXCs are unprivileged with nesting disabled. If a future service needs
  Docker *inside* a container, give it its own VM instead.

## Optional modules (default off)

Both are gated behind a boolean variable because enabling either one has
consequences you should choose deliberately.

### firewall.tf — datacenter firewall

Cluster-level ipset `infra-guests` built programmatically from the
`containers`/`vms` IPs, plus a minimal datacenter rule set: DNS (TCP+UDP 53)
to AdGuard, HTTPS (443) to the reverse proxy, and a final DROP for any other
traffic between infra guests. Return traffic for established connections
needs no rule — pve-firewall accepts ESTABLISHED,RELATED via conntrack
automatically, and the provider rule schema has no field to express it.

Why default-off: these rules only take effect once you switch the datacenter
firewall on, and Proxmox drops unmatched inbound traffic when the firewall
is enabled — so switching it on with just this rule set would also block the
Proxmox web UI (8006) and SSH (22) to the nodes. Add allow rules for your
management traffic first (see the warnings at the top of `firewall.tf`).

Enable: `tofu apply -var manage_firewall=true`, after the guests exist.

Note: the ipset/rules resources have no `tags` argument, so everything is
marked with `Terraform:` comment prefixes instead.

### ha.tf — high availability

HA group `infra` spanning `pve_nodes` (default `pve01`–`pve03`), plus one HA
resource per managed guest (`ct:<vmid>` / `vm:<vmid>`), desired state
`started`.

Why default-off: HA only makes sense once the guests exist, and HA-managed
guests must live on storage visible to every node in the group — otherwise a
failover tries to start a guest whose disk isn't reachable. Understand your
fencing/storage story first.

Enable: `tofu apply -var manage_ha=true`.

Note: under the `~> 0.80` pin these are `proxmox_virtual_environment_hagroup`
/ `proxmox_virtual_environment_haresource`. Upstream renamed them to
`proxmox_hagroup` / `proxmox_haresource` (both work on 0.x with a deprecation
warning); the old names are removed in provider v1.0, so plan a rename via a
`moved` block before upgrading past 0.x.
