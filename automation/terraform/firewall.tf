# ---------------------------------------------------------------------------
# Datacenter firewall for the infra VLAN (default-off).
#
# Creates a cluster-level ipset with the infra guest IPs (derived
# programmatically from var.containers / var.vms) and a minimal datacenter
# rule set: DNS to AdGuard, HTTPS to the reverse proxy, PVE node -> ntfy
# (TCP 80, only when var.pve_node_ips is set), and a final DROP for
# anything else between infra guests.
#
# Enable deliberately, e.g.:  tofu apply -var manage_firewall=true
# (or: manage_firewall = true in terraform.tfvars)
#
# READ BEFORE ENABLING:
#   * Apply once WITHOUT the firewall first so the guests exist.
#   * These rules are stored but NOT enforced until you switch the firewall
#     on (Datacenter -> Firewall -> Options -> Firewall: Yes).
#   * Fail-closed by design: the apply refuses to run unless `admin_networks`
#     is set, so enabling the firewall cannot lock you out of node SSH (22)
#     or the Proxmox web UI (8006). This file does not manage PBS or any
#     other management-plane hosts — add their rules separately if needed.
#   * This resource manages the whole datacenter rule list: import any
#     pre-existing datacenter rules first, or they will be replaced.
# ---------------------------------------------------------------------------

variable "manage_firewall" {
  description = "Set true to manage the datacenter firewall (ipset + rules) for the infra VLAN. Default false: enabling is a deliberate choice, see the warnings at the top of firewall.tf."
  type        = bool
  default     = false
}

variable "admin_networks" {
  description = "CIDR(s) allowed to reach node SSH (22) and the Proxmox web UI (8006), e.g. your workstation or admin VLAN. Required (non-empty) when manage_firewall is true — the apply fails closed otherwise so you cannot lock yourself out."
  type        = list(string)
  default     = []
}

variable "pve_node_ips" {
  description = "Management IPs of the PVE nodes (the addresses they use to reach the infra VLAN), e.g. [\"10.10.41.2\", \"10.10.41.3\", \"10.10.41.4\"]. Used to allow node-originated traffic (PVE notification webhooks, restore-test reports) to reach the ntfy LXC on TCP 80. Empty (default) means no such rule is created — notifications to ntfy will be dropped by the datacenter INPUT policy."
  type        = list(string)
  default     = []
}

# Fail closed: refuse to manage the datacenter firewall without admin
# networks defined. Enabling the Proxmox firewall drops unmatched inbound
# traffic, so an empty allow-list would lock you out of SSH and the web UI.
resource "terraform_data" "firewall_safety" {
  count = var.manage_firewall ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(var.admin_networks) > 0
      error_message = "Refusing to manage the datacenter firewall with empty admin_networks: you would lock yourself out of SSH (22) and the Proxmox web UI (8006). Set admin_networks to your admin workstation/VLAN CIDR(s), e.g. [\"10.10.10.0/24\"]."
    }
  }
}

locals {
  # Bare IPs (no /prefix) derived from the fleet definitions.
  infra_guest_ips = concat(
    [for c in var.containers : split("/", c.ipv4)[0]],
    [for v in var.vms : split("/", v.ipv4)[0]],
  )

  # Service endpoints referenced by the allow rules. These keys must exist
  # in var.containers (see the defaults in variables.tf).
  adguard_ip = split("/", var.containers["adguard"].ipv4)[0]
  proxy_ip   = split("/", var.containers["proxy"].ipv4)[0]
  ntfy_ip    = split("/", var.containers["ntfy"].ipv4)[0]
}

resource "proxmox_virtual_environment_firewall_ipset" "infra_guests" {
  count = var.manage_firewall ? 1 : 0

  # No node_name / vm_id / container_id => cluster (datacenter) level ipset.
  # NOTE: the ipset and rules resources have no `tags` argument, so the
  # "Terraform:" comment prefixes below serve as the marker instead.
  name    = "infra-guests"
  comment = "Terraform: infra VLAN guests (automation/terraform)"

  dynamic "cidr" {
    for_each = local.infra_guest_ips
    content {
      name    = cidr.value
      comment = "Terraform: infra guest"
    }
  }
}

resource "proxmox_virtual_environment_firewall_rules" "infra" {
  count = var.manage_firewall ? 1 : 0

  # No node_name / vm_id / container_id => datacenter (cluster) level rules.
  # Rules are evaluated top-down; the DROP stays last.

  depends_on = [proxmox_virtual_environment_firewall_ipset.infra_guests]

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Terraform: allow DNS (TCP) to AdGuard"
    dest    = local.adguard_ip
    proto   = "tcp"
    dport   = "53"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Terraform: allow DNS (UDP) to AdGuard"
    dest    = local.adguard_ip
    proto   = "udp"
    dport   = "53"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Terraform: allow HTTPS to reverse proxy"
    dest    = local.proxy_ip
    proto   = "tcp"
    dport   = "443"
  }

  # No explicit established/related rule: pve-firewall accepts
  # ESTABLISHED,RELATED via conntrack at the top of its chains automatically,
  # and the provider rule schema has no conntrack/state field to express it.

  # Management plane: allow admin networks to reach node SSH and the
  # Proxmox web UI. These MUST come before the final DROP. The
  # terraform_data.firewall_safety precondition above guarantees
  # admin_networks is non-empty whenever this resource exists.
  dynamic "rule" {
    for_each = var.admin_networks
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = "Terraform: admin SSH from ${rule.value}"
      source  = rule.value
      proto   = "tcp"
      dport   = "22"
    }
  }

  dynamic "rule" {
    for_each = var.admin_networks
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = "Terraform: admin Proxmox web UI from ${rule.value}"
      source  = rule.value
      proto   = "tcp"
      dport   = "8006"
    }
  }

  # PVE node -> ntfy: the notification webhooks (docs/NOTIFICATIONS.md) and
  # the restore-test reports (scripts/pbs_restore_test.sh) originate on the
  # nodes and would otherwise hit the datacenter default INPUT policy on the
  # ntfy guest. No rule is created while var.pve_node_ips is empty.
  dynamic "rule" {
    for_each = var.pve_node_ips
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = "Terraform: allow node ${rule.value} to reach ntfy (TCP 80)"
      source  = rule.value
      dest    = local.ntfy_ip
      proto   = "tcp"
      dport   = "80"
    }
  }

  rule {
    type    = "in"
    action  = "DROP"
    comment = "Terraform: drop remaining traffic between infra guests"
    source  = "+infra-guests"
    dest    = "+infra-guests"
  }
}
