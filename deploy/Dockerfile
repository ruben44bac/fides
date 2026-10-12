# The one image of Fides. Build it from the repository root:
#
#   docker build -f deploy/Dockerfile -t fides .
#
# The image serves with /app/bin/server, migrates with /app/bin/migrate and
# migrates then seeds with /app/bin/setup. Everything it needs comes from the
# environment (see deploy/README.md), so compose, Kubernetes and the hosted demo
# run the same image.
#
# Builder and runner tags come from Hex's build server:
#   https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian&sort=elixir_version,erlang_version,os_version
# Debian rather than Alpine avoids DNS resolution failures and problems with
# dynamically linked NIFs. Both stages use the same Debian release.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20261005-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# NIFs compile from C, and two asset dependencies are fetched from git
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, so a change in the code alone reuses this layer
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config comes before the dependencies compile, so a change in it
# recompiles them
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

RUN mix compile

COPY assets assets

RUN mix assets.deploy

# Runtime config is read when the release starts, so it never triggers a recompile
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# The final image only carries the release and what it needs at runtime
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 libsctp1 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

LABEL org.opencontainers.image.source="https://github.com/ruben44bac/fides"

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/fides ./

USER nobody

EXPOSE 4000

CMD ["/app/bin/server"]
