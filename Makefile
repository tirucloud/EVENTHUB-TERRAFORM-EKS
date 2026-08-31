# EventHub — Terraform + EKS workshop
#
# Everything is scoped to one environment at a time:
#
#     make apply                 # ENV defaults to dev
#     make ENV=stage apply
#     make ENV=prod plan
#
# Run `make` on its own for the list of targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV      ?= dev
ENV_DIR  := terraform/environments/$(ENV)
TF       := terraform -chdir=$(ENV_DIR)
SERVICES := frontend-service event-service booking-service payment-service notification-service

# Read lazily with `=` so a target that needs no AWS access pays nothing, and so
# these resolve after an apply rather than reflecting what was true when make
# started.
TF_OUT       = $(TF) output -raw
AWS_REGION   = $(shell $(TF_OUT) aws_region 2>/dev/null || echo us-east-1)
CLUSTER_NAME = $(shell $(TF_OUT) cluster_name 2>/dev/null)
ECR_URL      = $(shell $(TF_OUT) ecr_repository_url 2>/dev/null)
APP_NS       = eventhub
GIT_SHA      = $(shell git rev-parse HEAD 2>/dev/null || echo local)

# The staged apply order. Each is a separate `terraform apply -target=...`,
# because on a fresh environment the Kubernetes and Helm providers cannot be
# configured until the cluster they point at exists.
INFRA_STAGES := \
	module.vpc \
	module.security_groups \
	module.ecr \
	module.route53 \
	module.eks \
	module.eks_addons

IRSA_TARGETS := \
	-target=module.irsa_ebs_csi_driver \
	-target=module.irsa_cluster_autoscaler \
	-target=module.irsa_cert_manager \
	-target=module.irsa_aws_load_balancer_controller

APP_STAGES := \
	module.cert_manager \
	module.traefik \
	module.k8s_app

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  EventHub — Terraform + EKS        ENV=$(ENV)"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
		/^# ==/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo "  Override the environment with ENV=stage or ENV=prod."
	@echo ""

# == Local development ==========================================================

.PHONY: up
up: ## Start the whole stack locally with docker compose
	docker compose up -d --build
	@echo ""
	@echo "  UI: http://localhost:8080"
	@echo "  event :8081  booking :8082  payment :8083  notification :8084"

.PHONY: down
down: ## Stop the local stack (keeps the database volume)
	docker compose down

.PHONY: clean
clean: ## Stop the local stack and delete the database volume
	docker compose down -v

.PHONY: logs
logs: ## Tail logs from every local service
	docker compose logs -f

.PHONY: smoke
smoke: ## Run the end-to-end saga test against the local stack
	./scripts/smoke-test.sh

.PHONY: test
test: ## Run the Go unit tests
	go test -race -count=1 ./...

.PHONY: fmt
fmt: ## Format Go and Terraform sources
	gofmt -w .
	terraform fmt -recursive terraform/

.PHONY: lint
lint: ## Check formatting and run go vet
	@unformatted="$$(gofmt -l .)"; \
		if [ -n "$$unformatted" ]; then echo "Not gofmt-formatted:"; echo "$$unformatted"; exit 1; fi
	terraform fmt -check -recursive terraform/
	go vet ./...

.PHONY: validate
validate: ## terraform validate all three environments (no AWS credentials needed)
	@for env in dev stage prod; do \
		echo "==> $$env"; \
		terraform -chdir=terraform/environments/$$env init -backend=false -input=false >/dev/null || exit 1; \
		terraform -chdir=terraform/environments/$$env validate || exit 1; \
	done

# == Terraform: setup ===========================================================

.PHONY: init
init: ## Initialise the selected environment
	$(TF) init -input=false

.PHONY: plan
plan: ## Plan the whole environment (only works once the cluster exists)
	$(TF) plan

# == Terraform: infrastructure, one module at a time ============================

.PHONY: vpc
vpc: ## Apply the VPC, subnets, IGW, NAT and route tables
	$(TF) apply -target=module.vpc

.PHONY: sg
sg: ## Apply the security groups
	$(TF) apply -target=module.security_groups

.PHONY: ecr
ecr: ## Apply the ECR repository
	$(TF) apply -target=module.ecr

.PHONY: dns
dns: ## Apply the Route53 hosted zone
	$(TF) apply -target=module.route53

.PHONY: eks
eks: ## Apply the EKS cluster and node group (~15 minutes)
	$(TF) apply -target=module.eks

.PHONY: irsa
irsa: ## Apply the four IRSA roles
	$(TF) apply $(IRSA_TARGETS)

.PHONY: addons
addons: ## Apply the managed add-ons, load balancer controller and autoscaler
	$(TF) apply -target=module.eks_addons

.PHONY: infra
infra: ## Apply every infrastructure module in order, then update kubeconfig
	@for target in $(INFRA_STAGES); do \
		echo ""; echo "==> terraform apply -target=$$target"; \
		if [ "$$target" = "module.eks_addons" ]; then \
			$(TF) apply -auto-approve $(IRSA_TARGETS) || exit 1; \
		fi; \
		$(TF) apply -auto-approve -target=$$target || exit 1; \
	done
	@$(MAKE) --no-print-directory kubeconfig
	@echo ""
	@echo "  Infrastructure ready. Next: make ecr-push, then make apps"

# == Terraform: workloads =======================================================

.PHONY: cert-manager
cert-manager: ## Apply cert-manager and the Let's Encrypt ClusterIssuers
	$(TF) apply -target=module.cert_manager

.PHONY: traefik
traefik: ## Apply Traefik, its load balancer and the DNS record
	$(TF) apply -target=module.traefik

.PHONY: app
app: ## Apply the five services, PostgreSQL and the Ingresses
	$(TF) apply -target=module.k8s_app

.PHONY: apps
apps: ## Apply cert-manager, Traefik and the application in order
	@for target in $(APP_STAGES); do \
		echo ""; echo "==> terraform apply -target=$$target"; \
		$(TF) apply -auto-approve -target=$$target || exit 1; \
	done
	@echo ""
	@$(TF) output -raw app_url 2>/dev/null; echo ""

.PHONY: apply
apply: ## Apply everything (use only after the first staged run)
	$(TF) apply

# == Images =====================================================================

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at this environment's cluster
	@if [ -z "$(CLUSTER_NAME)" ]; then echo "Cluster not found. Run 'make eks' first."; exit 1; fi
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME)

.PHONY: ecr-login
ecr-login: ## Authenticate Docker against ECR
	@if [ -z "$(ECR_URL)" ]; then echo "ECR not found. Run 'make ecr' first."; exit 1; fi
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin $(firstword $(subst /, ,$(ECR_URL)))

.PHONY: ecr-push
ecr-push: ecr-login ## Build all five images and push them to ECR
	@for svc in $(SERVICES); do \
		echo "==> $$svc"; \
		docker build \
			--file services/$$svc/Dockerfile \
			--build-arg APP_VERSION=$(GIT_SHA) \
			--tag $(ECR_URL):$$svc-latest \
			--tag $(ECR_URL):$$svc-$(GIT_SHA) \
			. || exit 1; \
		docker push $(ECR_URL):$$svc-latest || exit 1; \
		docker push $(ECR_URL):$$svc-$(GIT_SHA) || exit 1; \
	done
	@echo ""
	@echo "  Pushed $(words $(SERVICES)) images at $(GIT_SHA)"

.PHONY: scan
scan: ## Scan the locally built images with Trivy (needs trivy installed)
	@for svc in $(SERVICES); do \
		echo "==> $$svc"; \
		trivy image --severity CRITICAL,HIGH --ignore-unfixed eventhub/$$svc:local || exit 1; \
	done

# == Cluster inspection =========================================================

.PHONY: status
status: ## Show what is running in the cluster
	@echo "--- nodes ---";          kubectl get nodes -o wide
	@echo ""; echo "--- eventhub ---";    kubectl get pods,svc,ingress,hpa -n $(APP_NS)
	@echo ""; echo "--- storage ---";     kubectl get pvc -n $(APP_NS)
	@echo ""; echo "--- certificate ---"; kubectl get certificate -n $(APP_NS)

.PHONY: cert-status
cert-status: ## Explain why the TLS certificate has or has not issued
	@kubectl describe certificate eventhub-tls -n $(APP_NS) | tail -30
	@echo ""; echo "--- challenges (empty once issued) ---"
	@kubectl get challenges -A

.PHONY: app-logs
app-logs: ## Tail logs from all five services in the cluster
	kubectl logs -n $(APP_NS) -l app.kubernetes.io/part-of=eventhub --all-containers --tail=100 -f

.PHONY: url
url: ## Print this environment's public URL
	@$(TF_OUT) app_url; echo ""

.PHONY: nameservers
nameservers: ## Print the Route53 nameservers to set at GoDaddy
	@$(TF_OUT) delegation_instructions

.PHONY: smoke-cluster
smoke-cluster: ## Run the saga test against the deployed environment
	BASE_URL=$$($(TF_OUT) app_url) ./scripts/smoke-test.sh

# == Teardown ===================================================================

.PHONY: destroy-apps
destroy-apps: ## Remove the workloads, leaving the cluster running
	$(TF) destroy $(foreach t,$(APP_STAGES),-target=$(t))

.PHONY: destroy
destroy: ## Destroy the whole environment, workloads first
	@echo "This destroys the $(ENV) cluster, VPC, images and DNS records."
	@read -p "Type the environment name ($(ENV)) to continue: " confirm; \
		[ "$$confirm" = "$(ENV)" ] || { echo "Aborted."; exit 1; }
	@echo "==> workloads first, so controller-created load balancers are removed"
	-$(TF) destroy -auto-approve $(foreach t,$(APP_STAGES),-target=$(t))
	@echo "==> the PVC the StatefulSet leaves behind"
	-kubectl delete pvc -n $(APP_NS) --all --ignore-not-found --timeout=120s
	@echo "==> checking the load balancer actually went"
	@# The NLB is created by a controller, not by Terraform, so it is not in
	@# state. If the workload destroy above failed, the controller is gone and
	@# nothing will ever delete it -- and an live NLB holds ENIs that block the
	@# VPC from deleting. Stop here rather than stalling later.
	@n=$$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0); 		if [ "$$n" != "0" ]; then 			echo ""; 			echo "  A load balancer still exists. The workload destroy did not finish."; 			echo "  Deleting the cluster now would orphan it and stall the VPC destroy."; 			echo ""; 			echo "  Fix it, then re-run 'make destroy':"; 			echo "    make destroy-apps                       # retry the workload teardown"; 			echo "  or, if the nodes are already gone and Helm cannot uninstall:"; 			echo "    aws elbv2 delete-load-balancer --load-balancer-arn <arn>"; 			echo "    $(TF) state rm module.traefik.helm_release.traefik"; 			echo ""; 			exit 1; 		fi; 		echo "  no load balancers remain"
	$(TF) destroy -auto-approve
	@echo "==> checking for volumes the CSI driver failed to clean up"
	@# Same orphaning risk as the load balancer: the EBS CSI driver creates the
	@# database volume, so it is not in Terraform state. If it lost its nodes
	@# before deleting it, the volume survives and bills quietly forever.
	@vols=$$(aws ec2 describe-volumes --filters Name=status,Values=available 		--query "Volumes[?Tags[?Key=='ebs.csi.aws.com/cluster']].VolumeId" --output text 2>/dev/null); 		if [ -n "$$vols" ]; then 			echo ""; 			echo "  Orphaned CSI volume(s) found. Terraform cannot see these."; 			for v in $$vols; do echo "    aws ec2 delete-volume --volume-id $$v"; done; 			echo ""; 		else 			echo "  no orphaned volumes"; 		fi
	@echo ""
	@echo "  $(ENV) is gone."
