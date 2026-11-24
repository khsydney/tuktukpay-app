#!/usr/bin/env bash
# Install or update the Datadog Agent (Helm chart datadog/datadog) on a cluster, from .env:
#   DD_API_KEY (required), DD_SITE (default datadoghq.com), DEPLOYMENT_ENVIRONMENT (the env tag).
# Called by kind-up.sh and eks-up.sh; can also be run on its own:
#   k8s/datadog-agent.sh <kube-context> <cluster-name> [kind|eks]
# The API key goes into Secret datadog/datadog-secret through a private temp file, never on a command line.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a
CONTEXT=${1:?kube-context}
CLUSTER_NAME=${2:?cluster name}
FLAVOUR=${3:-kind}
CHART_VERSION=${DD_CHART_VERSION:-3.276.0}
: "${DD_API_KEY:?set DD_API_KEY in .env (Datadog > Organization Settings > API Keys)}"
: "${DD_SITE:=datadoghq.com}"
: "${DEPLOYMENT_ENVIRONMENT:=tuktukpay-k8s}"
K=(kubectl --context "$CONTEXT")

echo "== Datadog Agent $CHART_VERSION on $CLUSTER_NAME (site $DD_SITE, env $DEPLOYMENT_ENVIRONMENT)"
"${K[@]}" create namespace datadog --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
KEYFILE=$(mktemp)   # mode 600
trap 'rm -f "$KEYFILE"' EXIT
printf '%s' "$DD_API_KEY" > "$KEYFILE"
"${K[@]}" -n datadog create secret generic datadog-secret --from-file=api-key="$KEYFILE" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null
EXTRA=()
# kind's kubelet serves a self-signed certificate.
[ "$FLAVOUR" = kind ] && EXTRA+=(--set datadog.kubelet.tlsVerify=false)
helm upgrade --install datadog-agent datadog/datadog --version "$CHART_VERSION" \
  --kube-context "$CONTEXT" --namespace datadog \
  -f "$DIR/values-datadog.yaml" \
  --set datadog.site="$DD_SITE" \
  --set datadog.clusterName="$CLUSTER_NAME" \
  --set "datadog.tags[0]=env:$DEPLOYMENT_ENVIRONMENT" \
  ${EXTRA[@]+"${EXTRA[@]}"} --wait --timeout 8m
"${K[@]}" -n datadog get pods -o wide
