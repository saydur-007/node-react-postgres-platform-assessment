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
├── k8s/
│   ├── kind-config.yaml       # kind cluster config (cluster-level, not kustomized)
│   ├── app-secrets.example.yaml   # placeholder shape only, never applied
│   ├── base/                  # namespace-agnostic manifests (configmap,
│   │                           # postgres StatefulSet + services,
│   │                           # backend/frontend Deployments + services,
│   │                           # ingress)
│   └── overlays/{dev,preprod,release}/   # namespace, image tags, ingress
│                                         # host per environment
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

No `helm` is required — nothing in the `Makefile` or `k8s/` uses it.

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
  `build` stage from the `nginx:1.27-alpine` runtime stage. No Node
  toolchain ships in the final image.
- **Non-root backend.** `Dockerfile.backend` runs as the `node` user that
  `node:22-alpine` already ships with, not root.
- **nginx `/api` proxy via `BACKEND_URL` template.**
  `frontend/nginx.conf.template` is rendered by nginx's `envsubst`-on-templates
  mechanism at container start. Its `/api/` location does
  `proxy_pass ${BACKEND_URL};` with no trailing slash, so `/api/items` is
  forwarded as `/api/items`, keeping the prefix the backend expects. The
  same image is used in `docker-compose.yml`
  (`BACKEND_URL=http://backend:4000`) and in `k8s/base/app-configmap.yaml`
  (`BACKEND_URL=http://backend-service:4000`).
- **Only the frontend is published to the host.** In `docker-compose.yml`,
  only `frontend` has a `ports:` mapping (`${FRONTEND_PORT:-8080}:80`).
  `postgres` and `backend` have none, so they're reachable only on the
  Compose network.
- **Healthcheck on `/api/health/ready`, not `/api/health`.** The backend's
  Compose healthcheck calls `/api/health/ready`, which checks Postgres,
  instead of `/api/health`, which always returns `200`. This stops Compose
  from calling the container healthy before it can serve `/api/items`.
- **No secrets in Git.** Credentials live in `.env` (gitignored); only
  `.env.example` with placeholder values is committed.

---

## Task 2 — Kubernetes (kind)

```bash
cp .env.example .env   # skip if already done for Task 1
make cluster ingress images secrets deploy
```

`make secrets` reads `.env`, so it has to exist before that step.

Add to `/etc/hosts`:

```
127.0.0.1 node-react.local
```

Open http://node-react.local.

The frontend was first a `NodePort` Service (`30080`). Task 3 replaced that
with the Ingress below, so `frontend-service` is now `ClusterIP` only.

Rebuild and roll out a code change:

```bash
make redeploy
```

`redeploy` exists because images are always tagged `backend:dev`/`frontend:dev`
with `imagePullPolicy: IfNotPresent`. After `make images` rebuilds and
reloads the image, a plain re-`apply` is a no-op — kubelet won't re-pull the
same tag. `make redeploy` rebuilds, reloads, then runs
`kubectl rollout restart` on both Deployments to force the new image in.

Tear the cluster down:

```bash
make clean
```

### Design decisions

- **StatefulSet + `volumeClaimTemplates`, not a static PV.** Postgres is a
  `StatefulSet` (`k8s/base/postgres-statefulset.yaml`) with a
  `volumeClaimTemplates` entry, so the controller provisions and binds its
  own PVC. A static PV/PVC pair would need manual provisioning and binding.
- **Headless + ClusterIP Postgres services.** `postgres-headless`
  (`clusterIP: None`) exists only because the StatefulSet needs a
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
- **`PGDATA` in a subdirectory.** `k8s/base/postgres-statefulset.yaml` sets
  `PGDATA=/var/lib/postgresql/data/pgdata`, a subdirectory of the mount,
  because kind's local-path-provisioner volume root can contain a
  `lost+found` entry that makes Postgres refuse to initialize.

---

## Task 3 — Ingress / API Gateway

`make ingress` installs ingress-nginx from the official kind-specific
manifest, pinned to `controller-v1.15.1` (applied straight from that URL,
not vendored into `k8s/`). `k8s/base/ingress.yaml` routes host
`node-react.local`: `/api` (Prefix) to `backend-service:4000`, `/` (Prefix)
to `frontend-service:80`, with no `rewrite-target` annotation — so
`/api/items` reaches the backend as `/api/items`. Each environment overlay
(`k8s/overlays/{dev,preprod,release}/`) patches the host — `preprod.` and
`release.` prefixes for those two — and sets the namespace; `dev` also
provides the `Namespace` resource the others have their own copy of.

> As of this writing, Kubernetes SIG Network has retired the community
> ingress-nginx project (announced November 2025); best-effort maintenance
> ran only until March 2026, after which there are no further releases or
> security fixes upstream. `controller-v1.15.1` still works for this local,
> time-boxed assessment. A deployment built today should use the Gateway
> API or another controller instead.
> ([kubernetes.io/blog](https://kubernetes.io/blog/2025/11/11/ingress-Nginx-retirement/))

### Request path: Browser → Ingress → Service → Pod → PostgreSQL

1. Browser resolves `node-react.local` to `127.0.0.1` via the `/etc/hosts`
   entry.
2. Connects to `127.0.0.1:80`. kind's `extraPortMappings`
   (`k8s/kind-config.yaml`) forward that into the control-plane node's
   container port 80.
3. The ingress-nginx controller pod listens there via `hostPort` — its
   Deployment is pinned with `nodeSelector: {ingress-ready: "true"}`
   (`make ingress`'s `kubectl patch`), the only label that node carries.
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
`orders-service` — each its own `Deployment` and `ClusterIP` Service. The
DNS and probe patterns already in place don't change. Once routing needs
more than path matching — traffic splitting, canary rollouts, mTLS, per-route
retries/timeouts — move to a dedicated API gateway or the Gateway API.
That's also the direction Kubernetes itself now points to, given
ingress-nginx's retirement above.

---

## Task 4 — CI/CD & Multi-Environment Deployment

`.github/workflows/ci-cd.yml`, triggered on `push` and `pull_request`:

| Branch pattern | Environment |
|---|---|
| `master` | `dev` |
| `pre-release/v*` | `preprod` |
| `release/v*` | `release` |

A `pull_request` run only executes `build-and-test` — `build-and-push`,
`deploy`, and `rollback` are all gated `if: github.event_name == 'push'`
(or `workflow_dispatch` for `rollback`), so PRs never push an image or
touch a cluster.

**Pipeline**: `npm ci` for backend and frontend → backend syntax check
(`node --check`) + `npm test` → frontend `vite build` → (on `push` only)
build both images with `docker/build-push-action` + buildx, GHA layer
cache, tag `<branch>-<short-sha>` (`tr '/' '-'` sanitizes `pre-release/v1.0`
to `pre-release-v1.0`) → push to `ghcr.io` → deploy.

**Deploy target**: an ephemeral `kind` cluster created inside the runner
itself (`.github/actions/deploy-to-kind`), not a long-lived cluster —
because the only cluster that exists for this assessment is `kind` on my
own laptop, which a GitHub-hosted runner can't reach. Each deploy run
installs the same pinned ingress-nginx, applies the target overlay with
that run's GHCR image tag, waits for rollout, then smoke-tests
`/api/health/ready` through the Ingress with the right `Host` header and
fails the job on a non-200. In a real setup, the cluster would be a
persistent one, reached via the kubeconfig of a namespace-scoped
`ServiceAccount` stored as a secret on the matching GitHub Environment —
not implemented here, since that cluster doesn't exist.

**Secrets**: `GITHUB_TOKEN` (short-lived, repo/run-scoped) logs in to
GHCR for both push and pull — no personal access token anywhere. `DB_USER`
/`DB_PASSWORD`/`DB_NAME` are GitHub Actions secrets, read into the
ephemeral cluster's `app-secrets` Secret at deploy time. The GHCR
`imagePullSecret` is created only inside that CI run, directly in the
target namespace, and attached to its `default` ServiceAccount — it is
never written into any committed manifest.

**GitHub Environments**: `dev`, `preprod`, `release` exist as real GitHub
Environments (verified via `gh api .../environments`). `preprod` and
`release` each require my manual review before a deployment proceeds, and
each has a deployment branch policy restricting it to its matching branch
pattern (`pre-release/v*` / `release/v*`) — confirmed live via
`gh api .../environments/preprod/deployment-branch-policies`. `dev` has
neither restriction.

**Rollback**: `workflow_dispatch` takes `environment` + `image_tag` and
redeploys that previously-built GHCR tag through the same ephemeral-cluster
steps as `deploy`. Because `preprod`/`release` carry the branch policies
above, that dispatch must itself be run from a matching branch — GitHub
enforces it at the point the job references `environment:`, regardless of
trigger type. This is the "precise" path. The "fast" path,
`kubectl rollout undo -n <namespace> deployment/<name>`, only makes sense
against a real, already-running cluster with deployment history — it isn't
wired into this workflow since the CI cluster never has any.

**Issues found**:
- `backend/package.json`'s `node --test test/` broke on Node 22 inside the
  `node:22-alpine` image — it tried to resolve `test/` as a CJS module
  (`Cannot find module '/app/test'`) instead of scanning the directory.
  Fixed by changing the script to `node --test test/*.test.js` (shell-glob
  expansion), verified with a passing run and a deliberately-broken one
  that correctly failed.
- A live run on `master` (merge of the Task 4 PR) failed at the `deploy`
  job: `chmod: changing permissions of '/usr/local/bin/kind': Operation not
  permitted` — the hosted runner's user can write into `/usr/local/bin` but
  not `chmod` a file there. Fixed by downloading to `/tmp`, `chmod`-ing
  there, then `sudo mv`-ing into place, for both `kind` and `kustomize` in
  `.github/actions/deploy-to-kind/action.yml`. **Not yet pushed** — the
  next run on a protected branch will still hit this until this fix is
  committed.

**Evidence**: a `docs/task4-actions-run.png` screenshot is referenced by
this plan but doesn't exist yet — every real `push`-triggered run so far
has failed at the `deploy` step on the bug above, so there's no successful
run to screenshot until the fix above is committed and pushed.

## Task 5 — Platform Services: Redis, Queue, Search, Read/Write DB

Added `redis` (`redis:7-alpine`) and `bullmq-worker` (the backend image,
`command: node src/worker.js`) to both `docker-compose.yml` and
`k8s/base/`. `REDIS_URL` is set on the backend, the worker, and in
`k8s/base/app-configmap.yaml`. OpenSearch/`SEARCH_URL` was skipped under
the time limit — `backend/src/search.js` already no-ops cleanly when
`SEARCH_URL` is unset (confirmed in Task 1/2 testing), so nothing breaks.
`/api/health/redis` returns `{"status":"ok"}` against the live cluster.

**Read/write routing** lives in application code: `backend/src/db.js`
holds two `pg.Pool` instances, `writePool` (from `DB_WRITE_URL`) and
`readPool` (from `DB_READ_URL`); `write()` always uses `writePool`,
`read()` always uses `readPool`. The alternative is a DB proxy (PgBouncer,
pgpool-II) that makes the split transparent to the app — simpler
application code, but another component to run and one more network hop.

**Replication lag**: a replica can be milliseconds to seconds behind the
primary. Anything that reads its own recent write — a redirect-after-POST
that re-fetches the record, a uniqueness check before an insert, "did my
update actually save?" — must go through `write()`/`writePool` (the
primary), never `read()`/`readPool`, or it risks reading stale data.

## Task 6 — Observability, Scaling & Rate Limiting

**HPA** (`k8s/base/hpa-backend.yaml`): `autoscaling/v2`, targets the
`backend` Deployment, 2–5 replicas, scales on 70% average CPU utilization.
2 as a floor keeps the readiness/liveness split from Task 2 meaningful (one
pod can be unready without zero capacity); 70% leaves headroom before
requests start queueing; 5 is a sane cap for a local kind cluster's actual
CPU budget. **Needs `metrics-server` installed in kind for the HPA to see
real CPU numbers** — not installed here (time limit), so `kubectl get hpa`
currently shows `TARGETS: cpu: <unknown>/70%`. The HPA object itself is
live and correctly configured either way.

**Rate limiting**: `nginx.ingress.kubernetes.io/limit-rps: "10"` and
`limit-burst-multiplier: "3"` on `k8s/base/ingress.yaml`. ingress-nginx
applies these per Ingress resource, not per path rule, so this currently
covers both `/api` and `/`, not `/api` alone — splitting into two Ingress
objects sharing the same host would scope it to `/api` only, skipped here
for time. 10 req/s per client IP is generous for a single-user local demo
but still catches an accidental infinite-retry loop or a basic flood;
burst×3 (30) absorbs a normal page load's handful of near-simultaneous
requests without tripping on legitimate traffic.

**What I'd alert on, and why**:
- **5xx error rate** — the most direct signal something is actually broken
  for users, independent of load.
- **p95 latency** — catches degradation (slow queries, GC pauses, a
  struggling dependency) that error rate and CPU alone can miss.
- **CPU near the HPA's 70% target with replicas already at 5 (max)** — the
  autoscaler is out of headroom; the next symptom is queueing, not more
  capacity.
- **Postgres down** (`/api/health/ready` failing cluster-wide) — single
  StatefulSet replica, so this is a hard outage, not degraded service, and
  needs to page immediately rather than wait for a trend.

---

## Not completed (time limit)

- **OpenSearch**: add `search-deployment.yaml`/`search-service.yaml`
  (single-node dev mode, same pattern as `redis-deployment.yaml`), set
  `SEARCH_URL=http://search-service:9200`. `backend/src/search.js` already
  has the health-check code; it would just start reporting real status
  instead of being unset.
- **Prometheus + Grafana**: deploy Prometheus with a scrape config
  targeting pods annotated `prometheus.io/scrape: "true"`; annotate the
  backend Deployment accordingly. Add Grafana pointed at that Prometheus,
  with one dashboard covering backend CPU/memory, request rate, error
  rate, and replica count over time (the HPA above makes that last one
  meaningful).
- **Fluent Bit + Loki**: Fluent Bit as a DaemonSet (one per node, so it
  picks up every pod's logs regardless of scheduling) shipping to Loki;
  verify with a Grafana Explore query like `{namespace="dev"}` to confirm
  backend logs are arriving and filterable by label.

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
  controller pod on a worker node. The pinned manifest's controller
  Deployment only requires `nodeSelector: {kubernetes.io/os: linux}` —
  nothing pins it to a specific node — so the scheduler was free to place it
  anywhere on this 3-node cluster. But `k8s/kind-config.yaml`'s
  `extraPortMappings` for ports 80/443 only forward into the control-plane
  container (confirmed with
  `docker ps --filter name=devops-assessment-control-plane`). Nothing was
  listening behind the host's port 80 on the node Docker was actually
  using.
- **Fix:** added a `kubectl patch deployment ingress-nginx-controller`
  step to `make ingress`, setting `nodeSelector: {ingress-ready: "true"}` —
  the label only the control-plane node carries. After the rollout,
  `kubectl get pods -n ingress-nginx -o wide` showed the pod on
  `devops-assessment-control-plane`, and the same `curl` succeeded.

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

## Trade-offs and what I'd do with more time

- TLS on the Ingress with cert-manager (everything is plain HTTP locally).
- Replace ingress-nginx with a maintained controller or the Gateway API.
- Remove the hardcoded fallback DB credentials in db.js and fail fast if DB
  settings are missing.
- Fixed `:dev` image tags need `make redeploy`; CI (Task 4) uses unique
  branch-sha tags instead.
- TODO: more after Tasks 4-6.

---

## Evidence

- [docs/task2-kubectl-get-all.png](docs/task2-kubectl-get-all.png) —
  `kubectl get all -n dev` output for Task 2.
- [docs/task3-app-ingress.png](docs/task3-app-ingress.png) — the app
  running at http://node-react.local through the Ingress.
- [docs/task3-ingress-controller.png](docs/task3-ingress-controller.png) —
  the ingress-nginx controller pod, pinned to the control-plane node after
  the scheduling fix above.
