# Terraform — infrastructure as code

Manages the supporting LXC/VM fleet on the cluster with the
[bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
provider. Compatible with both Terraform and OpenTofu.

## What it creates

| Name          | Type | Node  | VMID | IP            | Purpose                              |
|---------------|------|-------|------|---------------|--------------------------------------|
| adguard       | LXC  | pve01 | 200  | 10.10.30.10   | AdGuard Home (DNS + ad blocking)     |
| proxy         | LXC  | pve02 | 201  | 10.10.30.11   | Nginx Proxy Manager (TLS front door) |
| uptime        | LXC  | pve03 | 202  | 10.10.30.12   | Uptime Kuma (monitoring + alerts)    |
| semaphore     | LXC  | pve04 | 203  | 10.10.30.13   | Semaphore (Ansible UI)               |
| ntfy          | LXC  | pve01 | 204  | 10.10.30.14   | ntfy (push notifications)            |
| observability | VM   | pve02 | 300  | 10.10.30.20   | Grafana + Prometheus + Loki          |
| docker        | VM   | pve03 | 301  | 10.10.30.21   | Docker workload host                 |

All guests sit on the infra VLAN (default 30, `10.10.30.0/24`), get static
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
