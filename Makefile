CLUSTER_NAME := devops-assessment
NAMESPACE := dev
ENV_FILE := .env

# Reads DB_USER / DB_PASSWORD / DB_NAME / FRONTEND_PORT straight out of the
# same root .env docker-compose.yml uses - one source of truth for creds.
-include $(ENV_FILE)
export

.PHONY: cluster images secrets deploy redeploy status clean

# Usage: make cluster images secrets deploy
cluster:
	kind get clusters | grep -qx $(CLUSTER_NAME) || \
		kind create cluster --config k8s/kind-config.yaml

images:
	docker build -f Dockerfile.backend -t backend:dev .
	docker build -f Dockerfile.frontend -t frontend:dev .
	kind load docker-image backend:dev --name $(CLUSTER_NAME)
	kind load docker-image frontend:dev --name $(CLUSTER_NAME)

secrets:
	kubectl apply -f k8s/namespace-dev.yaml
	kubectl create secret generic app-secrets \
		-n $(NAMESPACE) \
		--from-literal=POSTGRES_USER=$(DB_USER) \
		--from-literal=POSTGRES_PASSWORD=$(DB_PASSWORD) \
		--from-literal=POSTGRES_DB=$(DB_NAME) \
		--from-literal=DB_WRITE_URL=postgres://$(DB_USER):$(DB_PASSWORD)@postgres-service:5432/$(DB_NAME) \
		--from-literal=DB_READ_URL=postgres://$(DB_USER):$(DB_PASSWORD)@postgres-service:5432/$(DB_NAME) \
		--dry-run=client -o yaml | kubectl apply -f -

# Applied in dependency order: namespace/config first, postgres next (and
# waited on), then backend (waited on), then frontend - avoids backend pods
# crash-looping through exponential backoff while waiting on a DB that
# isn't there yet.
deploy:
	kubectl apply -f k8s/namespace-dev.yaml
	kubectl apply -f k8s/app-configmap.yaml
	kubectl apply -f k8s/postgres-headless-service.yaml
	kubectl apply -f k8s/postgres-service.yaml
	kubectl apply -f k8s/postgres-statefulset.yaml
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres -n $(NAMESPACE) --timeout=120s
	kubectl apply -f k8s/backend-deployment.yaml
	kubectl apply -f k8s/backend-service.yaml
	kubectl wait --for=condition=available deployment/backend -n $(NAMESPACE) --timeout=120s
	kubectl apply -f k8s/frontend-deployment.yaml
	kubectl apply -f k8s/frontend-service.yaml

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
