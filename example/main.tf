terraform {
  required_version = ">= 1.9"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.15.0, < 10.0.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.12.0, < 0.13.0"
    }
  }
}

provider "oci" {
  region = var.region
}

module "talos_oci" {
  source = "../"

  tenancy_ocid        = var.tenancy_ocid
  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  cluster_name        = var.cluster_name
  image_id            = var.image_id
  alert_email         = var.alert_email
  uptime_urls         = var.uptime_urls
}

variable "region" {
  type        = string
  description = "OCI region (the tenancy's home region: Always Free resources live there)."
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID (the tenancy OCID works)."
}

variable "availability_domain" {
  type        = string
  description = "Availability domain, e.g. \"RyPa:PHX-AD-1\"."
}

variable "cluster_name" {
  type        = string
  description = "Cluster name."
  default     = "talos-oci"
}

variable "image_id" {
  type        = string
  description = "Talos custom image OCID (scripts/import-image.sh). null only for plans."
  default     = null
}

variable "alert_email" {
  type        = string
  description = "Email for OCI Monitoring alarms (null disables them)."
  default     = null
}

variable "uptime_urls" {
  type        = list(string)
  description = "One HTTPS URL for the APM synthetic uptime check."
  default     = []
}

output "cluster_name" {
  value = module.talos_oci.cluster_name
}

output "talosconfig" {
  value     = module.talos_oci.talosconfig
  sensitive = true
}

output "node_private_ips" {
  value = module.talos_oci.node_private_ips
}

output "node_instance_ids" {
  value = module.talos_oci.node_instance_ids
}

output "internal_lb_ip" {
  value = module.talos_oci.internal_lb_ip
}

output "public_nlb_ip" {
  value = module.talos_oci.public_nlb_ip
}

output "bastion_id" {
  value = module.talos_oci.bastion_id
}

output "installer_image" {
  value = module.talos_oci.installer_image
}

output "disk_image_url" {
  value = module.talos_oci.disk_image_url
}

output "schematic_id" {
  value = module.talos_oci.schematic_id
}

output "talos_version" {
  value = module.talos_oci.talos_version
}

output "backup_bucket" {
  value = module.talos_oci.backup_bucket
}

output "objectstorage_namespace" {
  value = module.talos_oci.objectstorage_namespace
}
