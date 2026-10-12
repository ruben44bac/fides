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

Fly has no free tier for new accounts: a card is required. Both apps stay on all
the time, so queued jobs run and the first request is never slow.

## One-time setup

1. Install flyctl and sign in: `fly auth login`.
2. Run `deploy/fly/bootstrap.sh`. It creates both apps, the volume and the
   secrets, and deploys the database. `FLY_REGION` (default `qro`) and `FLY_ORG`
   (default `personal`) override the defaults; the region must match
   `primary_region` in both TOML files.
3. Create a deploy token and save it as the `FLY_API_TOKEN` secret of the GitHub
   repository: `fly tokens create deploy --app fides-demo --expiry 8760h`.
4. Optionally create the `demo` environment in the repository settings, so the
   deployments view links to the URL.
5. Merge to `main`, or run the Release workflow by hand. It pushes the image to
   `registry.fly.io/fides-demo` and deploys it.

## Using it

The demo staff exist because `FIDES_DEMO_TOTP_SEED` is set to the phrase
development uses, so the local task computes their codes:

    FIDES_URL=https://fides-demo.fly.dev mix fides.token analyst_mx

Anyone with this repository can sign in as any demo user. All data is synthetic.

## Operating it

- Logs: `fly logs --app fides-demo`
- A remote console: `fly ssh console --app fides-demo --pty -C "/app/bin/fides remote"`
- Reseed by hand: `fly ssh console --app fides-demo -C /app/bin/setup`
- Deploy a given image by hand: `fly deploy --config deploy/fly/fly.toml --image registry.fly.io/fides-demo:<sha>`
- Rotate an application key: `fly secrets set --app fides-demo NAME=value`; the app restarts with it
