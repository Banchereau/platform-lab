resource "proxmox_virtual_environment_file" "k3s_cp_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve-1"

  source_raw {
    file_name = "k3s-cp-cloud-init.yaml"

    data = <<-CLOUDINIT
      #cloud-config

      hostname: k8s-cp
      fqdn: k8s-cp
      manage_etc_hosts: true

      package_update: true

      write_files:
        - path: /etc/resolv.conf
          permissions: "0644"
          content: |
            nameserver 192.168.1.254
            nameserver 1.1.1.1

      users:
        - name: xcode
          groups:
            - sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${trimspace(data.local_file.ssh_public_key.content)}
    CLOUDINIT
  }
}

resource "proxmox_virtual_environment_file" "k3s_worker_cloud_init" {
  for_each = {
    for name, vm in var.k8s_vms :
    name => vm
    if name != "k8s_cp"
  }

  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve-1"

  source_raw {
    file_name = "${replace(each.key, "_", "-")}-cloud-init.yaml"

    data = <<-CLOUDINIT
      #cloud-config

      hostname: ${replace(each.key, "_", "-")}
      fqdn: ${replace(each.key, "_", "-")}
      manage_etc_hosts: true

      package_update: true

      write_files:
        - path: /etc/resolv.conf
          permissions: "0644"
          content: |
            nameserver 192.168.1.254
            nameserver 1.1.1.1

      users:
        - name: xcode
          groups:
            - sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${trimspace(data.local_file.ssh_public_key.content)}
    CLOUDINIT
  }
}
