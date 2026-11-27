# Optional: the nodes' instance principal may list the backups bucket, so an
# in-cluster freshness check (for example mbologna/backup-monitor) can read
# the age of the newest etcd snapshot without a stored key. The dynamic group
# matches the node instances by OCID, so it follows replacements. Pods reach
# the instance principal only through the metadata service, which
# NetworkPolicies keep closed to everything but such a check.

resource "oci_identity_dynamic_group" "nodes" {
  count = var.instance_principal_backup_read ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${var.cluster_name}-nodes"
  description    = "${var.cluster_name} Talos nodes (backup bucket read access)"
  matching_rule  = "ANY {${join(", ", [for inst in oci_core_instance.node : "instance.id = '${inst.id}'"])}}"
  freeform_tags  = local.common_tags
}

resource "oci_identity_policy" "nodes_backup_read" {
  count = var.instance_principal_backup_read ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-nodes-backup-read"
  description    = "${var.cluster_name} nodes: list the backups bucket"
  freeform_tags  = local.common_tags
  statements = [
    for verb in ["read buckets", "inspect objects"] :
    "Allow dynamic-group ${oci_identity_dynamic_group.nodes[0].name} to ${verb} in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'"
  ]
}

# Object Storage runs the backups bucket's lifecycle rule (purge noncurrent
# versions) as its own regional service principal, which needs this grant;
# without it the lifecycle policy is rejected (InsufficientServicePermissions).
# The principal names the region (objectstorage-us-phoenix-1); it comes from
# the availability domain, whose middle part is the region's key (PHX) or,
# for newer regions, its name (EU-FRANKFURT-1).
data "oci_identity_regions" "all" {}

locals {
  ad_region = regex("^[^:]+:(.+)-AD-[1-3]$", var.availability_domain)[0]
  region_name = one([
    for r in data.oci_identity_regions.all.regions : r.name
    if upper(r.key) == local.ad_region || upper(r.name) == local.ad_region
  ])
}

resource "oci_identity_policy" "object_storage_lifecycle" {
  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-objectstorage-lifecycle"
  description    = "${var.cluster_name}: Object Storage may apply the backups bucket's lifecycle rule"
  freeform_tags  = local.common_tags
  statements = [
    "Allow service objectstorage-${local.region_name} to manage object-family in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'"
  ]
}
