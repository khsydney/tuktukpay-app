# TukTukPay on Kubernetes — Datadog edition

This branch (`tuktukpay-app-with-DD`) runs the platform on Kubernetes with the **Datadog Agent** Helm chart (one Agent pod
per node plus the Cluster Agent). Every service image starts its own Datadog tracer — `ddtrace-run` (Python), `dd-trace`
(Node.js, preloaded with `-r ./dd-init.js`), `dd-java-agent` (Java, via `JAVA_TOOL_OPTIONS`) and `dd-trace-go` (Go, in
code) — so nothing is injected by an operator or admission controller. Datadog setup and Bits AI SRE testing:
[`docs/datadog.md`](../docs/datadog.md).

**Why Kubernetes:** Bits AI SRE investigates Kubernetes monitors as well as APM and log monitors, and reads pod state,
restarts, events and deployments (Change Tracking). Acts 6 and 7 and the rollout scripts exist only here: ledger memory leak →
OOMKilled, wallet-sim bad release → CrashLoopBackOff, an unschedulable rollout and a bad image tag. Docker Compose stays the
quick option for laptops — it has no Kubernetes signals.

## 0. Fastest path: a local `kind` cluster (no EKS needed)

```bash
# requirements: docker, kind, kubectl, helm; DD_API_KEY and DD_SITE in .env
k8s/kind-up.sh                                                        # cluster "tuktukpay", namespace tuktukpay, env tuktukpay-k8s
NAMESPACE=tuktukpay-team01 DEPLOYMENT_ENVIRONMENT=tuktukpay-team01 k8s/kind-up.sh   # add a team namespace on the same cluster
open http://localhost:8090                                            # war room; :8087 agent console, :8080 payments API, :8086 copilot ...
scripts/smoke-test.sh                                                 # (ports are published by kind — no port-forward needed)
```
The script builds the images with Compose, loads them into kind, installs the Datadog Agent with `k8s/datadog-agent.sh`
(values in `k8s/values-datadog.yaml`; on kind the kubelet's self-signed certificate is accepted with `datadog.kubelet.tlsVerify=false`),
applies the manifests and prints the next steps. A `t3.xlarge` handles one cluster with two team namespaces at spike ×10; a laptop
with 8 GB for Docker runs one namespace at ×3.

## 0b. One command on EKS (Amazon Elastic Kubernetes Service)

```bash
# requirements: as above + eksctl, aws CLI; set EKS_AWS_ACCOUNT (and EKS_AWS_PROFILE, EKS_AWS_REGION if needed) in .env
make eks-up      # k8s/eks-up.sh: cluster tuktukpay-eks (k8s/eks-cluster.yaml), ECR images, Datadog Agent, deploy
make eks-down    # k8s/eks-down.sh: load balancers, cluster + VPC + NAT gateway, ECR repositories, leftovers check
```
Two arm64 `m7g.xlarge` nodes (the Mac builds arm64 images), private subnets behind one NAT gateway. The war-room panel and agent
console get their own load balancers (`chaos-controller-lb`, `shopping-agent-lb`) that only accept the public IP of the machine that
ran the script; re-run it on a new network. The nodes get the same 30 s crash-loop back-off cap as kind. kubectl:
`--context tuktukpay-eks`. About USD 0.60/hour, plus Datadog's own pricing for the hosts, APM, logs and Bits investigations.

## 1. Any other cluster: build and push images

```bash
export IMAGE_REGISTRY=123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/tuktukpay   # or ghcr.io/<org>
docker compose build
for s in chaos-controller checkout-api risk-engine payment-router acquirer-sim ledger webhook-dispatcher merchant-copilot wallet-sim loadgen; do
  docker tag tuktukpay-workshop-$s:latest $IMAGE_REGISTRY/tuktukpay-$s:latest   # compose names images <project>-<service>
  docker push $IMAGE_REGISTRY/tuktukpay-$s:latest
done
```

## 2. Install the Datadog Agent

```bash
k8s/datadog-agent.sh "$(kubectl config current-context)" <cluster-name> eks    # or: make datadog-agent CLUSTER_NAME=<name> FLAVOUR=eks
kubectl -n datadog get pods                                                    # datadog-agent-xxxxx (one per node) + cluster agent
make k8s-agent-status                                                          # APM, Logs Agent, OTLP and Forwarder sections
```

What the values turn on, and why: APM on hostPort 8126 (the tracers send to `DD_AGENT_HOST` = the node IP), DogStatsD on 8125
(runtime metrics), OTLP/HTTP on hostPort 4318 (the OpenTelemetry metrics), container log collection, Kubernetes state metrics,
the orchestrator explorer and live processes. Single Step Instrumentation and the admission controller are **off**: every image
already loads its tracer, and a second injected tracer would duplicate spans.

## 3. Deploy TukTukPay

```bash
IMAGE_REGISTRY=$IMAGE_REGISTRY NAMESPACE=tuktukpay DEPLOYMENT_ENVIRONMENT=tuktukpay-eks k8s/apply.sh
kubectl -n tuktukpay get pods -w
kubectl -n tuktukpay port-forward svc/chaos-controller 8090:8090   # facilitator panel
kubectl -n tuktukpay port-forward svc/checkout-api 8080:8080       # scripts/smoke-test.sh works against this
```

What to show:

* `kubectl -n tuktukpay get pod -l app=payment-router -o yaml | grep -A1 JAVA_TOOL_OPTIONS` → `-javaagent:/dd/dd-java-agent.jar`.
* The pod labels `tags.datadoghq.com/env|service|version` (unified service tagging): the Agent puts the same `env`, `service` and
  `version` on the pod's logs, container metrics and Kubernetes state as the tracer puts on its spans.
* **APM → Services** (`env:<env>`), **Infrastructure → Kubernetes**, **Logs** (`kube_namespace:tuktukpay`).

## The Kubernetes acts

| Act | Start | What Kubernetes sees | Datadog monitor (`datadog/terraform`) | Evidence logs | Fix |
|---|---|---|---|---|---|
| **6 — The leaky ledger** | panel `act6` (flag `ledger_memory_leak`) | `ledger` RSS climbs 6 MiB/s to its 384Mi limit → **OOMKilled** → restart, repeat | *container OOMKilled* (by service) | ledger `@event:memory.pressure` (`memory.leaked_mb`, `container.memory.limit_mb`), checkout-api `@event:ledger.write_failed` | flag off (≈ raise the limit / roll back the release) |
| **7 — The bad rollout** | panel `act7` (flags `wallet_crash_loop` + `agent_traffic_surge`) | `wallet-sim` exits 3 a few seconds after start → **CrashLoopBackOff**; AMP agent payments fail closed | *container in CrashLoopBackOff* (by service) | wallet-sim `@event:service.crashed` (`deployment.release`), checkout-api `@mandate.block_reason:mandate_kya_unavailable` | flag off (≈ `kubectl rollout undo`) |
| Oversize rollout | `k8s/acts/oversize-rollout.sh` | new `risk-engine` pod **Pending** (Insufficient memory), deployment stays below spec; old pod keeps serving | — (add a "deployment below desired replicas" monitor if you want one) | Kubernetes events (`FailedScheduling`) | `k8s/acts/rollback.sh risk-engine` |
| Bad image | `k8s/acts/bad-image.sh` | new `merchant-copilot` pod **ImagePullBackOff** | — | Kubernetes events (`ErrImagePull`) | `k8s/acts/rollback.sh merchant-copilot` |
| 2 on Kubernetes | panel `act2` | `risk-engine` pins its 500m CPU limit under model v3 | *risk-engine p90 latency* + log *risk.inference_slow* | `@event:config.changed`, `@event:risk.inference_slow` | flag off; the real fix is the model |

After **flag off** in Acts 6/7 the pod comes back by itself; no restart command is needed. On kind that takes at most ~30 s:
`kind-config.yaml` caps the kubelet's crash-loop back-off at 30 s, and `kind-up.sh` applies the same cap to a cluster created
before that setting existed. On other clusters the back-off belongs to the node, so expect up to 5 min, or skip the wait with
`kubectl -n <ns> rollout restart deploy/ledger` (or `deploy/wallet-sim`).

## Reaching the UIs

`kind-config.yaml` maps the node ports 30090/30087/30080/30086/30088/30085 to the same-numbered `localhost` ports
(8090 war room, 8087 agent console, 8080 payments API, 8086 copilot, 8088 wallet, 8085 merchant-sim); the six Services
are `type: NodePort` with those fixed ports. No `kubectl port-forward` is involved, so pod restarts during Acts 6/7
cannot break the panel. On clusters created without the mappings (EKS …) use `k8s/port-forward.sh`, which restarts
its tunnels automatically, or expose the Services the way the cluster prefers (Ingress, LoadBalancer).

## Configuration comes from `.env`

`k8s/apply.sh` (called by `kind-up.sh`) turns `.env` into three objects every application container reads through `envFrom`:
ConfigMap `tuktukpay-config` (`BASE_RPS`, `COPILOT_*`, `AGENT_*`, `LOG_LEVEL`, `AWS_REGION`), Secret `tuktukpay-secrets`
(`AMP_SHARED_SECRET`, LLM provider keys) and ConfigMap `tuktukpay-datadog` (`DD_ENV`, `DD_VERSION`, `DD_TRACE_OTEL_ENABLED`,
`DD_METRICS_OTEL_ENABLED`, `DD_LOGS_INJECTION`, `DD_RUNTIME_METRICS_ENABLED`, `DD_PROFILING_ENABLED`, propagation style and the
`/healthz` sampling rule). When any of them changed, the application pods are rolled (Postgres and Redis are not). The Datadog API
key goes only to the Agent's Secret `datadog/datadog-secret`, never to the application pods.

The same command picks up **code changes**: the images are rebuilt and loaded, and the deployments whose image actually changed
on the node are restarted (the manifests use a fixed `latest` tag with `IfNotPresent`). A restart of `chaos-controller` resets the
flags and the traffic switch; start the act again afterwards.

## Notes

* In `tuktukpay.yaml` the `DD_AGENT_HOST` (node IP) variable must stay **first** in every container's `env` list: Kubernetes only
  expands `$(VAR)` references to variables defined earlier in the list, so an `OTEL_EXPORTER_OTLP_ENDPOINT` placed before it would
  be the literal string `http://$(DD_AGENT_HOST):4318` and the OpenTelemetry metrics would not arrive.
* Change `SERVICE_VERSION` in `.env` when you deploy new code: it becomes `DD_VERSION` and the `tags.datadoghq.com/version`
  label, which is how Datadog Change Tracking (and so Bits AI SRE) sees a release.
* A laptop that sleeps (lid closed, idle timer) freezes the Docker Desktop VM and with it the whole cluster: every signal stops in the
  same minute and resumes on wake. `make awake` (`caffeinate -dimsu`) stops idle sleep; keep the lid open during the session.
* Postgres and Redis are dev-grade Deployments here; use RDS/ElastiCache for anything longer than a workshop.
* The .NET ledger variant (`services/ledger-dotnet` on `main`) is not part of this branch.
