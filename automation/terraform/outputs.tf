output "containers" {
  description = "Managed LXC containers: name -> node, VMID and IP."
  value = {
    for name, c in proxmox_virtual_environment_container.infra :
    name => {
      node = c.node_name
      vmid = c.vm_id
      ipv4 = var.containers[name].ipv4
    }
  }
}

output "vms" {
  description = "Managed VMs: name -> node, VMID and IP."
  value = {
    for name, v in proxmox_virtual_environment_vm.infra :
    name => {
      node = v.node_name
      vmid = v.vm_id
      ipv4 = var.vms[name].ipv4
    }
  }
}
