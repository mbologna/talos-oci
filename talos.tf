# Talos machine configuration. Terraform only renders it (no network access to
# the nodes is needed): the nodes read it from their user_data at first boot,
# and scripts/deploy.sh bootstraps etcd through a Bastion port forward.

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.talos_extensions
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "oracle"
  architecture  = "arm64"
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  docs               = false
  examples           = false

  config_patches = [
    templatefile("${path.module}/patches/common.yaml.tftpl", {
      lb_ip                = local.lb_ip
      private_cidr         = var.private_subnet_cidr
      installer_image      = local.installer_image
      ephemeral_max_size   = var.ephemeral_max_size
      talos_api_roles      = var.talos_api_access_roles
      talos_api_namespaces = var.talos_api_access_namespaces
    }),
    templatefile("${path.module}/patches/node.yaml.tftpl", {
      hostname = each.key
    }),
  ]
}

# talosconfig for clients. The endpoint is the local end of the Bastion port
# forward to the internal load balancer (scripts/tunnel.sh).
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = ["127.0.0.1"]
  nodes                = values(local.node_ips)
}
