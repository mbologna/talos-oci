#!/usr/bin/env bash
# apply-config.sh — apply the rendered machine configuration (output
# machine_configurations) to running nodes, one at a time. Nodes read user_data
# only at first boot, so a change to patches/ or to the Talos inputs reaches
# existing nodes through this script.
#
#   scripts/apply-config.sh                 # every node
#   scripts/apply-config.sh server-1        # one node
#   DRY_RUN=true scripts/apply-config.sh    # show what would change
#
# It refuses a node whose running Kubernetes or installer image differs from
# the rendered one (an upgrade done with tuppr or talosctl since): applying
# would downgrade it. Bump talos_version / kubernetes_version first.
#
# Env: TF_DIR (default ../example; its root module must expose
# machine_configurations and node_private_ips), TALOSCONFIG (default
# ~/.talos/<cluster>/talosconfig), MODE (talosctl apply mode, default
# no-reboot: a change that needs a reboot fails instead of rebooting), DRY_RUN.
# The Bastion tunnel must be up (scripts/tunnel.sh up).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
MODE="${MODE:-no-reboot}"
export GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[apply-config] $*" >&2; }
die() { echo "[apply-config] ERROR: $*" >&2; exit 1; }
tf() { tofu -chdir="$TF_DIR" "$@"; }

export TALOSCONFIG="${TALOSCONFIG:-$HOME/.talos/$(tf output -raw cluster_name)/talosconfig}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

tf output -json machine_configurations > "$TMP/configs.json"
tf output -json node_private_ips > "$TMP/ips.json"
mapfile -t NODES < <(python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$TMP/ips.json")
[[ $# -gt 0 ]] && NODES=("$@")

# The images a config pins: the API server (Kubernetes version) and the
# installer (Talos version). Printed one per line, nothing else.
images() {
  grep -oE 'kube-apiserver:v[0-9][^"[:space:]]*|[a-z-]*installer[^"[:space:]]*:v[0-9][^"[:space:]]*' "$1" | sort -u
}

for node in "${NODES[@]}"; do
  ip=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$TMP/ips.json" "$node") \
    || die "no node named $node"
  python3 -c 'import json,sys; open(sys.argv[3],"w").write(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$TMP/configs.json" "$node" "$TMP/$node.yaml"
  talosctl --nodes "$ip" get machineconfig v1alpha1 -o jsonpath='{.spec}' > "$TMP/$node.running.yaml"

  if [[ "$(images "$TMP/$node.yaml")" != "$(images "$TMP/$node.running.yaml")" ]]; then
    log "$node: running images differ from the rendered config:"
    diff <(images "$TMP/$node.running.yaml") <(images "$TMP/$node.yaml") >&2 || true
    die "bump talos_version / kubernetes_version to what the node runs, then retry"
  fi

  if [[ "${DRY_RUN:-false}" == true ]]; then
    log "$node ($ip): dry run"
    talosctl --nodes "$ip" apply-config --file "$TMP/$node.yaml" --mode "$MODE" --dry-run
    continue
  fi

  log "$node ($ip): applying (mode $MODE)"
  talosctl --nodes "$ip" apply-config --file "$TMP/$node.yaml" --mode "$MODE"
  talosctl --nodes "$ip" health --wait-timeout 10m >/dev/null
  log "$node healthy"
done
