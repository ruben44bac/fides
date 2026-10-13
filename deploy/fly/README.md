# The hosted demo on Fly.io

A running Fides that anyone can open without installing anything, at
https://fides-demo.fly.dev. It is not the deployment of the system: that is
Kubernetes (see [../README.md](../README.md)). Fly only runs the image that the
Release workflow publishes, with the same commands and variables as every other
environment, so nothing in the application knows about Fly.

## Shape

| App | What | Size | Cost |
| --- | --- | --- | --- |
| `fides-demo` | One node that serves and takes jobs. `/app/bin/setup` runs as the release command before each deploy, so migrations and seeds are always current | shared-cpu-1x, 1 GB | about USD 6 a month |
| `fides-demo-db` | PostgreSQL 18 with pgvector (`pgvector/pgvector:pg18`, the image compose and CI use) on a 1 GB volume, reachable only on the private network as `fides-demo-db.internal` | shared-cpu-1x, 512 MB | about USD 3.5 a month |
| `fides-demo-mocks` | The six simulated bank providers and the webhook receiver, from the mocks image the workflow publishes, reachable only on the private network as `fides-demo-mocks.internal`; they deliver Mexico's webhooks to `fides-demo.internal` | shared-cpu-1x, 256 MB | about USD 2 a month |

The three apps are on a private network of their own, `fides-demo`, so nothing else
in the organization reaches them and they reach nothing else. Fly has no free tier
for new accounts: a card is required. The three apps stay on all the time, so queued
jobs run and the first request is never slow.

## One-time setup

1. Install flyctl and sign in: `fly auth login`.
2. Run `deploy/fly/bootstrap.sh`. It creates the three apps on their own network, the
   volume and the secrets, and deploys the database. `FLY_REGION` (default `dfw`,
   Dallas, the closest region to Mexico) and `FLY_ORG` (default `personal`) override
   the defaults; the region must match `primary_region` in the three TOML files.
3. Create a deploy token per app and save them as the `FLY_API_TOKEN` and
   `FLY_MOCKS_API_TOKEN` secrets of the GitHub repository. Each token may only
   manage its app, so the workflow can touch nothing else in the organization:

       fly tokens create deploy --app fides-demo --expiry 8760h | tr -d '\n' | gh secret set FLY_API_TOKEN
       fly tokens create deploy --app fides-demo-mocks --expiry 8760h | tr -d '\n' | gh secret set FLY_MOCKS_API_TOKEN

4. Merge to `main`, or run the Release workflow by hand. It pushes the two images to
   `registry.fly.io/fides-demo` and `registry.fly.io/fides-demo-mocks` and deploys
   them; the `demo` environment of the repository appears with the first run.

## Trying it

A walkthrough for the team, in order. All the data is synthetic and anyone with this
repository can sign in as any demo user, so there is nothing to protect and nothing
to clean up: every run of the scenarios applies for new, fictitious holders. The
`mix` tasks below run from a checkout of this repository and only use the public API.

### 1. Is it up

    curl https://fides-demo.fly.dev/health

answers `{"status":"ok"}`.

### 2. The back office

Open <https://fides-demo.fly.dev/backoffice> and sign in with a demo user's email, the
password `fides demo password` and the user's current second-factor code. The code
comes from the local task, with no access to Fly, because the demo's
`FIDES_DEMO_TOTP_SEED` is the phrase development uses:

    mix fides.code analyst_es

A code stays current for 30 seconds and works once: signing in twice within those
seconds fails the second time. From a machine without Elixir, the app computes it:

    fly ssh console --app fides-demo -C "/app/bin/fides eval 'Fides.Release.code(\"analyst_es\")'"

| Handle | Email | Who they are |
| --- | --- | --- |
| `analyst_es` | analyst.es@fides.test | Analyst for Spain: sees and works Spain's applications |
| `analyst_mx` | analyst.mx@fides.test | Analyst for Mexico |
| `risk_manager_1` | risk.manager1@fides.test | Risk manager in every country; one proposes a policy version |
| `risk_manager_2` | risk.manager2@fides.test | Risk manager in every country; the other approves it |
| `admin` | admin@fides.test | Administrator |
| `auditor` | auditor@fides.test | Auditor: reads everything, changes nothing |

What to look at, as each user:

- The inbox at `/backoffice`: the applications the user is allowed to see, by state.
- An application's detail: its timeline, the moves the user can make, an information
  request and its answer, the holder's data revealed on demand (every reveal is
  logged) and the case brief the model wrote.
- `/backoffice/applications/new`: a new application, as an analyst.
- `/backoffice/policies`: the policy versions per country, proposed by one risk
  manager and approved by the other.
- `/backoffice/console`: the queues, the bank providers and the failed deliveries.

### 3. The API

The explorer is at <https://fides-demo.fly.dev/api/swaggerui>, and the OpenAPI
document at `/api/open_api`. Every call takes a bearer token; the task signs a demo
user in with the password and the current code, and prints the token:

    FIDES_URL=https://fides-demo.fly.dev mix fides.token analyst_es
    curl -H "Authorization: Bearer <the token>" https://fides-demo.fly.dev/api/applications

### 4. The three scenarios

    FIDES_URL=https://fides-demo.fly.dev mix fides.demo

runs them through the public API, as an integration would, and follows each one
state by state. Keep the inbox open to watch them move:

1. **Approved on its own.** Spain, 10,000 EUR against 2,500 EUR of monthly income:
   the agents take it to `approved` with nobody touching it.
2. **Approved after review.** Spain, 25,000 EUR: it stops in `in_review`, is approved
   with a note, and ends `approved`.
3. **Rejected by the policy.** Mexico, 500,000 MXN: Mexico's provider answers later,
   by a webhook the mocks deliver to the node over the private network, and the
   policy rejects it.

The task fails, naming the scenario, if one does not reach its state within 90
seconds; the logs below say why.

### 5. What the receiver got

The mocks answer only on the private network. A tunnel brings them to your machine:

    fly proxy 4010:4010 --app fides-demo-mocks

Then <http://localhost:4010/webhooks/page> lists the notifications Fides delivered
to the simulated receiver, newest first.

## Operating it

- Logs: `fly logs --app fides-demo`, and `fly logs --app fides-demo-mocks` for the providers
- A remote console: `fly ssh console --app fides-demo --pty -C "/app/bin/fides remote"`
- Reseed by hand: `fly ssh console --app fides-demo -C /app/bin/setup`
- Deploy a given image by hand: `fly deploy --config deploy/fly/fly.toml --image registry.fly.io/fides-demo:<sha>`
- Deploy a checkout by hand, built on Fly's builder (the machines are x86_64, so a local build on an Apple silicon Mac would run under emulation): `fly deploy --config deploy/fly/fly.toml --dockerfile deploy/Dockerfile --build-arg FIDES_CODE_SHA="$(git rev-parse HEAD)" --remote-only --ha=false` from the repository, and `fly deploy --config ../deploy/fly/mocks.fly.toml --dockerfile Dockerfile --remote-only --ha=false` from `mocks/`
- Rotate an application key: `fly secrets set --app fides-demo NAME=value`; the app restarts with it
