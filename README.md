# talos-oci

A Terraform/OpenTofu module for a highly available [Talos Linux](https://www.talos.dev) Kubernetes
cluster on Oracle Cloud's free allowance. It is the sibling of
[k3s-oci](https://github.com/mbologna/k3s-oci), which does the same with k3s.

## What it builds

| | Default | Free allowance used |
|---|---|---|
| Nodes | 3 Talos control planes, all schedulable: 2 OCPU / 8 GB, 1 / 8, 1 / 8 (A1.Flex, arm64) | 4 OCPU / 24 GB of A1 (Pay As You Go tenancies; 2 / 12 on never-upgraded ones) |
| Storage | Boot volumes 67 + 67 + 66 GB, each split into Talos's EPHEMERAL volume and a `longhorn` user volume | 200 GB block storage |
| Ingress | Public network load balancer → the ingress controller's NodePorts (30080/30443) on every node, client IP preserved | The free NLB |
| APIs | Internal load balancer for the Kubernetes API (6443) and the Talos API (50000), reached through OCI Bastion | The free 10 Mbps flexible LB, Bastion |
| Backups | One versioned bucket for etcd snapshots and Longhorn backups; weekly boot-volume backups | Object Storage, 3 of 5 volume backups |
| Network | Private nodes behind NAT; Oracle services through a Service Gateway | NAT and service gateways |
| Alerts (opt-in) | OCI Monitoring alarms (instance down, unhealthy NLB backends) and an APM synthetic uptime check | Monitoring, Notifications, APM free tier |

Nothing administrative is public. Talos reads its machine configuration from instance metadata;
etcd is bootstrapped and Argo CD installed by [`scripts/deploy.sh`](scripts/deploy.sh) through a
Bastion port forward. Argo CD then manages the cluster from your GitOps repository.

## Quick start

Requirements: OpenTofu ≥ 1.9 (or Terraform), the OCI CLI, `talosctl`, `kubectl`, `helm`,
`qemu-img`, `curl`, `python3`, `ssh`.

```bash
cd example
cp terraform.tfvars.example terraform.tfvars   # fill in tenancy, compartment, AD, region
cp backend_override.tf.example backend_override.tf   # optional: remote state in OCI
cd ..
GITOPS_REPO_URL=https://github.com/you/gitops.git GITOPS_PATH=clusters/mine \
  scripts/deploy.sh
```

`deploy.sh` imports the Talos image (and deletes it afterwards: custom images cost Object
Storage), applies, bootstraps etcd, writes `~/.talos/<cluster>/{talosconfig,kubeconfig}` and
installs Argo CD with your App of Apps. Use `scripts/tunnel.sh up` to reach the cluster later.

## Limits

- Two control planes run on 1 OCPU, below Talos's documented 2-core minimum. The machine config
  lengthens etcd's timeouts; [docs/design.md](docs/design.md) lists the checks that decide
  whether the layout holds, and the fallbacks.
- Oracle Cloud is a Tier 3 Talos platform (community-tested). The image import works around
  [siderolabs/talos#12557](https://github.com/siderolabs/talos/issues/12557).
- The machine configuration, PKI included, is in instance metadata. See [SECURITY.md](SECURITY.md).

## Documentation

- [docs/design.md](docs/design.md): topology, components and the alternatives considered.
- [docs/operations.md](docs/operations.md): deploying, access, upgrades, backups, replacing a
  node, recovery.
