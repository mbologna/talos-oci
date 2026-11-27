# Standalone instances with fixed private IPs: a replaced node keeps its name
# and address. Every node is a schedulable Talos control plane.

resource "oci_core_instance" "node" {
  for_each = var.nodes

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = each.value.fault_domain
  display_name        = "${var.cluster_name}-${each.key}"
  shape               = "VM.Standard.A1.Flex"
  freeform_tags       = merge(local.common_tags, { node = each.key })

  shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_id
    boot_volume_size_in_gbs = each.value.boot_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    private_ip       = local.node_ips[each.key]
    hostname_label   = each.key
    nsg_ids          = [oci_core_network_security_group.nodes.id]
  }

  # Talos reads its machine configuration from user_data at first boot. It
  # holds the cluster PKI: only principals that can read instance metadata see
  # it, and infra's NetworkPolicies keep pods away from 169.254.169.254:80.
  metadata = {
    user_data = base64encode(data.talos_machine_configuration.node[each.key].machine_configuration)
  }

  # Talos speaks IMDSv2 ("Authorization: Bearer Oracle").
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  # There is no Oracle Cloud Agent on Talos.
  agent_config {
    is_management_disabled = true
    is_monitoring_disabled = true
  }

  lifecycle {
    precondition {
      condition     = var.image_id != null
      error_message = "image_id is required to create nodes: run scripts/import-image.sh (or scripts/deploy.sh)."
    }

    # The image is deleted after the deploy, and Talos applies configuration
    # changes in place (talosctl apply-config, tuppr). A replacement is always
    # deliberate: scripts/replace-node.sh.
    ignore_changes = [source_details, metadata]
  }
}
