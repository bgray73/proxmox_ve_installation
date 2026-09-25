# LXC fleet for infrastructure services. Unprivileged, static IPs on the infra
# VLAN, spread across nodes. Startup order brings DNS up first so everything
# else can resolve during boot.
resource "proxmox_virtual_environment_container" "infra" {
  for_each = var.containers

  node_name   = each.value.node
  vm_id       = each.value.vmid
  description = each.value.description
  tags        = ["infra", "terraform"]

  unprivileged = true

  operating_system {
    template_file_id = var.lxc_template
    type             = "debian"
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.container_storage
    size         = each.value.disk_gb
  }

  network_interface {
    name    = "eth0"
    bridge  = var.infra_bridge
    vlan_id = var.infra_vlan
  }

  initialization {
    hostname = each.value.hostname

    ip_config {
      ipv4 {
        address = each.value.ipv4
        gateway = var.infra_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  features {
    # None of these services need Docker-in-LXC; keep nesting off.
    nesting = false
  }

  startup {
    order      = tostring(each.value.startup_order)
    up_delay   = "15"
    down_delay = "30"
  }
}
