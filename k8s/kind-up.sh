#!/usr/bin/env bash
# One-command local Kubernetes for the workshop (no EKS needed): kind cluster + the Datadog Agent
# (Helm, k8s/datadog-agent.sh) + the TukTukPay stack, each service started under its Datadog tracer.
#
# Requirements: docker, kind, kubectl, helm. Reads DD_API_KEY / DD_SITE from ../.env.
#   k8s/kind-up.sh                      # cluster "tuktukpay", namespace tuktukpay, environment tuktukpay-k8s
#   NAMESPACE=tuktukpay-team01 DEPLOYMENT_ENVIRONMENT=tuktukpay-team01 k8s/kind-up.sh   # per-team namespace on the same cluster
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
CLUSTER=${CLUSTER:-tuktukpay}
: "${NAMESPACE:=tuktukpay}"
: "${DEPLOYMENT_ENVIRONMENT:=tuktukpay-k8s}"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a
: "${DD_API_KEY:?set DD_API_KEY in .env (Datadog > Organization Settings > API Keys)}"

SERVICES="chaos-controller checkout-api risk-engine payment-router acquirer-sim ledger webhook-dispatcher merchant-copilot wallet-sim loadgen"

# After a reboot Docker Desktop is not running and every docker/kind/kubectl call below fails in
# its own confusing way; say it once. The kind node container restarts by itself once Docker is up.
docker info >/dev/null 2>&1 || { echo "Docker is not running: start Docker Desktop (open -a Docker), wait for the whale, then run this again." >&2; exit 1; }

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "== creating kind cluster $CLUSTER (UI/API ports published on localhost, see kind-config.yaml)"
  kind create cluster --name "$CLUSTER" --config "$DIR/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
NODE="$CLUSTER-control-plane"

# Crash-loop back-off capped at 30s (kind-config.yaml sets it on new clusters; this patches a cluster
# created before that), so a pod comes back within ~30s once an act's flag is off, not up to 5m later.
docker exec "$NODE" sh -c 'f=/var/lib/kubelet/config.yaml; grep -q maxContainerRestartPeriod $f && exit 0
  sed -i "/^crashLoopBackOff:/d" $f && printf "crashLoopBackOff:\n  maxContainerRestartPeriod: 30s\n" >> $f &&
  systemctl restart kubelet && echo "== kubelet: crash-loop back-off capped at 30s"'
kubectl wait --for=condition=Ready "node/$NODE" --timeout=120s >/dev/null

echo "== building images with docker compose"
( cd "$ROOT" && docker compose build $SERVICES )
echo "== loading images into kind"
# Remember which images actually changed on the node: the manifests use a fixed `latest` tag with
# imagePullPolicy IfNotPresent, so a rebuilt image never restarts a running pod by itself.
CHANGED=""
for s in $SERVICES; do
  img="tuktukpay-workshop/tuktukpay-$s:latest"
  before=$(docker exec "$NODE" crictl images -q "docker.io/$img" 2>/dev/null || true)
  docker tag "tuktukpay-workshop-$s:latest" "$img"
  kind load docker-image "$img" --name "$CLUSTER"
  after=$(docker exec "$NODE" crictl images -q "docker.io/$img" 2>/dev/null || true)
  if [ -n "$before" ] && [ "$before" != "$after" ]; then CHANGED="$CHANGED $s"; fi
done

DEPLOYMENT_ENVIRONMENT="$DEPLOYMENT_ENVIRONMENT" "$DIR/datadog-agent.sh" "kind-$CLUSTER" "kind-$CLUSTER" kind

echo "== deploying TukTukPay ($NAMESPACE / $DEPLOYMENT_ENVIRONMENT)"
IMAGE_REGISTRY=tuktukpay-workshop NAMESPACE="$NAMESPACE" DEPLOYMENT_ENVIRONMENT="$DEPLOYMENT_ENVIRONMENT" "$DIR/apply.sh"
if [ -n "$CHANGED" ]; then
  # Code changed: restart exactly the deployments whose image changed, so "edit, run kind-up.sh"
  # works for code the same way apply.sh makes it work for .env (chaos flags reset with the controller).
  echo "== restarting deployments whose image changed:$CHANGED"
  for s in $CHANGED; do
    # image -> deployment(s): loadgen runs as merchant-storefront; the wallet-sim image also runs the agent console
    case $s in loadgen) deps=merchant-storefront ;; wallet-sim) deps="wallet-sim shopping-agent" ;; *) deps=$s ;; esac
    for d in $deps; do kubectl -n "$NAMESPACE" rollout restart "deployment/$d" >/dev/null 2>&1 || true; done
  done
fi
kubectl -n "$NAMESPACE" rollout status deployment --timeout=300s 2>/dev/null || kubectl -n "$NAMESPACE" get pods
echo
echo "UIs + API:    http://localhost:8090 (war room), :8087 (agent console), :8080 (payments), :8086 (copilot) — direct via NodePorts"
echo "              (other clusters without the kind port mappings: k8s/port-forward.sh $NAMESPACE)"
echo "smoke test:   scripts/smoke-test.sh"
echo "K8s acts:     act6 / act7 from the panel; k8s/acts/oversize-rollout.sh, k8s/acts/bad-image.sh, k8s/acts/rollback.sh"
echo "tear down:    kind delete cluster --name $CLUSTER"
echo "Datadog:      APM > Services, env:$DEPLOYMENT_ENVIRONMENT (first traces within a minute or two)"
echo "stay awake:   make awake — a sleeping laptop (closed lid, idle timer) freezes the whole cluster"
