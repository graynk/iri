ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=bookworm-20260713-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential ca-certificates git tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets
RUN mix assets.deploy

COPY rel rel
RUN mix release

# Evaluate the assembled release with the pinned Elixir/OTP runtime. This catches
# runtime.exs syntax or config-provider failures during the image build rather
# than after the container enters its restart loop.
RUN DATABASE_PATH=/tmp/iri-build-check.db \
    MEDIA_ROOT=/tmp/iri-build-media \
    SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    IGDB_CLIENT_ID=build-check \
    IGDB_CLIENT_SECRET=build-check \
    LIBRARY_MODE=FAMILY \
    PHX_HOST=localhost \
    _build/prod/rel/iri/bin/iri eval "IO.puts(:release_config_ok)"

FROM debian:${DEBIAN_VERSION} AS app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates curl libgcc-s1 libncurses6 libsctp1 libsqlite3-0 libstdc++6 openssl sqlite3 tzdata && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 iri && \
    useradd --uid 1000 --gid iri --create-home --shell /bin/sh iri && \
    mkdir /data && \
    chown iri:iri /data

WORKDIR /app
COPY --from=build --chown=iri:iri /app/_build/prod/rel/iri ./

USER iri
ENV HOME=/app \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PHX_SERVER=true \
    PORT=4000

VOLUME ["/data"]
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:4000/health || exit 1

# Iri.Application supervises Ecto.Migrator before starting the web endpoint.
CMD ["/app/bin/server"]
