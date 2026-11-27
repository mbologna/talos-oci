#!/usr/bin/env bash
# Render patches/*.yaml.tftpl with test values, generate a control-plane config
# with talosctl (throwaway secrets, deleted on exit) and validate it for the
# cloud mode. Also checks the rendered config against OCI's 32,000-byte
# user_data limit. Used by CI and before every change to patches/.
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:-$(sed -n 's/.*default *= *"\(v[0-9.]*\)".*/\1/p' "$(dirname "$0")/../vars.tf" | head -n 1)}"
K8S_VERSION="${K8S_VERSION:-$(awk '/variable "kubernetes_version"/,/^}/' "$(dirname "$0")/../vars.tf" | sed -n 's/.*default *= *"v\{0,1\}\([0-9.]*\)".*/\1/p')}"
PATCHES="$(cd "$(dirname "$0")/../patches" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
values = {
    "lb_ip": "10.0.1.5", "private_cidr": "10.0.1.0/24", "hostname": "server-0",
    "installer_image": "factory.talos.dev/oracle-installer/0000000000000000000000000000000000000000000000000000000000000000:v1.14.7",
    "ephemeral_max_size": "24GiB",
}
lists = {"talos_api_roles": ["os:etcd:backup", "os:admin"],
         "talos_api_namespaces": ["talos-backup", "system-upgrade"]}
text = open(src).read()
for name, items in lists.items():
    text = re.sub(r"%\{ for \w+ in " + name + r" ~\}\n(\s*- )\$\{\w+\}\n%\{ endfor ~\}\n",
                  lambda m: "".join(f"{m.group(1)}{i}\n" for i in items), text)
for key, val in values.items():
    text = text.replace("${" + key + "}", val)
leftover = re.findall(r"\$\{[^}]+\}|%\{", text)
if leftover:
    sys.exit(f"{src}: unrendered template syntax: {leftover}")
open(dst, "w").write(text)
PY
}

render "$PATCHES/common.yaml.tftpl" "$TMP/common.yaml"
render "$PATCHES/node.yaml.tftpl" "$TMP/node.yaml"
talosctl gen config hotel https://10.0.1.5:6443 \
  --talos-version "${TALOS_VERSION%.*}" --kubernetes-version "$K8S_VERSION" \
  --output-types controlplane --with-docs=false --with-examples=false \
  --config-patch "@$TMP/common.yaml" --config-patch "@$TMP/node.yaml" \
  -o "$TMP/controlplane.yaml" >/dev/null
talosctl validate --config "$TMP/controlplane.yaml" --mode cloud
size=$(wc -c < "$TMP/controlplane.yaml" | tr -d ' ')
echo "controlplane config: $size bytes (OCI user_data limit 32000, base64 adds a third)"
[ $(( size * 4 / 3 )) -lt 32000 ] || { echo "too large for OCI user_data" >&2; exit 1; }
