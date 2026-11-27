locals {
  common_tags = merge({ cluster = var.cluster_name, managed-by = "talos-oci" }, var.freeform_tags)

  node_ips = { for name, node in var.nodes : name => cidrhost(var.private_subnet_cidr, node.ip_host) }

  # The internal load balancer fronts the Kubernetes API and the Talos API of
  # every node; clients reach it through a Bastion port forward.
  lb_ip            = oci_load_balancer_load_balancer.internal.ip_address_details[0].ip_address
  cluster_endpoint = "https://${local.lb_ip}:6443"

  installer_image = data.talos_image_factory_urls.this.urls.installer
}
