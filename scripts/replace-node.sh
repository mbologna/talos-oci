#!/usr/bin/env bash
# replace-node.sh — replace one node: remove its etcd member, recreate the
# instance from a freshly imported image (same name, same fixed IP), wait until
# it has rejoined, delete the image. Longhorn rebuilds the node's replicas.
#
#   scripts/replace-node.sh server-1
#
# Env: TF_DIR (default ../example), MODULE (address of the module in TF_DIR,
# default module.talos_oci), TALOSCONFIG (default ~/.talos/<cluster>/talosconfig),
# TALOS_VERSION / TALOS_EXTENSIONS as for deploy.sh.
# The Bastion tunnel must be up (scripts/tunnel.sh up).
set -euo pipefail

NODE="${1:?usage: replace-node.sh <node name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
MODULE="${MODULE:-module.talos_oci}"
export GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[replace-node] $*" >&2; }
die() { echo "[replace-node] ERROR: $*" >&2; exit 1; }
tf() { tofu -chdir="$TF_DIR" "$@"; }

export TALOSCONFIG="${TALOSCONFIG:-$HOME/.talos/$(tf output -raw cluster_name)/talosconfig}"
IPS=$(tf output -json node_private_ips)
IP=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$IPS" "$NODE") \
  || die "no node named $NODE"
OTHER=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print([v for k,v in sorted(d.items()) if k!=sys.argv[2]][0])' "$IPS" "$NODE")

# A replaced control plane must not come back as a stale etcd member.
MEMBER=$(talosctl --nodes "$OTHER" etcd members 2>/dev/null | awk -v h="$NODE" '$3 == h {print $2}')
if [[ -n "$MEMBER" ]]; then
  talosctl --nodes "$OTHER" etcd remove-member "$MEMBER"
  log "etcd member $MEMBER ($NODE) removed"
fi

IMAGE_ID=$("$SCRIPT_DIR/import-image.sh")
tf apply -input=false -auto-approve -var "image_id=$IMAGE_ID" \
  -replace="${MODULE}.oci_core_instance.node[\"${NODE}\"]"

INSTANCE=$(tf output -json node_instance_ids | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$NODE")
oci compute instance get --instance-id "$INSTANCE" --wait-for-state RUNNING --max-wait-seconds 1200 >/dev/null
oci compute image delete --image-id "$IMAGE_ID" --force >/dev/null
log "image deleted; waiting for $NODE ($IP) to rejoin"

for _ in $(seq 1 90); do
  talosctl --nodes "$OTHER" etcd members 2>/dev/null | awk '{print $3}' | grep -qx "$NODE" && break
  sleep 10
done
talosctl --nodes "$IP" health --wait-timeout 20m
log "$NODE replaced"
