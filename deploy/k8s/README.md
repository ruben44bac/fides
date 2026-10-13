# Fides on Kubernetes

One image in two roles, from the contract in [../README.md](../README.md), as a
kustomize base and one overlay per environment.

## The base

| Resource | What |
| --- | --- |
| `web` Deployment, Service and HorizontalPodAutoscaler | Nodes that serve the API, the back office and the inbound webhooks with `FIDES_ROLE=web`: they enqueue jobs and run none, with readiness and liveness probes on `/health`, scaled on CPU from one to four |
| `worker` Deployment | Nodes that take every queue with `FIDES_ROLE=worker` and serve nothing. Scale them on the depth of `oban_jobs`, which the console shows |
| `fides-migrate` Job | Runs `/app/bin/setup` before the nodes start: creates the database if missing, migrates and seeds. It removes itself five minutes after it is done, so the next apply runs it again |
| `postgres` StatefulSet and Service | PostgreSQL 18 with pgvector on a volume, for a demo; production points `DATABASE_URL` at a managed database and drops it |
| `mocks` Deployment and Service | The six simulated bank providers and the webhook receiver |
| `providers-from-workers` NetworkPolicy | Only the workers reach the providers; the web nodes never call them |
| `fides-env` ConfigMap | Every variable but the keys; the `fides-keys` Secret comes from the overlay |

## The local overlay, on kind

The images built on this machine, development keys `make deploy` writes once to
`deploy/k8s/overlays/local/keys.env`, and the web and the mocks on node ports 30400
and 30410:

    kind create cluster --name fides --config deploy/k8s/overlays/local/kind.yaml
    docker build -f deploy/Dockerfile -t fides:local .
    docker build -t fides-mocks:local mocks
    kind load docker-image fides:local fides-mocks:local --name fides
    make deploy
    kubectl -n fides get pods

Then open <http://localhost:30400/backoffice>; the demo staff are the ones of the
README, and `kubectl -n fides exec deploy/web -- /app/bin/fides eval 'Fides.Release.code("analyst_es")'`
prints a code. The demo runs with `kubectl -n fides exec deploy/web -- /app/bin/fides eval 'Fides.Release.demo()'`.

## Another environment

Copy the local overlay: set the namespace, the published image and tag, an Ingress
or a LoadBalancer in place of the node ports, `PHX_HOST` for its host, a `fides-keys` Secret with keys of its own, a managed database in
`DATABASE_URL`, and no `FIDES_DEMO_TOTP_SEED`.
