#!/usr/bin/env bash
# deploy.sh — build a cluster end to end:
#   1. import the Talos image (scripts/import-image.sh) and record its OCID in
#      $TF_DIR/talos-image.auto.tfvars (later plans need a value; the instances
#      ignore it once they exist);
#   2. tofu apply;
#   3. delete the custom image once every node is RUNNING (instances keep their
#      boot volumes; upgrades pull the installer from the Image Factory);
#   4. open the Bastion port forwards (scripts/tunnel.sh up);
#   5. bootstrap etcd on the first node, wait for the cluster to be healthy and
#      write a kubeconfig pointing at the tunnel;
#   6. install Argo CD and the App of Apps (scripts/bootstrap-argocd.sh) when
#      GITOPS_REPO_URL is set.
#
#   TF_DIR=example scripts/deploy.sh
#
# Env: TF_DIR (default ../example), TALOS_DIR (talosconfig and kubeconfig;
# default ~/.talos/<cluster>), KEEP_IMAGE=true to keep the image, plus what
# bootstrap-argocd.sh reads, and TALOS_VERSION / TALOS_EXTENSIONS when TF_DIR
# overrides the module's talos_version / talos_extensions (import-image.sh).
# The tofu backend and variables come from TF_DIR.
# Requires: tofu, oci CLI, talosctl, kubectl, helm, qemu-img, curl, python3, ssh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
export TF_DIR GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[deploy] $*" >&2; }
die() { echo "[deploy] ERROR: $*" >&2; exit 1; }
tf() { tofu -chdir="$TF_DIR" "$@"; }

for tool in tofu oci talosctl kubectl helm qemu-img curl python3 ssh; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# ── 1. image ──────────────────────────────────────────────────────────────────
IMAGE_ID=$("$SCRIPT_DIR/import-image.sh")
printf '# Written by scripts/deploy.sh: the Talos image the nodes were created from\n# (deleted after the deploy; the instances ignore later changes).\nimage_id = "%s"\n' \
  "$IMAGE_ID" > "$TF_DIR/talos-image.auto.tfvars"
log "image $IMAGE_ID"

# ── 2. apply ──────────────────────────────────────────────────────────────────
tf init -input=false >/dev/null
tf apply -input=false -auto-approve

CLUSTER=$(tf output -json node_instance_ids | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
log "$CLUSTER nodes created"

# ── 3. delete the image ───────────────────────────────────────────────────────
if [[ "${KEEP_IMAGE:-false}" != true ]]; then
  for id in $(tf output -json node_instance_ids | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).values()))'); do
    oci compute instance get --instance-id "$id" --wait-for-state RUNNING --max-wait-seconds 1200 >/dev/null
  done
  oci compute image delete --image-id "$IMAGE_ID" --force >/dev/null
  log "custom image deleted"
fi

# ── 4. tunnel ─────────────────────────────────────────────────────────────────
"$SCRIPT_DIR/tunnel.sh" up

# ── 5. bootstrap ──────────────────────────────────────────────────────────────
TALOS_DIR="${TALOS_DIR:-$HOME/.talos/$(tf output -raw cluster_name)}"
mkdir -p "$TALOS_DIR" && chmod 700 "$TALOS_DIR"
tf output -raw talosconfig > "$TALOS_DIR/talosconfig"
chmod 600 "$TALOS_DIR/talosconfig"
export TALOSCONFIG="$TALOS_DIR/talosconfig"
FIRST=$(tf output -json node_private_ips | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[sorted(d)[0]])')
ALL=$(tf output -json node_private_ips | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).values()))')

log "waiting for the Talos API on $FIRST"
for _ in $(seq 1 60); do
  talosctl --nodes "$FIRST" version >/dev/null 2>&1 && break
  sleep 10
done
if ! talosctl --nodes "$FIRST" etcd status >/dev/null 2>&1; then
  talosctl --nodes "$FIRST" bootstrap
  log "etcd bootstrapped on $FIRST"
fi
talosctl --nodes "$FIRST" health --control-plane-nodes "$ALL" --wait-timeout 20m

talosctl --nodes "$FIRST" kubeconfig "$TALOS_DIR/kubeconfig" --force --merge=false
# The kube-API is reached through the tunnel; 127.0.0.1 is in the certificate.
kubectl --kubeconfig "$TALOS_DIR/kubeconfig" config set-cluster "$(kubectl --kubeconfig "$TALOS_DIR/kubeconfig" config view -o jsonpath='{.clusters[0].name}')" \
  --server https://127.0.0.1:6443 >/dev/null
export KUBECONFIG="$TALOS_DIR/kubeconfig"
kubectl get nodes -o wide

# ── 6. Argo CD ────────────────────────────────────────────────────────────────
if [[ -n "${GITOPS_REPO_URL:-}" ]]; then
  "$SCRIPT_DIR/bootstrap-argocd.sh"
else
  log "GITOPS_REPO_URL not set: skipping Argo CD"
fi

log "done. talosconfig: $TALOS_DIR/talosconfig, kubeconfig: $TALOS_DIR/kubeconfig (through scripts/tunnel.sh)"
