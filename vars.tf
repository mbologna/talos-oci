# ── OCI placement ─────────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID (home region resources and service lookups)."

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "tenancy_ocid must be a tenancy OCID (ocid1.tenancy...)."
  }
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment for every resource of the cluster (the tenancy OCID works)."

  validation {
    condition     = can(regex("^ocid1\\.(tenancy|compartment)\\.", var.compartment_ocid))
    error_message = "compartment_ocid must be a tenancy or compartment OCID."
  }
}

variable "availability_domain" {
  type        = string
  description = "Availability domain for the nodes, e.g. \"RyPa:PHX-AD-1\"."

  validation {
    condition     = can(regex("^[^:]+:[A-Z0-9-]+-AD-[1-3]$", var.availability_domain))
    error_message = "availability_domain must look like \"<prefix>:<REGION>-AD-<n>\"."
  }
}

variable "cluster_name" {
  type        = string
  description = "Prefix of every display name, the Talos cluster name and the backup bucket name."
  default     = "talos-oci"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-30 characters of lowercase letters, digits and hyphens."
  }
}

variable "freeform_tags" {
  type        = map(string)
  description = "Extra freeform tags added to every resource."
  default     = {}
}

# ── Nodes ─────────────────────────────────────────────────────────────────────

variable "nodes" {
  type = map(object({
    ocpus        = number
    memory_gbs   = number
    boot_gb      = number
    fault_domain = optional(string)
    ip_host      = number
  }))
  description = <<-EOT
    Control-plane nodes, keyed by hostname. Every node is a schedulable Talos
    control plane; use 1 or 3 (etcd quorum). ip_host is the host number of the
    node's fixed private IP inside private_subnet_cidr. The default fills the
    Pay As You Go Always Free A1 allowance (4 OCPU / 24 GB) and the 200 GB
    block storage allowance.
  EOT
  default = {
    server-0 = { ocpus = 2, memory_gbs = 8, boot_gb = 67, fault_domain = "FAULT-DOMAIN-1", ip_host = 10 }
    server-1 = { ocpus = 1, memory_gbs = 8, boot_gb = 67, fault_domain = "FAULT-DOMAIN-2", ip_host = 11 }
    server-2 = { ocpus = 1, memory_gbs = 8, boot_gb = 66, fault_domain = "FAULT-DOMAIN-3", ip_host = 12 }
  }

  validation {
    condition     = contains([1, 3, 5], length(var.nodes))
    error_message = "nodes must hold 1, 3 or 5 control planes (an etcd quorum)."
  }

  validation {
    condition     = alltrue([for k, n in var.nodes : can(regex("^[a-z0-9][a-z0-9-]{0,14}$", k))])
    error_message = "Node keys become hostnames and OCI hostname labels: up to 15 lowercase letters, digits and hyphens."
  }

  validation {
    condition     = alltrue([for n in var.nodes : n.boot_gb >= 50])
    error_message = "boot_gb must be at least 50 (OCI's minimum boot volume)."
  }

  validation {
    condition     = alltrue([for n in var.nodes : n.fault_domain == null || can(regex("^FAULT-DOMAIN-[1-3]$", n.fault_domain))])
    error_message = "fault_domain must be FAULT-DOMAIN-1, -2 or -3 (or null)."
  }
}

variable "image_id" {
  type        = string
  description = <<-EOT
    OCID of the Talos custom image the nodes boot from. scripts/import-image.sh
    imports it from the Image Factory and prints the OCID; scripts/deploy.sh
    deletes the image after the apply (instances keep their boot volumes, and
    upgrades pull the installer from the factory). null only for plans.
  EOT
  default     = null

  validation {
    condition     = var.image_id == null || can(regex("^ocid1\\.image\\.", var.image_id))
    error_message = "image_id must be an image OCID (ocid1.image...)."
  }
}

# ── Talos and Kubernetes ──────────────────────────────────────────────────────

variable "talos_version" {
  type        = string
  description = "Talos version of new nodes and of the machine-config contract. Running nodes are upgraded in-cluster (tuppr), not by changing this."
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "v1.14.7"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_version))
    error_message = "talos_version must look like v1.14.7."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version of new clusters (must be supported by talos_version)."
  # renovate: datasource=github-releases depName=kubernetes/kubernetes
  default = "1.37.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.37.1 (no leading v)."
  }
}

variable "talos_extensions" {
  type        = list(string)
  description = "Official Image Factory system extensions baked into the image and the installer (Longhorn needs iscsi-tools and util-linux-tools)."
  default     = ["siderolabs/iscsi-tools", "siderolabs/util-linux-tools"]
}

variable "ephemeral_max_size" {
  type        = string
  description = "Size cap of the EPHEMERAL volume (container images, logs, etcd). The rest of the boot volume becomes the \"longhorn\" user volume at /var/mnt/longhorn."
  default     = "24GiB"
}

variable "talos_api_access_roles" {
  type        = list(string)
  description = "Talos API roles pods may request through a ServiceAccount (talos-backup needs os:etcd:backup, tuppr needs os:admin)."
  default     = ["os:etcd:backup", "os:admin"]
}

variable "talos_api_access_namespaces" {
  type        = list(string)
  description = "Namespaces whose ServiceAccounts may use the Talos API."
  default     = ["talos-backup", "tuppr-system"]
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vcn_cidr" {
  type        = string
  description = "VCN CIDR. Must not overlap the pod (10.244.0.0/16) or service (10.96.0.0/12) networks."
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be a valid CIDR."
  }
}

variable "public_subnet_cidr" {
  type        = string
  description = "Public subnet (the network load balancer only)."
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "Private subnet (nodes, internal load balancer, Bastion endpoint)."
  default     = "10.0.1.0/24"
}

variable "ingress_http_nodeport" {
  type        = number
  description = "NodePort of the ingress controller's HTTP entrypoint (the NLB forwards :80 here)."
  default     = 30080
}

variable "ingress_https_nodeport" {
  type        = number
  description = "NodePort of the ingress controller's HTTPS entrypoint (the NLB forwards :443 here)."
  default     = 30443
}

# ── Optional features ─────────────────────────────────────────────────────────

variable "enable_bastion" {
  type        = bool
  description = "Create an OCI Bastion for port forwarding to the Talos API (50000) and the Kubernetes API (6443) behind the internal load balancer. scripts/tunnel.sh uses it."
  default     = true
}

variable "bastion_client_cidrs" {
  type        = list(string)
  description = "Client CIDRs allowed to open Bastion sessions (sessions also need your SSH key)."
  default     = ["0.0.0.0/0"]
}

variable "enable_boot_volume_backups" {
  type        = bool
  description = "Weekly boot-volume backups kept one week (one per node; Always Free allows 5)."
  default     = true
}

variable "alert_email" {
  type        = string
  description = "Email for OCI Monitoring alarms (instance down, unhealthy NLB backends, failing uptime checks). null skips monitoring."
  default     = null
}

variable "uptime_urls" {
  type        = list(string)
  description = "HTTPS URLs checked every 10 minutes by a free-tier APM synthetic monitor (needs alert_email). Up to 10 runs an hour are free: keep this to one URL."
  default     = []

  validation {
    condition     = length(var.uptime_urls) <= 1
    error_message = "The free APM tier allows 10 synthetic runs an hour: one URL every 10 minutes."
  }
}

# ── Always Free guardrails ────────────────────────────────────────────────────

variable "a1_free_ocpus" {
  type        = number
  description = "Free A1 OCPUs of the tenancy: 4 on Pay As You Go (3,000 OCPU-hours a month), 2 on a never-upgraded Always Free tenancy."
  default     = 4
}

variable "a1_free_memory_gbs" {
  type        = number
  description = "Free A1 memory of the tenancy: 24 GB on Pay As You Go (18,000 GB-hours a month), 12 GB on a never-upgraded Always Free tenancy."
  default     = 24
}
