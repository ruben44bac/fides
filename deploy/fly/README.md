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

## Using it

The demo staff exist because `FIDES_DEMO_TOTP_SEED` is set to the phrase
development uses, so the local task computes their codes:

    FIDES_URL=https://fides-demo.fly.dev mix fides.token analyst_mx

Anyone with this repository can sign in as any demo user. All data is synthetic.

## Operating it

- Logs: `fly logs --app fides-demo`, and `fly logs --app fides-demo-mocks` for the providers
- A remote console: `fly ssh console --app fides-demo --pty -C "/app/bin/fides remote"`
- Reseed by hand: `fly ssh console --app fides-demo -C /app/bin/setup`
- Deploy a given image by hand: `fly deploy --config deploy/fly/fly.toml --image registry.fly.io/fides-demo:<sha>`
- Deploy a checkout by hand, built on Fly's builder (the machines are x86_64, so a local build on an Apple silicon Mac would run under emulation): `fly deploy --config deploy/fly/fly.toml --dockerfile deploy/Dockerfile --build-arg FIDES_CODE_SHA="$(git rev-parse HEAD)" --remote-only --ha=false` from the repository, and `fly deploy --config ../deploy/fly/mocks.fly.toml --dockerfile Dockerfile --remote-only --ha=false` from `mocks/`
- Rotate an application key: `fly secrets set --app fides-demo NAME=value`; the app restarts with it
