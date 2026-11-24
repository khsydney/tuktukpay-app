# Convenience targets for the TukTukPay workshop stack
COMPOSE ?= docker compose
CHAOS   ?= http://localhost:8090

.PHONY: up down restart logs ps smoke pause resume reset act1 act2 act3 act4 act5 act6 act7 baseline flags agent-status k8s-up k8s-forward k8s-down k8s-agent-status datadog-agent eks-up eks-down monitors-plan monitors-apply awake

# ---- Kubernetes (the reference deployment) ----
k8s-up:        ## create/update the kind cluster, build + load images, install the Datadog Agent, deploy
	k8s/kind-up.sh
k8s-forward:   ## port-forward the UIs/APIs to localhost (not needed on kind: ports are published directly)
	k8s/port-forward.sh
k8s-down:      ## delete the kind cluster
	k8s/port-forward.sh stop; kind delete cluster --name $${CLUSTER:-tuktukpay}
eks-up:        ## the same stack on EKS (EKS_AWS_ACCOUNT / EKS_AWS_PROFILE in .env): cluster, ECR images, Datadog Agent, deploy
	k8s/eks-up.sh
eks-down:      ## delete the EKS cluster, its VPC/NAT/load balancers and the ECR repositories
	k8s/eks-down.sh
k8s-agent-status: ## Datadog Agent status on the current kube-context (APM, logs, OTLP sections)
	kubectl -n datadog exec ds/datadog-agent -c agent -- agent status | grep -E -A6 '^(APM Agent|Logs Agent|OTLP|Forwarder)'
datadog-agent: ## (re)install only the Datadog Agent on the current kube-context: make datadog-agent CLUSTER_NAME=<name> FLAVOUR=kind|eks
	k8s/datadog-agent.sh "$$(kubectl config current-context)" "$${CLUSTER_NAME:-kind-tuktukpay}" "$${FLAVOUR:-kind}"
monitors-plan: ## Datadog monitors for Bits AI SRE (datadog/terraform): terraform plan
	cd datadog/terraform && set -a && . ../../.env && set +a && terraform init -upgrade >/dev/null \
	  && terraform plan -var "environment=$$DEPLOYMENT_ENVIRONMENT" -var "dd_site=$${DD_SITE:-datadoghq.com}"
monitors-apply: ## create / update the Datadog monitors (needs DD_API_KEY + DD_APP_KEY in .env)
	cd datadog/terraform && set -a && . ../../.env && set +a && terraform init -upgrade >/dev/null \
	  && terraform apply -var "environment=$$DEPLOYMENT_ENVIRONMENT" -var "dd_site=$${DD_SITE:-datadoghq.com}"
awake:         ## keep the Mac from idle-sleeping while the demo runs (a closed lid still sleeps it); Ctrl-C to stop
	caffeinate -dimsu

# ---- Docker Compose (alternative) ----
up:            ## build + start everything
	$(COMPOSE) up -d --build
down:          ## stop and remove containers + database volume
	$(COMPOSE) down -v
restart:
	$(COMPOSE) restart
logs:
	$(COMPOSE) logs -f --tail=100
ps:
	$(COMPOSE) ps
smoke:         ## send test payments + copilot questions
	scripts/smoke-test.sh
pause:         ## stop simulated traffic (payments + copilot questions) to save laptop CPU
	curl -s -X POST $(CHAOS)/traffic -H 'Content-Type: application/json' -d '{"paused": true}'; echo
resume:        ## restart simulated traffic
	curl -s -X POST $(CHAOS)/traffic -H 'Content-Type: application/json' -d '{"paused": false}'; echo
flags:
	curl -s $(CHAOS)/flags | python3 -m json.tool
reset baseline act1 act2 act3 act4 act5 act6 act7:
	curl -s -X POST $(CHAOS)/scenarios/$(if $(filter reset,$@),baseline,$@) | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("title","reset"))'
agent-status:  ## Datadog Agent status in Docker Compose (APM, logs, OTLP sections)
	docker exec datadog-agent agent status | grep -E -A6 '^(APM Agent|Logs Agent|OTLP|Forwarder)'
