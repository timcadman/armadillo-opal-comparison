# armadillo-opal-comparison

A deliberately minimal benchmark comparing DataSHIELD backends: **Opal**,
**Armadillo** (default profile), and **Armadillo** again on its **Rserve
profile**. It measures **operations per second** for a set of `ds.*` functions,
plus the speed of **logging in, logging out, and loading a workspace** — on
localhost first, swappable to external servers by editing one config block.

## Functions measured

`datashield.assign.table`, `ds.dataFrameSubset_row`, `ds.dataFrameSubset_col`,
`ds.Boole`, `ds.assign`, `ds.mean`, `ds.table`, `ds.glm`, `ds.glmSLMA`,
`ds.merge`, plus `login` / `logout` / `workspace_load`.

Each `(backend × op × rep)` cell runs for `DURATION_SEC` (default 20s),
repeated `REPS` times (default 10), and all cells are run in a single random
order for reliability.

## Files

| file               | role                                                        |
|--------------------|-------------------------------------------------------------|
| `config.R`         | URLs, credentials, data/benchmark settings — **edit this only** |
| `start_servers.sh` | start Opal (docker) + Armadillo (gradlew) on localhost      |
| `setup.R`          | generate synthetic data, upload to both backends, save workspaces |
| `bench.R`          | run the benchmark → `results/rates.csv`                     |

## Prerequisites

R packages: `DSI`, `DSOpal`, `DSMolgenisArmadillo`, `dsBaseClient`, `opalr`,
`MolgenisArmadillo`, `tibble`. Docker (for Opal) and Java 21 + the
`molgenis-service-armadillo` checkout (for Armadillo).

## Run (localhost)

```bash
bash start_servers.sh                 # Opal :8080, Armadillo :8081
Rscript setup.R                       # once: upload data + save workspaces
DURATION_SEC=2 REPS=1 Rscript bench.R # quick smoke run first
Rscript bench.R                       # full run (20s × 10 reps)
```

Output is a single tidy CSV, `results/rates.csv`:

```
backend, op, rep, count, elapsed, rate
```

`rate` is operations per second (`count / elapsed`).

## External servers

Edit only the URL/credential lines at the top of `config.R`. Armadillo auth is
**token-based by default**: leave `ARMA_TOKEN` blank and it is fetched once via
`armadillo.get_token()` before the timed logins (the handshake is not part of
the timed `datashield.login` step), or set `ARMA_TOKEN` yourself. Set
`ARMA_AUTH=basic` to use `ARMA_USER`/`ARMA_PASS` instead (local dev). The two
Armadillo profiles are `ARMA_PROFILE` (default) and `ARMA_RSERVE_PROFILE`
(`rserve`); both must exist on the server.

## Notes

- Local Armadillo uses basic auth (`admin`/`admin`); set `ARMA_AUTH=basic`.
- `ds.merge` joins `tableA` and `tableB` on a dedicated `key` column. `key` is a
  normal variable on both backends. It is *not* `id`: Opal reserves `id` as the
  entity identifier and hides it from the assigned data frame, so `id` cannot be
  a join key.
- `ds.dataFrameSubset` is benchmarked two ways: `_row` keeps rows matching a
  Boolean condition (all columns), `_col` keeps all rows but only some columns.
- The exact argument forms for `ds.glm` / `ds.table` / `ds.dataFrameSubset` are
  validated by the smoke run; tweak in `bench.R` if a function rejects an
  argument.
