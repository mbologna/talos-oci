# Design

## Free allowance

A Pay As You Go tenancy gets 3,000 A1 OCPU-hours and 18,000 GB-hours a month free (Oracle's
price list, parts B93297 and B93298): 4 OCPU / 24 GB around the clock. A tenancy that was never
upgraded gets half. The rest of the budget: 200 GB of block storage (boot volumes included),
5 volume backups, one network load balancer, one 10 Mbps flexible load balancer, Object
Storage (10 GB Standard + 10 GB Infrequent Access + 10 GB Archive on paid tenancies, 50,000
requests a month). `checks.tf` warns when a plan exceeds the A1 or block allowances
(`a1_free_ocpus`, `a1_free_memory_gbs`).

## Topology

Three control planes with etcd: 2 OCPU / 8 GB, 1 / 8 and 1 / 8. It is the only layout on 4 OCPUs
with a real etcd quorum that uses every OCPU. Losing or rebooting any one node keeps the
Kubernetes API, the ingress and the Longhorn volumes (two replicas on different nodes) up.

Alternatives, scored on HA, free-allowance use, room for apps, cost risk, simplicity and
security:

| Layout | Why not |
|---|---|
| Three control planes of 1 / 8 each | Leaves an OCPU unused |
| Three control planes + one worker, 1 / 6 each | A fourth node of overhead, smaller boot volumes (fewer IOPS for etcd), no HA gain |
| One node, 4 / 24 | The most room for apps and the simplest, but every reboot is an outage |
| One control plane 2 / 12 + one worker 2 / 12 | At Talos's documented minimum, but the control plane is a single point of failure |

### Running below the 2-core minimum

Talos documents 2 cores for a control plane; the two smaller nodes have one. The machine config
compensates: etcd heartbeat 500 ms and election timeout 5 s (stalls ride out instead of
becoming elections), kubelet reservations, a lower API server in-flight limit. Heavy
controllers should prefer the 2-OCPU node.

The layout holds if, over 7 days: no etcd leader change outside reboots, etcd WAL fsync p99
under 100 ms, no `leaderelection lost` in the control-plane logs, and almost no API server 5xx.
If it doesn't, rebuild as one 4 / 24 node, or as one control plane plus one worker.

## Components

| Layer | Choice | Notes |
|---|---|---|
| Image | Image Factory `oracle-arm64`, extensions `iscsi-tools` and `util-linux-tools` (Longhorn) | Imported per deploy and deleted afterwards; upgrades pull the installer from the factory |
| Machine config | Rendered by the `siderolabs/talos` provider, delivered in user_data | 12-13 KB; CI checks the 32,000-byte limit |
| Bootstrap | `scripts/deploy.sh`: `talosctl bootstrap` and Argo CD's Helm chart through a Bastion port forward | Terraform needs no network path to the nodes; Talos doesn't manage Argo CD, so a Kubernetes upgrade never reverts it |
| CNI | Talos's flannel with `kubeNetworkPoliciesEnabled` (kube-network-policies, nftables) | NetworkPolicy without Cilium's memory cost (about 0.8 GiB on three nodes). It filters after kube-proxy's DNAT, as kube-router does, so policies written for k3s keep working. It fails open while its container restarts. Cilium is the fallback |
| Storage | Longhorn on the `longhorn` user volume (`/var/mnt/longhorn`), EPHEMERAL capped at `ephemeral_max_size` | Talos 1.14 mounts `/var/mnt` into the kubelet, so no kubelet extra mount is needed; Longhorn can't fill the volume etcd lives on |
| Access | Internal load balancer (6443, 50000) through OCI Bastion port forwarding | Day-to-day kubectl can go through the Tailscale operator's API-server proxy |
| Upgrades | In-cluster, from GitOps: [tuppr](https://github.com/home-operations/tuppr) `TalosUpgrade` and `KubernetesUpgrade` | One node at a time, drained, in a maintenance window; minors one step at a time |
| etcd backups | [talos-backup](https://github.com/siderolabs/talos-backup) to the bucket's `etcd/` prefix | Needs the Talos API access this module grants (`os:etcd:backup`) |
| Monitoring | OCI alarms on `instance_status` and `UnhealthyBackendsPerNlb`; an APM REST monitor | Outside the cluster, free |

## Network

- VCN with a public subnet (the NLB only) and a private subnet (nodes, internal LB, Bastion
  endpoint). An empty security list replaces OCI's default one, which allows SSH from anywhere;
  network security groups do the filtering.
- The NLB preserves client IPs, so the NodePort rules allow `0.0.0.0/0`: traffic arrives from
  client addresses, not from the NLB. The nodes have no public IPs.
- Pods use 10.244.0.0/16 and services 10.96.0.0/12; keep the VCN outside both.
- The instance metadata service (`169.254.169.254`) is also the VCN's DNS resolver: block
  port 80 from pods, never 53.
