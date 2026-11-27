# AGENTS.md — guidance for AI coding agents

Terraform/OpenTofu module for a Talos Linux cluster on OCI's free allowance. Sibling of
`mbologna/k3s-oci`. Start with [README.md](README.md) and [docs/design.md](docs/design.md).

## Hard constraints

- **Free allowance only.** A1.Flex up to `a1_free_ocpus` / `a1_free_memory_gbs` (4 / 24 on Pay
  As You Go, 2 / 12 otherwise), 200 GB block storage, 5 volume backups, one NLB, one 10 Mbps
  flexible LB, Object Storage within the free tiers. Flag anything paid instead of adding it.
- **Nothing administrative is public.** The Kubernetes and Talos APIs sit behind the internal
  load balancer and Bastion; the public NLB carries only 80/443 to the ingress NodePorts.
- **Terraform never connects to the nodes.** It renders the machine config into user_data;
  `scripts/deploy.sh` bootstraps through Bastion. Don't add `talos_machine_configuration_apply`
  or `talos_machine_bootstrap`: they need a network path to TCP 50000.
- **Talos doesn't manage Argo CD** (no `extraManifests` / `inlineManifests` for it): a Kubernetes
  upgrade re-applies Talos-managed manifests and would revert Argo CD.
- **Custom images are transient**: import, launch, delete. The instances ignore `source_details`
  and `metadata`.
- Secrets never go into git; the state holds `talos_machine_secrets` and lives in an encrypted
  remote backend.

## File map

```
versions.tf       providers (oracle/oci, siderolabs/talos)
vars.tf           inputs; versions carry # renovate: comments
locals.tf         node IPs, cluster endpoint, installer image
network.tf        VCN, IGW, NAT, Service Gateway, route tables, empty security list, subnets
nsg.tf            NSGs: nodes, internal LB, public NLB
lb.tf             internal flexible LB: 6443 and 50000 to every node
nlb.tf            public NLB: 80/443 to the ingress NodePorts
compute.tf        one oci_core_instance per node (fixed IP, user_data, IMDSv2 only)
talos.tf          Image Factory schematic, machine secrets, machine configs, talosconfig
objectstorage.tf  backups bucket (versioned, noncurrent versions purged after 2 days)
backup.tf         weekly boot-volume backups
monitoring.tf     ONS topic, alarms, APM free-tier synthetic monitor (alert_email)
bastion.tf        OCI Bastion for the port forwards
checks.tf         free-allowance and user_data size checks
output.tf         outputs
patches/          machine-config patches (Talos 1.14 multi-document format)
scripts/          import-image, deploy, tunnel, bootstrap-argocd, replace-node, validate-machine-config
example/          root module used by CI and as a starting point
docs/             design.md, operations.md
```

## Machine config

- Patches use the Talos 1.14 documents (`KubeNodeConfig`, `KubeletConfig`,
  `KubeFlannelCNIConfig`, `VolumeConfig`, `UserVolumeConfig`, …). The multi-document kubelet
  config has no extra mounts: Longhorn uses the `longhorn` user volume at `/var/mnt/longhorn`,
  which Talos mounts into the kubelet.
- Run `scripts/validate-machine-config.sh` (needs `talosctl`) after changing `patches/`; CI runs
  it too.

## Checks before pushing

```bash
tofu fmt -recursive
(cd example && tofu init -backend=false && tofu validate)
tflint --init && tflint --recursive
shellcheck scripts/*.sh
scripts/validate-machine-config.sh
```

## Commits and releases

Conventional Commits (header ≤ 72 characters, imperative, no AI attribution trailers), one
concern per commit, merged through pull requests with merge commits. auto-release tags
versions from the commit types every Monday; never create tags by hand.
