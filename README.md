# Node + React + Postgres Platform

A small full-stack app (React frontend, Express backend, PostgreSQL) used as
a DevOps take-home assessment. It is built up in stages: local containers
first, then a local Kubernetes cluster, then Ingress, then (planned) CI/CD,
platform services, and observability.

## Repo structure

```
.
├── backend/
│   ├── src/                  # Express API (index.js), db.js, redisClient.js,
│   │                         # queue.js, worker.js, search.js
│   └── .env.example          # env vars for running the backend without Docker
├── frontend/
│   ├── src/                  # React app (App.jsx, main.jsx)
│   ├── nginx.conf.template   # envsubst'd into nginx's config at container start
│   └── vite.config.js
├── k8s/                      # namespace, configmap, secret example, postgres
│                             # StatefulSet + services, backend/frontend
│                             # Deployments + services, kind cluster config,
│                             # ingress
├── docs/                     # evidence screenshots
├── docker-compose.yml
├── Dockerfile.backend
├── Dockerfile.frontend
├── .dockerignore
├── .env.example               # docker-compose / Makefile env vars
├── Makefile                   # kind cluster + kubectl bring-up targets
└── .github/workflows/ci-cd.yml
```

## Prerequisites

Versions this was built and tested against:

```
$ docker --version
Docker version 29.9.0, build f415da8

$ kind version
kind v0.30.0 go1.24.6 linux/amd64

$ kubectl version --client
Client Version: v1.37.0
Kustomize Version: v5.8.1

$ make --version
GNU Make 4.3
```

---

## Task 1 — Docker Compose

```bash
cp .env.example .env
docker compose up --build -d
```

Open http://localhost:8080.

Reset the database (drops the named volume):

```bash
docker compose down -v
```

### Design decisions

- **Multi-stage builds.** `Dockerfile.backend` separates a `deps` stage
  (`npm ci --omit=dev`) from the `runtime` stage, which only copies in
  `node_modules` and `src/`. `Dockerfile.frontend` separates the Vite
  `build` stage from the `nginx:1.27-alpine` runtime stage, so no Node
  toolchain ships in the final image.
- **Non-root backend.** `Dockerfile.backend` runs as the `node` user that
  `node:22-alpine` already ships with, not root.
- **nginx `/api` proxy via `BACKEND_URL` template.**
  `frontend/nginx.conf.template` is rendered by nginx's built-in
  `envsubst`-on-templates mechanism at container start. Its `/api/`
  location does `proxy_pass ${BACKEND_URL};` with no trailing slash, so a
  request to `/api/items` is forwarded as `/api/items`, preserving the
  prefix the backend's routes expect. The same image is used in
  `docker-compose.yml` (`BACKEND_URL=http://backend:4000`) and in
  `k8s/app-configmap.yaml` (`BACKEND_URL=http://backend-service:4000`).
- **Only the frontend is published to the host.** In `docker-compose.yml`,
  only the `frontend` service has a `ports:` mapping
  (`${FRONTEND_PORT:-8080}:80`). `postgres` and `backend` have no host port
  mapping, so they're reachable only on the Compose network.
- **Healthcheck on `/api/health/ready`, not `/api/health`.** The backend's
  Compose healthcheck calls `/api/health/ready`, which checks Postgres is
  reachable, instead of `/api/health`, which always returns `200`. This
  stops Compose from calling the container healthy before it can actually
  serve `/api/items`.

---

## Task 2 — Kubernetes (kind)

```bash
make cluster ingress images secrets deploy
```

Add to `/etc/hosts`:

```
127.0.0.1 node-react.local
```

Open http://node-react.local.

The frontend was first exposed directly with a `NodePort` Service
(`30080`). Task 3 replaced that with the Ingress below, so
`frontend-service` is now `ClusterIP` only — see Task 3 for how external
access works now.

Rebuild and roll out a code change:

```bash
make redeploy
```

`redeploy` exists because the image tag is always `backend:dev`/`frontend:dev`
and both Deployments use `imagePullPolicy: IfNotPresent`. After `make images`
rebuilds and reloads the image into the kind nodes, a plain re-`apply` of the
Deployment is a no-op (the tag didn't change, so kubelet doesn't re-pull).
`make redeploy` rebuilds, reloads, then runs `kubectl rollout restart` on both
Deployments to force the new image in.

Tear the cluster down:

```bash
make clean
```

### Design decisions

- **StatefulSet + `volumeClaimTemplates`, not a static PV.** Postgres is a
  `StatefulSet` (`k8s/postgres-statefulset.yaml`) with a
  `volumeClaimTemplates` entry, so the controller provisions and binds its
  own PVC automatically; a static PV/PVC pair would have to be created and
  matched by hand.
- **Headless + ClusterIP Postgres services.** `postgres-headless`
  (`clusterIP: None`) exists only because the StatefulSet requires a
  `serviceName`. `DB_WRITE_URL`/`DB_READ_URL` point at the separate
  `postgres-service` (`ClusterIP`), per the assessment's requirement that
  Postgres be reachable via a ClusterIP service.
- **Separate liveness/readiness endpoints.** The backend's `livenessProbe`
  hits `/api/health/live` (process check only); its `readinessProbe` hits
  `/api/health/ready` (checks Postgres). A Postgres outage pulls the pod out
  of Service rotation without restarting it.
- **CPU/memory `requests`/`limits` set now.** Backend, frontend, and
  Postgres all declare `resources.requests`/`limits` (e.g. backend:
  `100m`/`128Mi` requests, `500m`/`256Mi` limits), because a future HPA
  computes CPU/memory percentage against `requests`.
- **Secret created from `.env`, never committed.** `make secrets` builds the
  `app-secrets` Secret from the root `.env` via
  `kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -`.
  `k8s/app-secrets.example.yaml` is committed but holds placeholder values
  only.
- **`PGDATA` in a subdirectory.** `postgres-statefulset.yaml` sets
  `PGDATA=/var/lib/postgresql/data/pgdata`, a subdirectory of the mount,
  because kind's local-path-provisioner volume root can contain a
  `lost+found` entry that makes Postgres refuse to initialize.

---

## Task 3 — Ingress / API Gateway

`make ingress` installs ingress-nginx from the official kind-specific
manifest, pinned to `controller-v1.15.1` (`k8s/` has no copy of it; the
Makefile applies it straight from that pinned URL). `k8s/ingress-dev.yaml`
routes host `node-react.local`: `/api` (Prefix) to `backend-service:4000`,
`/` (Prefix) to `frontend-service:80`, with no `rewrite-target` annotation,
so `/api/items` reaches the backend as `/api/items`.

> As of this writing, Kubernetes SIG Network has retired the community
> ingress-nginx project (announced November 2025); best-effort maintenance
> ran only until March 2026, after which there are no further releases or
> security fixes upstream. `controller-v1.15.1` still works for this local,
> time-boxed assessment, but a real deployment built today should look at
> the Gateway API or another controller instead.
> ([kubernetes.io/blog](https://kubernetes.io/blog/2025/11/11/ingress-Nginx-retirement/))

### Request path: Browser → Ingress → Service → Pod → PostgreSQL

1. Browser resolves `node-react.local` to `127.0.0.1` via the `/etc/hosts`
   entry.
2. Connects to `127.0.0.1:80` → kind's `extraPortMappings`
   (`k8s/kind-config.yaml`) forward that into the
   `devops-assessment-control-plane` node's container port 80.
3. The ingress-nginx controller pod is listening there via `hostPort`: its
   Deployment is pinned with `nodeSelector: {ingress-ready: "true"}`
   (`make ingress`'s `kubectl patch`), the only label matching that node.
4. The controller matches the `Ingress` object (`app-ingress`, namespace
   `dev`) by host and path, and proxies to `backend-service` or
   `frontend-service` — both `ClusterIP` — not to a pod IP directly.
5. `kube-proxy`'s iptables/IPVS rules for that Service load-balance to one
   of its healthy pod endpoints.
6. For `/api/*` requests, the backend pod queries Postgres through
   `postgres-service` (`ClusterIP`), which routes to the single
   `postgres-0` pod.

### Kubernetes DNS

A pod's `/etc/resolv.conf` (confirmed live inside a `backend` pod):

```
search dev.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

- `nameserver 10.96.0.10` is the `kube-dns` Service's ClusterIP, backed by
  the CoreDNS pods in `kube-system`. CoreDNS watches the Kubernetes API for
  `Service`/`EndpointSlice` objects directly and answers from that live
  state — it isn't reading a static zone file.
- `options ndots:5` means a name with fewer than 5 dots is not tried as
  absolute first. A bare `backend-service` is tried against each `search`
  suffix in order — `backend-service.dev.svc.cluster.local` first (same
  namespace) — until one resolves.
- A fully-qualified name with a trailing dot
  (`backend-service.dev.svc.cluster.local.`) skips the search list and
  resolves in one query.

### Debugging

**(a) Ingress reachable, backend not:**

```bash
kubectl get ingress -n dev app-ingress -o yaml   # host/paths/backend names correct?
kubectl get endpoints backend-service -n dev     # empty = selector matches no Ready pod
kubectl get pods -n dev -l app.kubernetes.io/name=backend -o wide
kubectl describe pod -n dev -l app.kubernetes.io/name=backend   # readiness probe status/events
kubectl logs -n dev -l app.kubernetes.io/name=backend --tail=50
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50   # 502/503 upstream errors
```

**(b) Frontend can't reach backend:**

```bash
kubectl logs -n dev -l app.kubernetes.io/name=frontend --tail=50   # nginx access/error log, actual request path
kubectl get cm app-config -n dev -o yaml          # BACKEND_URL=http://backend-service:4000 ?
kubectl exec -n dev deploy/frontend -- cat /etc/nginx/conf.d/default.conf   # did envsubst render BACKEND_URL correctly?
kubectl get ingress -n dev -o yaml                # /api path rule present, no stray rewrite-target
```

### Evolving to microservices

Splitting the backend into multiple services means adding more path rules to
the same `Ingress` — `/api/users` → `users-service`, `/api/orders` →
`orders-service` — each its own `Deployment` + `ClusterIP` Service. The DNS
and probe patterns already in place don't change. Once routing needs more
than path matching — traffic splitting, canary rollouts, mTLS between
services, retries/timeouts per route — a single `Ingress` object stops being
enough, and that's the point to move to a dedicated API gateway or the
Gateway API (the latter is also the direction Kubernetes itself now points
to, given ingress-nginx's retirement above).

---

## Issues found during testing

### 1. Postgres connection pool crash

Deleting the Postgres pod (`kubectl delete pod -n dev postgres-0`) to test
persistence crashed the backend:

- **Symptom:** `kubectl get pods -n dev` showed both backend pods at
  `RESTARTS: 2` shortly after the postgres pod was deleted.
- **Diagnosis:** `kubectl logs <backend-pod> --previous` showed:
  ```
  failed to initialize schema: Error: connect ECONNREFUSED ...
      at async initSchema (file:///app/src/db.js:30:3)
  ```
  The container had actually crashed and restarted — not just failed a
  readiness check — and on restart it reran `initSchema()` against a
  Postgres that wasn't back up yet, failing again.
- **Root cause:** `backend/src/db.js`'s `writePool`/`readPool` (`pg.Pool`
  instances) had no `.on("error", ...)` handler. When an idle pooled
  connection breaks, `pg.Pool` emits an `'error'` event; with no listener,
  Node treats that as an uncaught exception and crashes the process.
- **Fix:** added `writePool.on("error", ...)` and
  `readPool.on("error", ...)` in `backend/src/db.js` (the same pattern
  already used in `backend/src/redisClient.js`).
- **Re-test:** after `make redeploy`, deleted `postgres-0` again and polled
  `kubectl get pods -n dev` for about 40 seconds. Both backend pods stayed
  at `RESTARTS: 0`. `GET /api/items` still returned the item created before
  the test once Postgres was ready again.

### 2. Ingress controller scheduled off the control-plane node

- **Symptom:** `curl -H "Host: node-react.local" http://localhost/api/health`
  failed with `Recv failure: Connection reset by peer` (curl exit code 56),
  even though the controller pod was `Running` and `1/1 Ready`.
- **Cause:** `kubectl get pods -n ingress-nginx -o wide` showed the
  controller pod scheduled on a worker node. The pinned manifest's
  controller Deployment only requires `nodeSelector: {kubernetes.io/os:
  linux}` — nothing pins it to a specific node — so on this 3-node cluster
  the scheduler was free to place it anywhere. But `k8s/kind-config.yaml`'s
  `extraPortMappings` for ports 80/443 only forward into the
  `devops-assessment-control-plane` container (confirmed with
  `docker ps --filter name=devops-assessment-control-plane`). The host's
  port 80 had nothing listening behind it on that node.
- **Fix:** added a `kubectl patch deployment ingress-nginx-controller`
  step to `make ingress`, setting
  `nodeSelector: {ingress-ready: "true"}` — the label only the
  control-plane node carries. After the rollout, `kubectl get pods -n
  ingress-nginx -o wide` showed the pod on `devops-assessment-control-plane`,
  and the same `curl` succeeded.

---

## Known limitations

- `backend/src/db.js`'s `buildConnectionString()` has hardcoded fallback
  credentials (`appuser`/`apppass`/`localhost`/`5432`/`appdb`), used only if
  `DB_WRITE_URL`/`DB_READ_URL` aren't set. Both `docker-compose.yml` and
  `k8s/` always set those, so this fallback path isn't exercised today.
- `backend/package.json`'s `test` script is `node --test test/ || true` —
  the `|| true` means the script always exits `0`, so a real test failure
  wouldn't fail a CI step that runs it.
- The backend logs repeated `redis connection error` messages in both
  Compose and kind, because `backend/src/redisClient.js` and
  `backend/src/queue.js` always try to connect to `REDIS_URL` (default
  `redis://localhost:6379`), and no Redis container exists yet in either
  `docker-compose.yml` or `k8s/` (planned for Task 5). This is expected
  noise, not a bug.

---

## Evidence

- [docs/task2-kubectl-get-all.png](docs/task2-kubectl-get-all.png) —
  `kubectl get all -n dev` output for Task 2.
- [docs/task3-app-ingress.png](docs/task3-app-ingress.png) — the app
  running at http://node-react.local through the Ingress.
- [docs/task3-ingress-controller.png](docs/task3-ingress-controller.png) —
  the ingress-nginx controller pod, pinned to the control-plane node after
  the scheduling fix above.

---

## Task 4 — CI/CD & Multi-Environment Deployment

TODO

## Task 5 — Platform Services: Redis, Queue, Search, Read/Write DB

TODO

## Task 6 — Observability, Scaling & Rate Limiting

TODO
