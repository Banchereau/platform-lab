data "proxmox_virtual_environment_nodes" "nodes" {}

data "proxmox_vm" "debian_template" {
  node_name = "pve-1"
  id        = "502"
}

data "local_file" "ssh_public_key" {
  filename = pathexpand("~/.ssh/id_ed25519.pub")
}

resource "proxmox_virtual_environment_vm" "k8s" {
  for_each = var.k8s_vms

  name      = replace(each.key, "_", "-")
  node_name = "pve-1"
  vm_id     = each.value.vm_id

  on_boot       = each.value.on_boot
  scsi_hardware = "virtio-scsi-single"

  clone {
    vm_id = data.proxmox_vm.debian_template.id
  }

  initialization {
    user_data_file_id = proxmox_virtual_environment_file.k3s_cp_cloud_init.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_size
    iothread     = true
  }

  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = true
  }
}
