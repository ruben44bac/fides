# Deploying Fides

One image, built from [`Dockerfile`](Dockerfile), serves every environment. What
differs between environments is only how the image is run, so each descriptor in
this directory consumes the same contract.

## The contract

| Piece | Value |
| --- | --- |
| Image | `ghcr.io/ruben44bac/fides:<commit sha>`, also tagged `main`. The Release workflow publishes it on every merge to `main`, for linux/amd64 today |
| `/app/bin/server` | A node that serves HTTP on `PORT` and takes jobs |
| `/app/bin/migrate` | Runs the pending migrations and exits |
| `/app/bin/setup` | Migrates, then seeds the reference data (and the demo staff when `FIDES_DEMO_TOTP_SEED` is set) and exits. Safe to run before every deploy: the seeds leave existing rows alone |
| `GET /health` | 200 while the database answers, 503 otherwise. Checks reach it over plain HTTP, so it is excluded from the HTTPS redirect |
| Port | 4000 by default, on every interface, IPv4 and IPv6 |
| User | `nobody`, never root |

### Environment

| Variable | Required | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | yes | `ecto://user:password@host:5432/database`, on PostgreSQL 18 with pgvector |
| `SECRET_KEY_BASE` | yes | At least 64 random bytes; signs cookies and sessions |
| `FIDES_ENCRYPTION_KEY` | yes | 32 random bytes, base64; encrypts personal data at rest |
| `FIDES_BLIND_INDEX_KEY` | yes | 32 random bytes, base64; keys the blind index of documents |
| `FIDES_STAFF_TOKEN_KEY` | yes | 32 random bytes, base64; signs staff tokens. Changing it signs everyone out |
| `PHX_HOST` | yes | The public host name, for links and the origin check |
| `PORT` | no | HTTP port, 4000 by default |
| `POOL_SIZE` | no | Database connections per node, 10 by default |
| `ECTO_IPV6` | no | `true` where the database is reached over IPv6 |
| `DNS_CLUSTER_QUERY` | no | DNS name whose records are the other nodes; unset means a single node |
| `FIDES_DEMO_TOTP_SEED` | no | Enables the demo staff and derives their TOTP secrets from this phrase. Never set in production |

Generate the keys with `openssl rand -base64 32` and the secret key base with
`openssl rand -base64 64`.

## Consumers

| Where | Descriptor | Status |
| --- | --- | --- |
| Local development | [`compose.yml`](compose.yml): PostgreSQL 18 with pgvector; the app runs from the host with `mix phx.server` | In use |
| Hosted demo on Fly.io | [`fly/`](fly/README.md): the image above, one node, deployed by the Release workflow after each merge to `main` | In use |
| Kubernetes | Kustomize base and overlays, applied to kind with `make deploy` | Next |

## Checking the image locally

Build it from the repository root and run it against the compose database, in a
database of its own so development data stays untouched:

    docker build -f deploy/Dockerfile -t fides:local .
    docker exec fides-postgres-1 psql -U postgres -c 'CREATE DATABASE fides_image_check'

    docker run --rm -e DATABASE_URL=ecto://postgres:postgres@host.docker.internal:5434/fides_image_check \
      -e SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n') \
      -e FIDES_ENCRYPTION_KEY=$(openssl rand -base64 32) \
      -e FIDES_BLIND_INDEX_KEY=$(openssl rand -base64 32) \
      -e FIDES_STAFF_TOKEN_KEY=$(openssl rand -base64 32) \
      -e FIDES_DEMO_TOTP_SEED="fides development totp seed" \
      -e PHX_HOST=localhost -p 4000:4000 fides:local sh -c '/app/bin/setup && /app/bin/server'

    curl localhost:4000/health
