# armadillo-opal-comparison

A deliberately minimal benchmark comparing **Opal** vs **Armadillo** as
DataSHIELD backends. It measures **operations per second** for a set of `ds.*`
functions, plus the speed of **logging in, logging out, and loading a
workspace** — on localhost first, swappable to external servers by editing one
config block.

## Functions measured

`datashield.assign.table`, `ds.subset`, `ds.Boole`, `ds.assign`, `ds.mean`,
`ds.table`, `ds.glm`, `ds.glmSLMA`, `ds.merge`, plus `login` / `logout` /
`workspace_load`.

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

Edit only the URL/credential lines at the top of `config.R`. For an
OAuth-protected Armadillo, set `ARMA_TOKEN` (fetch it once, before running — the
token handshake is not part of the timed `datashield.login` step). Everything
else is unchanged.

## Notes

- Local Armadillo uses basic auth (`admin`/`admin`); no token needed.
- `ds.merge` joins `tableA` and `tableB` on the `id` column. If Opal treats `id`
  purely as an entity identifier and drops it from the assigned data frame, the
  smoke run will surface it — adjust the merge key in `bench.R`/`setup.R` then.
- The exact argument forms for `ds.glm` / `ds.table` / `ds.subset` are validated
  by the smoke run; tweak in `bench.R` if a function rejects an argument.
