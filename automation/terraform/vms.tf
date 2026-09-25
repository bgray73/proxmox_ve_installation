# VMs cloned (full clone) from the Ubuntu cloud-init template produced by
# templates/cloud-init/create-ubuntu-cloudinit-template.sh. Full clones keep
# each VM independent of the template afterwards.
resource "proxmox_virtual_environment_vm" "infra" {
  for_each = var.vms

  name        = each.value.hostname
  node_name   = each.value.node
  vm_id       = each.value.vmid
  description = each.value.description
  tags        = ["infra", "terraform"]
  started     = true

  clone {
    vm_id = var.ubuntu_template_vmid
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.vm_storage
    interface    = "scsi0"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge  = var.infra_bridge
    vlan_id = var.infra_vlan
  }

  initialization {
    datastore_id = var.vm_storage

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
      username = var.vm_admin_user
      keys     = [var.ssh_public_key]
    }
  }

  startup {
    order      = tostring(each.value.startup_order)
    up_delay   = "30"
    down_delay = "60"
  }
}
