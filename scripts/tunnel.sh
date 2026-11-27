#!/usr/bin/env bash
# tunnel.sh — OCI Bastion port forwards to the internal load balancer:
# localhost:6443 → Kubernetes API, localhost:50000 → Talos API. The talosconfig
# output and the kubeconfig written by scripts/deploy.sh point at 127.0.0.1.
#
#   scripts/tunnel.sh up      # create the Bastion sessions and start the forwards
#   scripts/tunnel.sh down    # stop the forwards and delete the sessions
#   scripts/tunnel.sh status
#
# Env: TF_DIR (default: ../example), SSH_KEY (default: ~/.ssh/id_ed25519; its
# .pub is sent to the Bastion), SESSION_TTL (seconds, default 10800, the max).
# Requires: oci CLI, ssh, tofu (outputs bastion_id and internal_lb_ip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SESSION_TTL="${SESSION_TTL:-10800}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/talos-oci"
export GODEBUG="${GODEBUG:-http2client=0}"
PORTS=(6443 50000)

log() { echo "[tunnel] $*" >&2; }
die() { echo "[tunnel] ERROR: $*" >&2; exit 1; }

out() { tofu -chdir="$TF_DIR" output -raw "$1"; }

region() {
  if [[ -n "${OCI_REGION:-}" ]]; then echo "$OCI_REGION"; else sed -n 's/^region *= *//p' ~/.oci/config | head -n 1; fi
}

# listening <port>: something accepts connections on 127.0.0.1:<port>.
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

up() {
  [[ -r "$SSH_KEY" && -r "$SSH_KEY.pub" ]] || die "SSH key pair $SSH_KEY(.pub) not found (set SSH_KEY)"
  local bastion lb
  bastion=$(out bastion_id) || die "no bastion_id output (enable_bastion = true?)"
  lb=$(out internal_lb_ip)
  mkdir -p "$STATE_DIR"
  for port in "${PORTS[@]}"; do
    if listening "$port"; then
      log "localhost:$port already forwarded"
      continue
    fi
    local session
    session=$(oci bastion session create-port-forwarding --bastion-id "$bastion" \
      --target-private-ip "$lb" --target-port "$port" --session-ttl "$SESSION_TTL" \
      --display-name "talos-oci-$port-$(date +%s)" --ssh-public-key-file "$SSH_KEY.pub" \
      --wait-for-state SUCCEEDED --query 'data.resources[0].identifier' --raw-output)
    [[ -n "$session" ]] || die "could not create a Bastion session for port $port"
    echo "$session" > "$STATE_DIR/$port.session"
    for _ in $(seq 1 30); do
      [[ "$(oci bastion session get --session-id "$session" --query 'data."lifecycle-state"' --raw-output)" == "ACTIVE" ]] && break
      sleep 5
    done
    # An ACTIVE session can still refuse the key for a few seconds: retry.
    # OCI Bastion offers only AES-CTR ciphers, which hardened ssh configs often
    # leave out (the + adds them to OpenSSH's defaults), and IdentitiesOnly
    # keeps an agent's other keys from using up the server's attempts.
    for _ in $(seq 1 6); do
      ssh -i "$SSH_KEY" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -o Ciphers=+aes256-ctr -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
        -L "127.0.0.1:$port:$lb:$port" -p 22 "$session@host.bastion.$(region).oci.oraclecloud.com" &
      echo $! > "$STATE_DIR/$port.pid"
      for _ in $(seq 1 10); do
        listening "$port" && break 2
        kill -0 "$(cat "$STATE_DIR/$port.pid")" 2>/dev/null || break
        sleep 2
      done
      sleep 5
    done
    listening "$port" || die "the port forward for $port did not come up"
    log "localhost:$port → $lb:$port (session ${session: -8})"
  done
}

down() {
  for port in "${PORTS[@]}"; do
    if [[ -f "$STATE_DIR/$port.pid" ]]; then
      kill "$(cat "$STATE_DIR/$port.pid")" 2>/dev/null || true
      rm -f "$STATE_DIR/$port.pid"
    fi
    if [[ -f "$STATE_DIR/$port.session" ]]; then
      oci bastion session delete --session-id "$(cat "$STATE_DIR/$port.session")" --force >/dev/null 2>&1 || true
      rm -f "$STATE_DIR/$port.session"
    fi
  done
  log "forwards stopped, sessions deleted"
}

status() {
  for port in "${PORTS[@]}"; do
    if listening "$port"; then
      echo "localhost:$port up"
    else
      echo "localhost:$port down"
    fi
  done
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
