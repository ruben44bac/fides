# Frequent tasks for Fides. Run `make` or `make help` to list them.
#
# Needs Docker, for PostgreSQL, and Elixir 1.20 with Erlang/OTP 29. Development and
# tests need no other configuration: every variable has a default (see .env.example).

COMPOSE := docker compose -f deploy/compose.yml
STAFF ?= analyst_es
K8S_OVERLAY ?= deploy/k8s/overlays/local

.DEFAULT_GOAL := help
.PHONY: help setup db down run server mocks migrate seed reset test precommit lint docs token code deploy

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z-]*:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: db ## Install the dependencies, create and migrate the database, and seed the demo data
	mix setup
	cd mocks && mix deps.get

db: ## Start PostgreSQL 18 on port 5434 and wait until it is healthy
	$(COMPOSE) up -d --wait

down: ## Stop PostgreSQL
	$(COMPOSE) down

run: db ## Start Fides on :4000 and the simulated providers on :4010, setting up on the first run
	@test -d deps || $(MAKE) setup
	@test -d mocks/deps || (cd mocks && mix deps.get)
	mix ecto.migrate
	@(cd mocks && mix run --no-halt) & MOCKS=$$!; \
	trap 'kill $$MOCKS 2>/dev/null' EXIT INT TERM; \
	mix phx.server

server: db ## Start only Fides, on :4000
	mix phx.server

mocks: ## Start only the simulated bank providers and the webhook receiver, on :4010
	cd mocks && mix run --no-halt

migrate: db ## Run the migrations, triggers included
	mix ecto.migrate

seed: db ## Seed the reference data, the life cycles and the demo staff; running it again changes nothing
	mix run priv/repo/seeds.exs

reset: db ## Drop the database and set it up again
	mix ecto.reset

test: db ## Run the whole test suite
	mix test

precommit: db ## Compile without warnings, format and test, as before a commit
	mix precommit

lint: ## Check the format, Credo and Sobelow
	mix format --check-formatted
	mix credo
	mix sobelow --exit low --skip

docs: ## Regenerate the data inventory and the life cycle diagrams
	mix fides.gen.inventory
	mix fides.gen.lifecycles

token: ## Print a bearer token for a demo staff user while Fides runs (STAFF=analyst_es)
	@mix fides.token $(STAFF)

code: ## Print a demo staff user's current TOTP code, to sign in to the back office (STAFF=analyst_es)
	@mix fides.code $(STAFF)

deploy: ## Apply the Kubernetes manifests to the current kubectl context (K8S_OVERLAY=deploy/k8s/overlays/local)
	@test -d $(K8S_OVERLAY) || { echo "No Kubernetes manifests at $(K8S_OVERLAY)"; exit 1; }
	kubectl apply -k $(K8S_OVERLAY)
