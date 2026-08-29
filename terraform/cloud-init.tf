resource "proxmox_virtual_environment_file" "k3s_cp_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve-1"

  source_raw {
    file_name = "k3s-cp-cloud-init.yaml"

    data = <<-EOF
      #cloud-config

      hostname: k8s-cp
      fqdn: k8s-cp

      package_update: true

      users:
        - name: xcode
          groups:
            - sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${trimspace(data.local_file.ssh_public_key.content)}

      runcmd:
        - curl -sfL https://get.k3s.io | K3S_TOKEN='${var.k3s_token}' sh -
    EOF
  }
}
