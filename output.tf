output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "talosconfig" {
  description = "talosctl client configuration (endpoint 127.0.0.1: the local end of scripts/tunnel.sh)."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "node_private_ips" {
  description = "Fixed private IP of each node."
  value       = local.node_ips
}

output "node_instance_ids" {
  description = "Instance OCID of each node."
  value       = { for name, inst in oci_core_instance.node : name => inst.id }
}

output "internal_lb_ip" {
  description = "Private IP of the internal load balancer (Kubernetes API 6443, Talos API 50000)."
  value       = local.lb_ip
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint written into the machine configuration."
  value       = local.cluster_endpoint
}

output "public_nlb_ip" {
  description = "Public IP of the network load balancer (HTTP/HTTPS ingress). Point DNS here."
  value       = [for ip in oci_network_load_balancer_network_load_balancer.public.ip_addresses : ip.ip_address if ip.is_public][0]
}

output "bastion_id" {
  description = "OCID of the OCI Bastion (null when enable_bastion = false)."
  value       = one(oci_bastion_bastion.this[*].id)
}

output "schematic_id" {
  description = "Image Factory schematic ID (the extensions baked into the image and the installer)."
  value       = talos_image_factory_schematic.this.id
}

output "installer_image" {
  description = "Installer image for upgrades (tuppr TalosUpgrade, talosctl upgrade)."
  value       = local.installer_image
}

output "disk_image_url" {
  description = "Image Factory URL of the oracle-arm64 disk image (scripts/import-image.sh)."
  value       = data.talos_image_factory_urls.this.urls.disk_image
}

output "talos_version" {
  description = "Talos version of new nodes."
  value       = var.talos_version
}

output "backup_bucket" {
  description = "Object Storage bucket for etcd snapshots (etcd/) and Longhorn backups (longhorn/)."
  value       = oci_objectstorage_bucket.backups.name
}

output "objectstorage_namespace" {
  description = "Object Storage namespace (the S3 endpoint is https://<namespace>.compat.objectstorage.<region>.oraclecloud.com)."
  value       = data.oci_objectstorage_namespace.this.namespace
}
