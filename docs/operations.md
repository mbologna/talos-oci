# Operations

## Deploy

```bash
GITOPS_REPO_URL=https://github.com/you/gitops.git GITOPS_PATH=clusters/mine \
GITOPS_HTTPS_USERNAME=you GITOPS_HTTPS_TOKEN=... \
  scripts/deploy.sh
```

1. `import-image.sh` registers the schematic with the Image Factory, downloads
   `oracle-arm64.qcow2`, rewrites it with an 8 KiB cluster size, imports it with UEFI_64
   firmware and A1.Flex compatibility, and prints the image OCID. `deploy.sh` records it in
   `talos-image.auto.tfvars`. If your root module sets `talos_version` or `talos_extensions`,
   export the same values as `TALOS_VERSION` / `TALOS_EXTENSIONS`; otherwise the image follows
   the module's defaults.
2. `tofu apply` creates the network, load balancers, Bastion, bucket and nodes.
3. Once every node runs, the custom image is deleted.
4. `tunnel.sh up` opens Bastion port forwards to the internal load balancer.
5. etcd is bootstrapped on the first node; `talosctl health` waits for all control planes;
   `~/.talos/<cluster>/kubeconfig` points at `https://127.0.0.1:6443`.
6. `bootstrap-argocd.sh` installs Argo CD and the App of Apps. Keep `ARGOCD_CHART_VERSION`
   equal to the version your Argo CD Application pins.

## Access

```bash
scripts/tunnel.sh up        # localhost:6443 (Kubernetes) and localhost:50000 (Talos)
export TALOSCONFIG=~/.talos/<cluster>/talosconfig KUBECONFIG=~/.talos/<cluster>/kubeconfig
talosctl --nodes 10.0.1.10 dashboard
kubectl get nodes
scripts/tunnel.sh down
```

Sessions last up to three hours (`SESSION_TTL`). For day-to-day kubectl without Bastion, run
the Tailscale operator with `apiServerProxyConfig` and use `tailscale configure kubeconfig`.

## Upgrades

Running clusters are upgraded in-cluster, not by Terraform: `talos_version` and
`kubernetes_version` only set what new nodes start with.

- **Talos:** a tuppr `TalosUpgrade` with the installer image
  (`tofu output installer_image`, with the target version). One node at a time, drained.
  Step through every minor's latest patch; never skip a minor.
- **Kubernetes:** a tuppr `KubernetesUpgrade`. The target must be supported by the running
  Talos minor.
- **Extensions:** changing `talos_extensions` changes the schematic, and so the installer image
  the next `TalosUpgrade` must use.
- **Machine-config changes** (patches, Talos inputs): the instances ignore user_data changes,
  so apply the rendered config to running nodes with `scripts/apply-config.sh` (tunnel up,
  `TF_DIR` set; `DRY_RUN=true` shows the change first). It goes one node at a time with
  `--mode no-reboot` and refuses a node whose Kubernetes or Talos version differs from the
  rendered one: set `talos_version` / `kubernetes_version` to what tuppr rolled out first.

## Backups

- **etcd:** talos-backup, from your GitOps repository, to `<cluster>-backups/etcd/`
  (S3 endpoint `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`, a
  bucket-scoped Customer Secret Key). talos-backup never deletes a snapshot: the bucket's
  lifecycle rule expires `etcd/` objects after `etcd_backup_retention_days` (14). Restore:
  `talosctl bootstrap --recover-from <snapshot>` on a fresh first node.
- **Longhorn:** a BackupTarget pointing at `s3://<cluster>-backups@<region>/longhorn`. Set its
  `pollInterval` to a day: every poll lists the bucket, and 5-minute polling exceeds the free
  50,000 requests a month.
- **Boot volumes:** weekly, kept a week.

## Replace a node

```bash
scripts/tunnel.sh up
scripts/replace-node.sh server-1
```

It removes the node's etcd member, recreates the instance from a fresh image (same name and
IP), waits for it to rejoin, and deletes the image. Longhorn rebuilds that node's replicas.

## Tear down

`tofu destroy` removes everything the module created. The bucket must be empty first (it is
versioned: delete every object version).
