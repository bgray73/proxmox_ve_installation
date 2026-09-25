# ---------------------------------------------------------------------------
# High availability for the infra fleet (default-off).
#
# One HA group spanning the PVE nodes, plus one HA resource per
# Terraform-managed guest (ct:<vmid> / vm:<vmid>), all desired-state
# "started".
#
# Enable deliberately, e.g.:  tofu apply -var manage_ha=true
# (or: manage_ha = true in terraform.tfvars)
#
# Only enable once:
#   * the guests exist (apply once WITHOUT ha first), and
#   * you understand the fencing/storage story: an HA-managed guest must live
#     on storage visible to every node in the group, otherwise a failover
#     tries to start a guest whose disk isn't reachable.
#
# PROVIDER NOTE: proxmox_virtual_environment_hagroup /
# proxmox_virtual_environment_haresource are the correct names under the
# ~> 0.80 pin used here. Upstream renamed them to proxmox_hagroup /
# proxmox_haresource (ADR-007); both names work on 0.x with a deprecation
# warning, and the old names are removed in provider v1.0 — plan a rename
# (terraform `moved` block) before upgrading past 0.x.
# ---------------------------------------------------------------------------

variable "manage_ha" {
  description = "Set true to manage the HA group + resources for the infra fleet. Default false: enable only once guests exist and the fencing/storage story is understood, see ha.tf."
  type        = bool
  default     = false
}

variable "pve_nodes" {
  description = "PVE cluster node names forming the infra HA group."
  type        = list(string)
  default     = ["pve01", "pve02", "pve03"]
}

resource "proxmox_virtual_environment_hagroup" "infra" {
  count = var.manage_ha ? 1 : 0

  group   = "infra"
  comment = "Terraform: HA group for infra VLAN guests (automation/terraform)"

  # Map of node name => priority (null = no explicit priority).
  nodes = { for n in var.pve_nodes : n => null }

  restricted  = false
  no_failback = false
}

resource "proxmox_virtual_environment_haresource" "containers" {
  # for_each (not count): one HA resource per managed container, gated on
  # manage_ha the same way the group above is gated on count.
  for_each = var.manage_ha ? var.containers : {}

  depends_on = [
    proxmox_virtual_environment_hagroup.infra,
    proxmox_virtual_environment_container.infra,
  ]

  resource_id = "ct:${each.value.vmid}"
  group       = proxmox_virtual_environment_hagroup.infra[0].group
  state       = "started"
  comment     = "Terraform: HA for ${each.value.hostname} (automation/terraform)"
}

resource "proxmox_virtual_environment_haresource" "vms" {
  for_each = var.manage_ha ? var.vms : {}

  depends_on = [
    proxmox_virtual_environment_hagroup.infra,
    proxmox_virtual_environment_vm.infra,
  ]

  resource_id = "vm:${each.value.vmid}"
  group       = proxmox_virtual_environment_hagroup.infra[0].group
  state       = "started"
  comment     = "Terraform: HA for ${each.value.hostname} (automation/terraform)"
}
