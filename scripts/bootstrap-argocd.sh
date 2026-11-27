#!/usr/bin/env bash
# bootstrap-argocd.sh — install Argo CD and the App of Apps on a fresh cluster.
# From then on Argo CD manages everything, Argo CD itself included (an
# Application for the argo-cd chart with releaseName: argocd adopts this
# release). Talos doesn't manage it, so a Kubernetes upgrade never reverts it.
#
#   GITOPS_REPO_URL=https://codeberg.org/you/infra.git GITOPS_PATH=clusters/hotel \
#   GITOPS_HTTPS_USERNAME=you GITOPS_HTTPS_TOKEN=... scripts/bootstrap-argocd.sh
#
# Env:
#   KUBECONFIG              kubeconfig for the cluster (scripts/deploy.sh writes one)
#   GITOPS_REPO_URL         repository of the App of Apps (required)
#   GITOPS_PATH             path of the App of Apps in that repository (required)
#   GITOPS_REVISION         default HEAD
#   GITOPS_HTTPS_USERNAME   with GITOPS_HTTPS_TOKEN: a repository Secret for a
#   GITOPS_HTTPS_TOKEN      private repository (read from the environment only)
#   ARGOCD_CHART_VERSION    argo-cd chart version; keep it equal to the version
#                           your Argo CD Application pins (default below)
# Requires: helm, kubectl.
set -euo pipefail

# renovate: datasource=helm registryUrl=https://argoproj.github.io/argo-helm depName=argo-cd
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.18.0}"
: "${GITOPS_REPO_URL:?GITOPS_REPO_URL is required}"
: "${GITOPS_PATH:?GITOPS_PATH is required}"
GITOPS_REVISION="${GITOPS_REVISION:-HEAD}"

log() { echo "[bootstrap-argocd] $*" >&2; }

kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd >/dev/null

if [[ -n "${GITOPS_HTTPS_TOKEN:-}" ]]; then
  : "${GITOPS_HTTPS_USERNAME:?GITOPS_HTTPS_USERNAME is required with GITOPS_HTTPS_TOKEN}"
  # The token goes to kubectl on stdin, never on a command line.
  python3 -c '
import json, os
print(json.dumps({
  "apiVersion": "v1", "kind": "Secret",
  "metadata": {"name": "argocd-repo-gitops", "namespace": "argocd",
               "labels": {"argocd.argoproj.io/secret-type": "repository"}},
  "type": "Opaque",
  "stringData": {"type": "git", "url": os.environ["GITOPS_REPO_URL"],
                 "username": os.environ["GITOPS_HTTPS_USERNAME"],
                 "password": os.environ["GITOPS_HTTPS_TOKEN"]},
}))' | kubectl apply -f - >/dev/null
  log "repository Secret argocd-repo-gitops applied"
fi

# The two values infra's Argo CD Application also sets, so the first sync
# changes nothing structural: plain HTTP behind the ingress controller, and
# Helm inside kustomizations.
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd \
  --set 'configs.params.server\.insecure=true' \
  --set 'configs.cm.kustomize\.buildOptions=--enable-helm' \
  --wait --timeout 10m >/dev/null
log "Argo CD $ARGOCD_CHART_VERSION installed"

kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: ${GITOPS_REVISION}
    path: ${GITOPS_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
log "App of Apps applied: ${GITOPS_REPO_URL} ${GITOPS_PATH}@${GITOPS_REVISION}"
