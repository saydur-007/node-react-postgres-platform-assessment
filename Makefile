CLUSTER_NAME := devops-assessment
NAMESPACE := dev
ENV_FILE := .env

# Reads DB_USER / DB_PASSWORD / DB_NAME / FRONTEND_PORT straight out of the
# same root .env docker-compose.yml uses - one source of truth for creds.
-include $(ENV_FILE)
export

INGRESS_NGINX_VERSION := controller-v1.15.1
INGRESS_NGINX_MANIFEST := https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_VERSION)/deploy/static/provider/kind/deploy.yaml

METRICS_SERVER_VERSION := v0.9.0
METRICS_SERVER_MANIFEST := https://github.com/kubernetes-sigs/metrics-server/releases/download/$(METRICS_SERVER_VERSION)/components.yaml

MONITORING_NAMESPACE := monitoring
KUBE_PROMETHEUS_STACK_VERSION := 91.8.2

.PHONY: cluster ingress metrics observability images secrets deploy redeploy status clean

# Usage: make cluster ingress images secrets deploy
cluster:
	kind get clusters | grep -qx $(CLUSTER_NAME) || \
		kind create cluster --config k8s/kind-config.yaml

# Pinned to a release tag, not "main" - the manifest contents (and which
# k8s versions it supports) must not change under us on a later run.
ingress:
	kubectl apply -f $(INGRESS_NGINX_MANIFEST)
	# This manifest's controller Deployment only requires kubernetes.io/os:
	# linux, so on a multi-node cluster the scheduler can place it on a
	# worker - but the 80/443 hostPort mappings in kind-config.yaml only
	# reach the control-plane node we labeled ingress-ready=true. Force it
	# there explicitly instead of relying on scheduler luck.
	kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
		--type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true"}}}}}'
	# This manifest doesn't pass --enable-metrics, so the controller never
	# exposes nginx_ingress_controller_* on :10254 (verified live: with the
	# flag unset, /metrics has only Go runtime metrics, nothing
	# ingress-specific). Needed for Task 6's ingress-nginx ServiceMonitor.
	kubectl get deployment ingress-nginx-controller -n ingress-nginx \
		-o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--enable-metrics=true' || \
		kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
			--type json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-metrics=true"}]'
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s

# kind's kubelets serve their metrics endpoint with a self-signed
# certificate that isn't in metrics-server's trusted CA bundle - no real
# cluster CA issued it, kind doesn't set one up for this purpose. Every
# kind + metrics-server guide requires this flag for that reason; it only
# weakens the metrics-server -> kubelet leg inside the cluster, nothing
# external.
metrics:
	kubectl apply -f $(METRICS_SERVER_MANIFEST)
	kubectl get deployment metrics-server -n kube-system \
		-o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls' || \
		kubectl patch deployment metrics-server -n kube-system \
			--type json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	kubectl wait --namespace kube-system \
		--for=condition=available deployment/metrics-server --timeout=120s

# kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics,
# node-exporter) via Helm, pinned chart version, into its own "monitoring"
# namespace - deliberately outside k8s/base and k8s/overlays, so CI's
# `kubectl apply -k` never deploys or manages any of this.
observability:
	kubectl create namespace $(MONITORING_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic grafana-admin-secret \
		-n $(MONITORING_NAMESPACE) \
		--from-literal=admin-user=admin \
		--from-literal=admin-password=$(GRAFANA_ADMIN_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update prometheus-community
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--version $(KUBE_PROMETHEUS_STACK_VERSION) \
		--namespace $(MONITORING_NAMESPACE) \
		--values observability/prometheus-values.yaml \
		--wait --timeout 5m
	kubectl apply -f observability/ingress-metrics.yaml
	kubectl apply -f observability/dashboard-backend.yaml
	kubectl apply -f observability/alerts.yaml

images:
	docker build -f Dockerfile.backend -t backend:dev .
	docker build -f Dockerfile.frontend -t frontend:dev .
	kind load docker-image backend:dev --name $(CLUSTER_NAME)
	kind load docker-image frontend:dev --name $(CLUSTER_NAME)

secrets:
	kubectl apply -f k8s/overlays/dev/namespace.yaml
	kubectl create secret generic app-secrets \
		-n $(NAMESPACE) \
		--from-literal=POSTGRES_USER=$(DB_USER) \
		--from-literal=POSTGRES_PASSWORD=$(DB_PASSWORD) \
		--from-literal=POSTGRES_DB=$(DB_NAME) \
		--from-literal=DB_WRITE_URL=postgres://$(DB_USER):$(DB_PASSWORD)@postgres-service:5432/$(DB_NAME) \
		--from-literal=DB_READ_URL=postgres://$(DB_USER):$(DB_PASSWORD)@postgres-service:5432/$(DB_NAME) \
		--dry-run=client -o yaml | kubectl apply -f -

# Single kustomize apply for the dev overlay (namespace, config, postgres,
# backend, frontend, ingress all at once), then wait for postgres and
# backend to actually be ready. On a brand-new cluster the backend may
# crash-loop once or twice before postgres is ready - Kubernetes' own
# restart backoff handles that; `kubectl wait` just blocks until it settles.
deploy:
	kubectl apply -k k8s/overlays/dev
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres -n $(NAMESPACE) --timeout=120s
	kubectl wait --for=condition=available deployment/backend -n $(NAMESPACE) --timeout=120s

# Rebuild + reload images, then force backend/frontend pods to pick them
# up. Needed because the :dev tag never changes, and imagePullPolicy:
# IfNotPresent means kubelet won't re-pull an image it already has cached
# under that same tag - a plain re-apply of the Deployments is a no-op.
redeploy: images
	kubectl rollout restart deployment/backend -n $(NAMESPACE)
	kubectl rollout restart deployment/frontend -n $(NAMESPACE)
	kubectl rollout status deployment/backend -n $(NAMESPACE)
	kubectl rollout status deployment/frontend -n $(NAMESPACE)

status:
	kubectl get all -n $(NAMESPACE)

clean:
	kind delete cluster --name $(CLUSTER_NAME)
