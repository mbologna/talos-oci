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
  Restrict instance read access in IAM, and keep pods away from the metadata service with
  NetworkPolicies (the flannel CNI enforces them: `kubeNetworkPoliciesEnabled`). DNS to
  `169.254.169.254:53` is the VCN resolver and must stay open.
- **Terraform state holds every cluster secret** (`talos_machine_secrets`). Keep it in an
  encrypted, access-controlled backend; never commit it.
- **NetworkPolicy enforcement fails open**: if the kube-network-policies container of the
  flannel DaemonSet stops, traffic is allowed until it restarts.
- **Instance principal (opt-in, `instance_principal_backup_read`)**: the nodes may list the
  backups bucket. Any process that reaches the metadata service can use that identity, so keep
  pods away from `169.254.169.254:80` except the backup check that needs it.
