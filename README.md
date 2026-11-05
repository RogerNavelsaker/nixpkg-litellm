# LiteLLM community OCI gateway image

Nix-built community image for upstream LiteLLM 1.106.2, pinned to source commit `49943cd52ea46aacf8db2e5cb2b890d580fe9bb4`. The community dependency graph excludes `litellm-enterprise` and `litellm-admin-mcp`; this is not the Enterprise image or LiteLLM Admin Agent.

Published images include `ghcr.io/rogernavelsaker/litellm:1.102.1`, `1.106.2-community`, and `1.106.2-community-r1` (digest `sha256:cfd6be25506d31de4020b73465b87e3fba95ce51962d10b438f417755b10f1dd`). The published `1.106.2-community-r2` image adds GNU Coreutils so `cat` is available on runtime `PATH`; its digest is `sha256:75d55b3d0b42ae0198a87f0e80e73431af0a4d3d839a4282851cbddb921b0e95`. The published `1.106.2-community-r3` image includes the Prisma raw-result decoder compatibility fix; its digest is `sha256:62dca098e541ab90f40aef9d66587017cf6b83a49cb766f15ddcf0db7e59d8dc`. The published `1.106.2-community-r4` candidate adds the missing OCI `/etc/os-release` required to bootstrap Prisma Client Python's query engine; its digest is `sha256:50f25952308873129d3477673927d139cf7a2c8b8a9fa3783fead2b7d0ab07fe`. The upstream LiteLLM version remains 1.106.2.

## Build

```sh
nix flake check
nix build .#image
podman load -i result
```

The flake pins Nixpkgs, uv2nix, the Python build-system set, and LiteLLM source in `flake.lock`. It targets `x86_64-linux`. The build uses LiteLLM's locked Python dependencies and vendored Rust dependencies; it does not use an upstream container image.

## Included

- LiteLLM's community `proxy`, `proxy-runtime`, `extra-proxy`, `semantic-router`, `saml`, and `bedrock-realtime` extras.
- The community dashboard bundle shipped in the pinned LiteLLM source.
- PgBouncer 1.26.0 and an offline Prisma CLI/engine toolchain for database-backed proxy features.
- libsndfile 1.2.2 for LiteLLM's audio/transcription handlers.
- Numeric non-root UID/GID `10001:10001`; no provider request is part of the build checks.

The Prisma Python client is generated during the Nix build with Nixpkgs Prisma 6.19.3 and native Linux engine binaries. LiteLLM locks Python package `prisma==0.11.0`, whose generator defaults to Prisma CLI 5.4.2; the image aligns generation with the Nix CLI's engine version and uses the raw-result decoder from Prisma Client Python 0.15.0 to handle Prisma 6's `columns`/`types`/`rows` format. The image also provides `/etc/os-release` (`ID=litellm`): Prisma Client Python 0.11 reads this file before honoring `PRISMA_QUERY_ENGINE_BINARY`, then falls back to the Debian engine-target naming for unknown IDs. Without it, r3 could not start the query engine. The build check covers decoder fixtures and bigint-array conversion. The image includes MIT-licensed `litellm-proxy-extras` 0.4.108, including `litellm_proxy_extras.prisma_toolchain`. The disposable PostgreSQL smoke test applies 213 migrations and verifies the Prisma query engine and `SELECT 1` decoder; model CRUD beyond that remains unverified. The Prisma client and CLI are included; database services are not started automatically.

Third-party dependencies retain their own licenses; the LiteLLM source itself is MIT licensed.

## Runtime contract

- Entrypoint: LiteLLM CLI. Default command reads `/etc/litellm/config.yaml` and listens on `0.0.0.0:4000`.
- Mount a deployment-owned config at `/etc/litellm/config.yaml`; supply provider credentials, `LITELLM_MASTER_KEY`, and `LITELLM_SALT_KEY` through a secret manager or protected runtime environment.
- TCP port metadata: 4000. Keep host exposure and private-network policy at the runtime layer.
- Writable path: `/data` (home/cache/local state); mount `/tmp` as tmpfs for read-only-root runs.
- Liveness endpoint: `GET /health/liveliness`; the OCI healthcheck uses the bundled Python runtime.
- LiteLLM normally fetches its model cost map from upstream. Set `LITELLM_LOCAL_MODEL_COST_MAP=true` to use the bundled map without that request.
- Coreutils (including `cat`) and PgBouncer are available on `PATH`; PgBouncer is not started by the LiteLLM entrypoint.
- Enterprise package and Admin Agent are excluded. The image is not claimed to be feature-equivalent to LiteLLM's full monolithic upstream image.

## Verification

`nix flake check` builds the community environment, verifies the Prisma 6 raw-result decoder against a fixture, checks the Prisma toolchain import and absence of Enterprise packages, and starts a disposable empty-model proxy with test-only keys to check liveness and dashboard delivery. The exact published r3 digest failed DB-enabled LiteLLM startup because the image lacked `/etc/os-release`; this failure occurred before query-engine spawn and before raw-result decoding. The r4 candidate passed the database-backed smoke test below against a fresh PostgreSQL 18.6 database: HTTP 200 readiness with `db=connected`, all 213 migrations applied, query-engine ready, and `SELECT 1` decoded. No provider request or real database was used. The published `r2` image passed a rootless Podman check for `cat` resolution/execution, Prisma toolchain import, and localhost-only health; the `1.106.2-community`, `r1`, and `r2` tags remain unchanged.

Run the database-backed smoke test after building and loading the image. It uses a fresh disposable PostgreSQL container pinned by digest and applies migrations only to that container:

```sh
IMAGE_TAR="$(nix build .#image --no-link --print-out-paths)"
podman load -i "$IMAGE_TAR"
tests/prisma-db-smoke.sh localhost/litellm:1.106.2-community-r4
```

Never put real provider credentials or master/salt keys in Nix sources, image layers, or committed config.
