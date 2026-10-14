# Node + React + Postgres Platform

A small full-stack app (React frontend, Express backend, PostgreSQL) used as
a DevOps take-home assessment. It is built up in stages: local containers
first, then a local Kubernetes cluster, then (planned) Ingress, CI/CD,
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
│                             # ingress (Task 3, not yet documented below)
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
make cluster images secrets deploy
```

Open http://localhost:30080.

> This documents Task 2 as it stood when merged. The `task-3-ingress`
> branch changes `frontend-service` to `ClusterIP` and moves external
> access behind an Ingress instead — not covered in this README section.

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

## Issue found during testing

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
  at `RESTARTS: 0`. `GET /api/items` through the NodePort still returned the
  item created before the test once Postgres was ready again.

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
- [docs/task3-ingress-controller.png](docs/task3-ingress-controller.png) —
  the ingress-nginx controller pod scheduling issue: it first landed on a
  worker node, where the `kind-config.yaml` 80/443 `hostPort` mappings
  (control-plane only) couldn't reach it. Fixed with a `kubectl patch` in
  `make ingress` pinning the controller's `nodeSelector` to
  `ingress-ready: "true"`.

---

## Task 3 — Ingress / API Gateway



## Task 4 — CI/CD & Multi-Environment Deployment



## Task 5 — Platform Services: Redis, Queue, Search, Read/Write DB



## Task 6 — Observability, Scaling & Rate Limiting


