# automation/

Post-deployment automation for the cluster: declarative infrastructure with
Terraform/OpenTofu, and day-2 operations with Ansible. Nothing here runs
during the initial install — this is what you use *after* `create_cluster.sh`
has done its job.

## Layout

- `terraform/` — LXC fleet + infra VMs as code (bpg/proxmox provider).
  Works with Terraform >= 1.6 and OpenTofu.
- `ansible/` — node hardening and rolling updates. Inventory is generated
  from the deploy-kit's `inventory.json`, so there is one source of truth
  for hosts.

## Suggested order of operations

1. Deploy PVE + PBS with the deploy kit as documented in the main README.
2. `cd ansible && python3 scripts/gen_inventory.py > inventory.json`
3. `ansible-playbook -i inventory.json playbooks/harden.yml` — SSH keys, NTP,
   sshd hardening on all five nodes.
4. `cd ../terraform`, copy `terraform.tfvars.example` to `terraform.tfvars`,
   fill in credentials, then `tofu init && tofu plan && tofu apply` (or
   `terraform`).
5. Install your chosen apps inside the containers (AdGuard, NPM, Kuma,
   Semaphore, ntfy, Grafana stack, Docker).
6. Point the containers' DNS at AdGuard once it's live (`dns_servers` var).
7. Schedule PBS verify jobs + a quarterly restore test (see main README).

## Security notes

- `terraform.tfvars` and `ansible/inventory.json` are git-ignored; they
  contain credentials and internal IPs. Prefer `PROXMOX_VE_API_TOKEN` /
  `PROXMOX_VE_ENDPOINT` env vars over tfvars where possible.
- Create a dedicated least-privilege API token for Terraform instead of
  using root.
- The Ansible hardening playbook disables SSH password auth for root —
  make sure your key works before running it (test `ssh root@<node>` first).
