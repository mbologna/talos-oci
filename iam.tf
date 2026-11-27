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
