#!/usr/bin/env bash
# import-image.sh — import a Talos image from the Image Factory into OCI as a
# custom image, ready for VM.Standard.A1.Flex. Prints the image OCID on stdout
# (everything else goes to stderr).
#
#   scripts/import-image.sh [--version v1.14.7] [--extensions "siderolabs/iscsi-tools ..."]
#                           [--compartment OCID] [--bucket NAME] [--keep-object]
#
# The version and extensions default to TALOS_VERSION and TALOS_EXTENSIONS from
# the environment, else to the module's vars.tf defaults. A root module that
# sets talos_version or talos_extensions exports the same values, so deploy.sh
# and replace-node.sh import the image its machine config expects.
#
# Steps:
#   1. Registers the schematic (the extensions) with the Image Factory: the ID is
#      a content hash, the same one the talos provider computes in talos.tf.
#   2. Downloads oracle-arm64.qcow2 for that schematic and version, and rewrites
#      it with an 8 KiB cluster size (siderolabs/talos#12557: OCI drops recent
#      Talos qcow2 images into the UEFI shell otherwise).
#   3. Uploads it to a temporary Object Storage bucket and imports it through the
#      REST API with launchMode CUSTOM and UEFI_64 firmware (the CLI can't set
#      launch options at import time), then removes BIOS from the image's
#      firmware capability and adds A1.Flex shape compatibility.
#   4. Deletes the uploaded object (the bucket stays, empty, for the next import).
#
# The image is meant to be transient: scripts/deploy.sh deletes it once the
# instances run. Custom images are billed as Object Storage while they exist.
#
# Requires: oci CLI (configured), curl, python3, qemu-img.
set -euo pipefail

VERSION="${TALOS_VERSION:-}"
EXTENSIONS="${TALOS_EXTENSIONS:-}"
COMPARTMENT_ID="${COMPARTMENT_OCID:-}"
BUCKET_NAME="talos-image-import"
KEEP_OBJECT=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[import-image] $*" >&2; }
die() { echo "[import-image] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --extensions) EXTENSIONS="$2"; shift 2 ;;
    --compartment) COMPARTMENT_ID="$2"; shift 2 ;;
    --bucket) BUCKET_NAME="$2"; shift 2 ;;
    --keep-object) KEEP_OBJECT=true; shift ;;
    -h | --help) sed -n '2,29p' "$0" >&2; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for tool in oci curl python3 qemu-img; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# Fallbacks from the module's vars.tf, so the image matches the default config.
VARS="$SCRIPT_DIR/../vars.tf"
if [[ -z "$VERSION" ]]; then
  VERSION=$(awk '/variable "talos_version"/,/^}/' "$VARS" | sed -n 's/.*default *= *"\(v[0-9.]*\)".*/\1/p')
fi
if [[ -z "$EXTENSIONS" ]]; then
  EXTENSIONS=$(awk '/variable "talos_extensions"/,/^}/' "$VARS" | sed -n 's/.*default *= *\[\(.*\)\].*/\1/p' | tr -d '",')
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad Talos version: '$VERSION'"

# ── schematic ─────────────────────────────────────────────────────────────────
SCHEMATIC_JSON=$(python3 -c '
import json, sys
exts = sys.argv[1].split()
print(json.dumps({"customization": {"systemExtensions": {"officialExtensions": exts}}}))
' "$EXTENSIONS")
SCHEMATIC_ID=$(curl -fsS -X POST --data-binary "$SCHEMATIC_JSON" -H 'Content-Type: application/json' \
  https://factory.talos.dev/schematics | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
log "Talos $VERSION, schematic $SCHEMATIC_ID ($EXTENSIONS)"
IMAGE_NAME="talos-${VERSION}-${SCHEMATIC_ID:0:12}-arm64"

# ── OCI context ───────────────────────────────────────────────────────────────
TENANCY_ID=$(oci iam availability-domain list --query 'data[0]."compartment-id"' --raw-output)
[[ -n "$TENANCY_ID" ]] || die "could not resolve the tenancy (oci setup config?)"
COMPARTMENT_ID="${COMPARTMENT_ID:-$TENANCY_ID}"
REGION="${OCI_REGION:-$(sed -n 's/^region *= *//p' ~/.oci/config | head -n 1)}"
[[ -n "$REGION" ]] || die "could not determine the region (set OCI_REGION)"
IAAS="https://iaas.${REGION}.oraclecloud.com/20160918"
NS=$(oci os ns get --query data --raw-output)

EXISTING=$(oci compute image list --compartment-id "$COMPARTMENT_ID" --display-name "$IMAGE_NAME" \
  --lifecycle-state AVAILABLE --query 'data[0].id' --raw-output 2>/dev/null || true)
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  log "image already imported: $EXISTING"
  echo "$EXISTING"
  exit 0
fi

# ── download and convert ──────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${VERSION}/oracle-arm64.qcow2"
log "downloading $URL"
curl -fL --progress-bar -o "$TMP/factory.qcow2" "$URL"
qemu-img convert -f qcow2 -O qcow2 -o cluster_size=8192 "$TMP/factory.qcow2" "$TMP/talos.qcow2"
rm -f "$TMP/factory.qcow2"
OBJECT="${IMAGE_NAME}.qcow2"

# ── upload ────────────────────────────────────────────────────────────────────
if ! oci os bucket get --namespace "$NS" --bucket-name "$BUCKET_NAME" >/dev/null 2>&1; then
  oci os bucket create --compartment-id "$COMPARTMENT_ID" --namespace "$NS" --name "$BUCKET_NAME" \
    --public-access-type NoPublicAccess >/dev/null
  log "bucket $BUCKET_NAME created"
fi
log "uploading $(du -h "$TMP/talos.qcow2" | cut -f1) to $BUCKET_NAME/$OBJECT"
oci os object put --namespace "$NS" --bucket-name "$BUCKET_NAME" --name "$OBJECT" \
  --file "$TMP/talos.qcow2" --force >/dev/null

# ── import (UEFI_64 needs launchMode CUSTOM, REST API only) ───────────────────
BODY=$(python3 -c '
import json, sys
c, name, b, ns, obj, ver = sys.argv[1:7]
print(json.dumps({
  "compartmentId": c, "displayName": name,
  "imageSourceDetails": {"sourceType": "objectStorageTuple", "bucketName": b, "namespaceName": ns,
                         "objectName": obj, "sourceImageType": "QCOW2",
                         "operatingSystem": "Talos", "operatingSystemVersion": ver},
  "launchMode": "CUSTOM",
  "launchOptions": {"firmware": "UEFI_64", "bootVolumeType": "PARAVIRTUALIZED",
                    "networkType": "PARAVIRTUALIZED", "remoteDataVolumeType": "PARAVIRTUALIZED"},
}))' "$COMPARTMENT_ID" "$IMAGE_NAME" "$BUCKET_NAME" "$NS" "$OBJECT" "$VERSION")
IMAGE_ID=$(oci raw-request --http-method POST --target-uri "$IAAS/images" --request-body "$BODY" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])') \
  || die "import request failed"
log "import started: $IMAGE_ID"

for _ in $(seq 1 60); do
  STATE=$(oci compute image get --image-id "$IMAGE_ID" --query 'data."lifecycle-state"' --raw-output)
  [[ "$STATE" == "AVAILABLE" ]] && break
  [[ "$STATE" == "IMPORTING" || "$STATE" == "PROVISIONING" ]] || die "import ended in state $STATE"
  sleep 30
done
[[ "$STATE" == "AVAILABLE" ]] || die "import still not finished after 30 minutes"
log "image available"

# ── capabilities: UEFI_64 only, and A1.Flex ───────────────────────────────────
SCHEMA_VERSION=$(oci compute global-image-capability-schema list --query 'data[0]."current-version-name"' --raw-output)
GLOBAL_ID=$(oci compute global-image-capability-schema list --query 'data[0].id' --raw-output)
oci compute image-capability-schema create --compartment-id "$COMPARTMENT_ID" --image-id "$IMAGE_ID" \
  --global-image-capability-schema-version-name "$SCHEMA_VERSION" \
  --schema-data '{"Compute.Firmware": {"descriptorType": "enumstring", "source": "IMAGE", "values": ["UEFI_64"], "defaultValue": "UEFI_64"}}' \
  >/dev/null 2>&1 || log "WARNING: could not restrict the firmware capability to UEFI_64 (schema ${GLOBAL_ID:-?})"
oci compute image-shape-compatibility-entry add --image-id "$IMAGE_ID" --shape-name VM.Standard.A1.Flex >/dev/null
log "capabilities set (UEFI_64 only, VM.Standard.A1.Flex)"

if [[ "$KEEP_OBJECT" == false ]]; then
  oci os object delete --namespace "$NS" --bucket-name "$BUCKET_NAME" --name "$OBJECT" --force >/dev/null
  log "uploaded object deleted"
fi

echo "$IMAGE_ID"
