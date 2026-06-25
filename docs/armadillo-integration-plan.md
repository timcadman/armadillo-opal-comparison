# Integrating the benchmark into molgenis-service-armadillo

A self-contained, runnable benchmarking process living in the
`molgenis-service-armadillo` repo, with selectable Opal and dsBase versions.

## Decision: dsBase is managed by the image (build-time), not at runtime

All three backends get their serverside `dsBase` from their **Docker image build**,
pinned by a build `ARG`. **No runtime `dsadmin.install_*` / GitHub-master installs.**

Rationale: the runtime-install approach is what bit us — a Rock container had been
runtime-upgraded to `dsBase 7.0.0.9000` (master), which broke `numNaDS`/`levelsDS`/
`dim` (7.x signature changes) and was invisible until we inspected the running
container. Image-managed versions are reproducible, survive `docker compose down/up`,
and keep all backends on one known version (the precondition for a valid comparison).

Concretely: one shared `rock-dsbase/Dockerfile` (parameterised by `DSBASE_REF`)
builds the Rock image for **Opal** *and* the Rock image the **Armadillo** `default`/
`rserve` profiles run — so Opal-rock, armadillo-rock and armadillo-rserve all carry
the same dsBase, matched to the client lib.

## Location & layout

New `scripts/benchmark/` (sibling to `release/`, `rock/`, `ops/`), mirroring the
`scripts/release/` layout. Vendored (not submodule) so it runs from a fresh checkout.
Not a Gradle subproject — it orchestrates Docker + R, not Java; an optional thin
`./gradlew benchmark` task can wrap the entrypoint.

```
scripts/benchmark/
  README.md
  benchmark.sh                       # entrypoint: parse flags -> export versions -> up servers -> setup -> bench -> (plot)
  bench.env.dist                     # all config (versions, URLs, creds, run params)
  install_benchmark_dependencies.R
  lib/                               # vendored config.R, bench_lib.R, setup.R, capture.R, speed_true.R, speed_client.R, plot*.R
  opal/
    docker-compose.yml               # ${OPAL_IMAGE_TAG}; rock built from ./rock-dsbase with build args
    rock-dsbase/Dockerfile           # ARG DSBASE_REF / ROCK_BASE -> installs dsBase at build time
  data/                              # optional vendored dsBaseClient .rda fixtures
  results/                           # gitignored output
```

## Version selection — two required flags

| flag | env | drives |
|---|---|---|
| `--opal-version <tag>` | `OPAL_IMAGE_TAG` | `datashield/opal_citest:<tag>` in `opal/docker-compose.yml` |
| `--dsbase-version <X.Y.Z>` | `DSBASE_VERSION` | (a) Opal Rock image, (b) Armadillo profile image, (c) the `dsBaseClient` client lib |

`benchmark.sh` requires both (errors with usage if missing — not defaulted). It
derives `DSBASE_REF=v${DSBASE_VERSION}-permissive` (the dsBase GitHub branch).

## How versions flow (all image-managed)

`rock-dsbase/Dockerfile`:
```dockerfile
ARG ROCK_BASE=datashield/rock_citest-permissive:latest
ARG DSBASE_REF=v6.3.5-permissive
ARG DSBASE_VERSION=6.3.5
FROM ${ROCK_BASE}
ENV ROCK_LIB=/var/lib/rock/R/library
RUN Rscript -e "remotes::install_github('datashield/dsBase', ref='${DSBASE_REF}', \
      dependencies=TRUE, upgrade=FALSE, lib=Sys.getenv('ROCK_LIB'))" \
 && Rscript -e "stopifnot(grepl('^${DSBASE_VERSION}', packageVersion('dsBase', lib.loc=Sys.getenv('ROCK_LIB'))))" \
 && chown -R rock "$ROCK_LIB"
```

`opal/docker-compose.yml` (env-interpolated, nothing mutated at runtime):
```yaml
services:
  opal:
    image: datashield/opal_citest:${OPAL_IMAGE_TAG:-latest}
  rock:
    build:
      context: ./rock-dsbase
      args:
        DSBASE_REF: ${DSBASE_REF}
        DSBASE_VERSION: ${DSBASE_VERSION}
        ROCK_BASE: ${ROCK_BASE:-datashield/rock_citest-permissive:latest}
    image: opal-rock-dsbase-${DSBASE_VERSION}:local
```

- **Armadillo profiles**: build a matching Rock image from the same `rock-dsbase`
  Dockerfile and point the `default`/`rserve` profiles at it via the `ds-profiles`
  API (reuse the repo's `setup-profiles.R` pattern). This keeps the armadillo
  backends on the same dsBase as Opal + the client — the "three-way version
  honesty" that makes the comparison valid. (Passing stock `--arma-rock-image`
  tags is allowed but reintroduces skew; document the trade-off.)
- **Client lib**: `install_benchmark_dependencies.R` installs `dsBaseClient` at
  `DSBASE_VERSION` from `cran.obiba.org` into `.Rlib`; `config.R` warns on mismatch.

## R scripts, deps, config, outputs

- Vendor `config.R`, `bench_lib.R`, `setup.R`, `capture.R`, `speed_true.R`,
  `speed_client.R`, `plot*.R` into `lib/`. They're env-driven; adapt `DATA_DIR`
  (→ vendored `data/`), `OPAL_COMPOSE` (→ vendored compose), `OUT_CSV` (→ `results/`).
- Deps: `DSI`, `DSOpal`, `DSMolgenisArmadillo`, `opalr`, `MolgenisArmadillo`,
  `dsBaseClient` (version-pinned), `tibble`, `ggplot2`, `httr`, `remotes`.
- Outputs in `results/` (gitignored): `primitives.csv`, `speed_true.csv`,
  `speed_client.csv`, `rates.csv`, plots.

## Entrypoint (`benchmark.sh`)

1. Parse `--opal-version`, `--dsbase-version` (required) + optional
   `--arma-rock-image`, `--reps`, `--compute`/`--probe`, `--skip-setup`, `--down`.
2. Export derived env (`DSBASE_REF`, image tags).
3. Opal: `docker compose -f opal/docker-compose.yml build` then `up -d`; wait on :8080.
4. Armadillo: `SERVER_PORT=8081 ./gradlew run` (backgrounded; log+pid to results/);
   wait on `/actuator/health`. (8081 avoids Opal's 8080.)
5. Ensure profiles point at the matching Rock image (build + `ds-profiles` API).
6. `Rscript lib/setup.R`; then `lib/capture.R` (once) + `lib/speed_true.R` /
   `lib/speed_client.R` (and/or the broad client run); optional plots.
7. `--down`: `docker compose down` + kill the gradlew pid.

## Testing model: standalone, not testthat

The benchmark stays a **standalone process** (full rationale in
`docs/refactor-plan.md` "testthat framework fit"). The target repo's
`scripts/release` testthat suite is correctness-only (assertions on one backend,
one profile at a time, operator-run) — a poor fit for a 3-concurrent-backend
measurement process with crash-healing and a Docker-level version matrix.

**Borrow the suite's infrastructure, not its framework** — into this layout:
- `scripts/benchmark/lib/profiles.R` ← port `scripts/release/lib/setup-profiles.R`
  (`create_profile`/`start_profile`, the `profile_defaults` profile→image map) to
  create/start `default` + `rserve` pointed at the **dsBase-matched Rock image**.
  This is the single most valuable reuse and directly serves the version requirement.
- `bench.env(.dist)` ← the `release/` `.env` + `configure_test()` validation idiom
  (URL/cred/version checks; op selection via existing `BACKENDS`/`BENCH_DATASETS`).
- Mirror `release/`'s `lib/` + executable-R + `install_*_dependencies.R` + `README.md`
  so the dir reads as a sibling of `release/`.
- Keep the resilient work-queue, healing, and incremental CSV **intact** (the parts
  testthat would have broken).

**Caveat:** if the goal ever becomes a regression *gate*, wrap a thin testthat
around the produced CSV (`expect_gt(ratio, threshold)`) — assert on the artifact,
never inside the timed loop.

## Risks / assumptions

- **Docker + gradlew are user-run** (sandbox can't); default `ARMA_AUTH=basic` on
  localhost (gradlew OIDC token auth fails outside a configured server).
- **Version availability** — fail fast if a `vX.Y.Z-permissive` branch or exact
  `dsBaseClient` version is missing (the Dockerfile `stopifnot` + a client warn).
- **Opal OOM** — Opal (`datashield/opal_citest`) can OOM (exit 137) under load
  (observed). Consider a compose `mem_limit` / JVM heap setting and the existing
  `heal()`/`OPAL_COMPOSE` restart for long runs.
- **Data provenance** — vendor the dsBaseClient `.rda` fixtures (license-permitting)
  or require `DSBASECLIENT_DATA`.
- **Profile creation** needs the Docker socket + `docker-management-enabled`.
- **`:::` private-API readers** in the timing path can break across client
  versions — keep `tryCatch`→`NA` and pin versions.
