# Network security groups: stateful, so egress replies need no rules.

# ── Nodes ─────────────────────────────────────────────────────────────────────

resource "oci_core_network_security_group" "nodes" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-nodes"
  freeform_tags  = local.common_tags
}

# Node to node: etcd (2379-2380), Kubernetes API (6443), kubelet (10250),
# Talos apid/trustd (50000-50001), flannel VXLAN (UDP 4789), NodePorts.
resource "oci_core_network_security_group_security_rule" "nodes_intra" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  description               = "All traffic between nodes"
  direction                 = "INGRESS"
  protocol                  = "all"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.nodes.id
}

# The internal load balancer and the Bastion endpoint both live in the private
# subnet and reach the Kubernetes and Talos APIs on the nodes.
resource "oci_core_network_security_group_security_rule" "nodes_apis" {
  for_each = toset(["6443", "50000"])

  network_security_group_id = oci_core_network_security_group.nodes.id
  description               = "API port ${each.key} from the private subnet (internal LB, Bastion)"
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = var.private_subnet_cidr

  tcp_options {
    destination_port_range {
      min = tonumber(each.key)
      max = tonumber(each.key)
    }
  }
}

# The public NLB preserves client IPs, so its traffic arrives from internet
# addresses, not from the NLB's NSG. The nodes have no public IPs.
resource "oci_core_network_security_group_security_rule" "nodes_ingress_nodeports" {
  for_each = toset([tostring(var.ingress_http_nodeport), tostring(var.ingress_https_nodeport)])

  network_security_group_id = oci_core_network_security_group.nodes.id
  description               = "Ingress controller NodePort ${each.key} through the public NLB"
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"

  tcp_options {
    destination_port_range {
      min = tonumber(each.key)
      max = tonumber(each.key)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_egress" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  description               = "All egress (NAT gateway, service gateway, VCN)"
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

# ── Internal load balancer ────────────────────────────────────────────────────

resource "oci_core_network_security_group" "internal_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-internal-lb"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "internal_lb_ingress" {
  for_each = toset(["6443", "50000"])

  network_security_group_id = oci_core_network_security_group.internal_lb.id
  description               = "API port ${each.key} from the VCN (Bastion sessions, nodes)"
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = var.vcn_cidr

  tcp_options {
    destination_port_range {
      min = tonumber(each.key)
      max = tonumber(each.key)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "internal_lb_egress" {
  network_security_group_id = oci_core_network_security_group.internal_lb.id
  description               = "To the nodes (backends and health checks)"
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.nodes.id
}

# ── Public network load balancer ──────────────────────────────────────────────

resource "oci_core_network_security_group" "public_nlb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-public-nlb"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "public_nlb_ingress" {
  for_each = toset(["80", "443"])

  network_security_group_id = oci_core_network_security_group.public_nlb.id
  description               = "HTTP(S) from the internet, port ${each.key}"
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"

  tcp_options {
    destination_port_range {
      min = tonumber(each.key)
      max = tonumber(each.key)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "public_nlb_egress" {
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  description               = "To the nodes (NodePorts and health checks)"
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.nodes.id
}
