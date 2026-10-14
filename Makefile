CLUSTER_NAME := devops-assessment
NAMESPACE := dev
ENV_FILE := .env

# Reads DB_USER / DB_PASSWORD / DB_NAME / FRONTEND_PORT straight out of the
# same root .env docker-compose.yml uses - one source of truth for creds.
-include $(ENV_FILE)
export

INGRESS_NGINX_VERSION := controller-v1.15.1
INGRESS_NGINX_MANIFEST := https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_VERSION)/deploy/static/provider/kind/deploy.yaml

.PHONY: cluster ingress images secrets deploy redeploy status clean

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
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s

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
