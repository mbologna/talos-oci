# Security Policy

## Supported versions

Releases follow [semantic versioning](https://semver.org) and are listed on the
[Releases page](https://github.com/mbologna/talos-oci/releases). Security fixes land on `main`
and ship in the next release; only the latest minor version is supported. Pin
`?ref=vX.Y.Z` and upgrade to the newest release to receive fixes.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

1. Go to the [Security tab](https://github.com/mbologna/talos-oci/security) of this repository.
2. Click **"Report a vulnerability"** to open a private security advisory.
3. Describe the issue, steps to reproduce, and potential impact.

You can expect an acknowledgement within **48 hours** and a fix or mitigation plan within
**14 days** for confirmed vulnerabilities.

## Scope

In scope: the Terraform module, the machine-config patches, the scripts and the documentation;
secrets leakage from Terraform state, user_data or git history; network exposure of the
cluster's APIs.

Out of scope: vulnerabilities in upstream projects (Talos, Kubernetes, Longhorn, Argo CD, the
OCI provider), which belong upstream.

## Known security trade-offs

- **Machine configuration in user_data.** Talos reads its configuration, which holds the
  cluster PKI, from OCI instance metadata. Anyone who can read the instance's metadata (OCI
  IAM `read instances`, or a process that reaches `169.254.169.254:80` on a node) can read it.
  Restrict instance read access in IAM. Pods can't reach the metadata service: a policy-routing
  rule on every node (`block_pod_metadata_access`, default on) rejects traffic from the pod
  network to `169.254.169.254`, from the pod's first packet on. Host-network pods use the node's
  address and are not covered: keep them to trusted system components. Pods resolve names
  through Talos's host DNS (`169.254.116.108`), not the VCN resolver, so DNS is unaffected.
- **Terraform state holds every cluster secret** (`talos_machine_secrets`). Keep it in an
  encrypted, access-controlled backend; never commit it.
- **NetworkPolicy enforcement fails open**: if the kube-network-policies container of the
  flannel DaemonSet stops, traffic is allowed until it restarts. It also filters only pods whose
  IP it has already added to its per-node set: a new pod's first second or so of traffic is not
  filtered (measured on Talos 1.14.7; Talos's flannel DaemonSet doesn't mount the NRI socket
  that would let it learn the IP before the pod starts). The metadata service is closed by the
  routing rule above regardless; keep that window in mind for other destinations.
