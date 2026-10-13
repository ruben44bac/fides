# Frequent tasks for Fides. Run `make` or `make help` to list them.
#
# `make run` needs only Docker: it starts PostgreSQL and runs Fides and the simulated
# providers from their images. With LOCAL=1, `make run` and `make demo` use the host's
# Elixir 1.20 with Erlang/OTP 29 instead, as the development targets below do.
# Development and tests need no other configuration: every variable has a default
# (see .env.example).

COMPOSE := docker compose -f deploy/compose.yml
STAFF ?= analyst_es
K8S_OVERLAY ?= deploy/k8s/overlays/local
CODE_SHA := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

.DEFAULT_GOAL := help
.PHONY: help run keys urls logs down setup db server mocks migrate seed reset test precommit lint docs token code demo deploy

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z-]*:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## Start everything in Docker: PostgreSQL, the migrations and seeds, a web node on :4000, a worker and the mocks on :4010 (LOCAL=1: Fides and the mocks from the host)
ifeq ($(LOCAL),1)
	@$(MAKE) --no-print-directory db
	@test -d deps || $(MAKE) setup
	@test -d mocks/deps || (cd mocks && mix deps.get)
	mix ecto.migrate
	@(cd mocks && mix run --no-halt) & MOCKS=$$!; \
	trap 'kill $$MOCKS 2>/dev/null' EXIT INT TERM; \
	mix phx.server
else
	@test -f deploy/compose.env || $(MAKE) --no-print-directory keys
	FIDES_CODE_SHA=$(CODE_SHA) $(COMPOSE) --profile app up -d --wait
	@$(MAKE) --no-print-directory urls
endif

keys: ## Write the development keys compose runs Fides with, once, to deploy/compose.env
	@test -f deploy/compose.env && echo "deploy/compose.env already exists" || { \
	  printf 'SECRET_KEY_BASE=%s\nFIDES_ENCRYPTION_KEY=%s\nFIDES_BLIND_INDEX_KEY=%s\nFIDES_STAFF_TOKEN_KEY=%s\n' \
	    "$$(openssl rand -base64 64 | tr -d '\n')" "$$(openssl rand -base64 32)" \
	    "$$(openssl rand -base64 32)" "$$(openssl rand -base64 32)" > deploy/compose.env; \
	  echo "wrote deploy/compose.env"; }

urls: ## Print where everything answers, and the demo staff
	@echo ""
	@echo "  Back office   http://localhost:$${FIDES_PORT:-4000}/backoffice"
	@echo "  API explorer  http://localhost:$${FIDES_PORT:-4000}/api/swaggerui"
	@echo "  Webhooks got  http://localhost:$${MOCKS_PORT:-4010}/webhooks/page"
	@echo ""
	@echo "  Demo staff, all with the password 'fides demo password' and a code from 'make code':"
	@echo "    analyst_es, analyst_mx, risk_manager_1, risk_manager_2, admin, auditor"
	@echo "    e.g. analyst.es@fides.test; 'make demo' runs the three scenarios"
	@echo ""

logs: ## Follow the logs of Fides and the mocks in Docker
	$(COMPOSE) --profile app logs -f --tail 100 web worker mocks

down: ## Stop everything in Docker; the database's volume stays
	$(COMPOSE) --profile app down

setup: db ## Install the dependencies, create and migrate the database, and seed the demo data (host)
	mix setup
	cd mocks && mix deps.get

db: ## Start only PostgreSQL 18 on port 5434 and wait until it is healthy
	$(COMPOSE) up -d --wait

server: db ## Start only Fides from the host, on :4000
	mix phx.server

mocks: ## Start only the simulated bank providers and the webhook receiver from the host, on :4010
	cd mocks && mix run --no-halt

migrate: db ## Run the migrations, triggers included (host)
	mix ecto.migrate

seed: db ## Seed the reference data, the life cycles and the demo staff; running it again changes nothing (host)
	mix run priv/repo/seeds.exs

reset: db ## Drop the database and set it up again (host)
	mix ecto.reset

test: db ## Run the whole test suite (host)
	mix test

precommit: db ## Compile without warnings, format and test, as before a commit (host)
	mix precommit

lint: ## Check the format, Credo and Sobelow (host)
	mix format --check-formatted
	mix credo
	mix sobelow --exit low --skip

docs: ## Regenerate the data inventory and the life cycle diagrams (host)
	mix fides.gen.inventory
	mix fides.gen.lifecycles

token: ## Print a bearer token for a demo staff user while Fides runs, from the host (STAFF=analyst_es)
	@mix fides.token $(STAFF)

code: ## Print a demo staff user's current TOTP code, to sign in to the back office (STAFF=analyst_es)
ifeq ($(LOCAL),1)
	@mix fides.code $(STAFF)
else
	@$(COMPOSE) --profile app exec web /app/bin/fides eval 'Fides.Release.code("$(STAFF)")'
endif

demo: ## Run the three scripted scenarios against the running app and mocks, and follow them (LOCAL=1: from the host)
ifeq ($(LOCAL),1)
	@mix fides.demo
else
	@$(COMPOSE) --profile app exec web /app/bin/fides eval 'Fides.Release.demo()'
endif

deploy: ## Apply the Kubernetes manifests to the current kubectl context (K8S_OVERLAY=deploy/k8s/overlays/local)
	@test -d $(K8S_OVERLAY) || { echo "No Kubernetes manifests at $(K8S_OVERLAY)"; exit 1; }
	kubectl apply -k $(K8S_OVERLAY)
