# armadillo-opal-comparison

A benchmark comparing DataSHIELD backends — **Opal**, **Armadillo** (default
profile), and **Armadillo** on its **Rock/Rserve profile** — by measuring
**operations per second** for the dsBaseClient `ds.*` and DSI `datashield.*`
functions, plus **login / logout / workspace_load**. Localhost by default,
swappable to external servers via one config block.

## What it measures

`bench.R` drives an **operation registry** (`ds_ops()`): a nested
`category → op-name → function(cn)` list covering essentially the whole
dsBaseClient surface (all exported `ds.*`, ~118) plus the server-side DSI
`datashield.*` functions — ~140 ops in ~24 fine-grained categories (descriptive,
correlation, metadata, coercion, transform, recode, vector, list, dataframe,
reshape, tabulation, matrix, spline, glm, mixed-model, survival, distributional,
imputation, growth, plot, random, io, dsi). Each op's call form + the dataset it
uses are taken from that function's dsBaseClient smoke test
(`tests/testthat/test-smk-ds.*`), with the connect/expect scaffolding stripped.
The category travels with each op into the output, so the plot needs no separate
map. Add a function = one line in the right category (+ a `PREP_FOR` entry if it
needs a prerequisite server object).

Server symbols (datasets): `D` = CNSIM, `D2` = CNSIM_B (merge partner),
`DS` = survival, `DC` = cluster, `DG` = gamlss, `DA` = anthro.

Each `(backend × op × rep)` cell: reset the workspace to the base tables →
build any prerequisite (untimed) → one untimed warm-up call → run the op for
`DURATION_SEC`, counting completed calls (`rate = count/elapsed`). Repetitions
are independent blocks, each shuffled into a fresh random order.

## Resilience (built for long, unattended runs)

- **Incremental output** — every cell's result is appended to `results/rates.csv`
  as it completes, so a crash never loses finished work.
- **Failures recorded** — every failed (backend, op, rep) + error goes to
  `results/failures.csv`, so missing rows are explained, not silent.
- **Self-healing** — if a backend's connection drops mid-run it is healed
  (Opal's container is restarted via `docker compose up -d` when `OPAL_COMPOSE`
  is set) and its cells are **re-queued** and retried, so a crashed-then-recovered
  backend loses no measurements. A backend that can't be healed is skipped and
  re-probed each repetition.
- **`PROBE=1 Rscript bench.R`** — runs each op once (no timing) and prints a
  per-backend OK/FAIL tally; use it to validate call forms before a timed run.

## Files

| file               | role                                                        |
|--------------------|-------------------------------------------------------------|
| `config.R`         | URLs/credentials, project-local lib, `DATASETS` registry, settings |
| `start_servers.sh` | start Opal (docker) + Armadillo (gradlew) on localhost      |
| `setup.R`          | load real dsBaseClient datasets, inflate to `N_ROWS`×`N_VARS`, upload to both backends, save workspaces |
| `bench.R`          | run the benchmark → `results/rates.csv` (+ `failures.csv`)  |
| `plot.R`           | ratio-vs-Opal figures → `results/rates.png`, `rates_by_category.png` |

## dsBaseClient version (project-local library)

The benchmark runs against the **CRAN (Obiba) release** of dsBaseClient, not
whatever dev build is installed globally — pinned in a project-local `.Rlib`.
Install once (matches the version your servers run; 6.3.5 used here):

```r
install.packages("dsBaseClient", lib = ".Rlib",
                 repos = "https://cran.obiba.org", dependencies = FALSE)
```

`config.R` prepends `.Rlib` to `.libPaths()` and warns if it's missing. **The
client must match the servers' `dsBase` version** — a mismatch makes some
functions fail with version-skew errors (e.g. `numNaDS`/`dim`/`length`) that are
not call-form bugs.

## Run (localhost)

```bash
bash start_servers.sh                  # Opal :8080, Armadillo :8081
ARMA_AUTH=basic Rscript setup.R        # once: upload data + save workspaces
ARMA_AUTH=basic PROBE=1 Rscript bench.R          # validate all call forms
ARMA_AUTH=basic DURATION_SEC=2 REPS=1 Rscript bench.R   # quick smoke
ARMA_AUTH=basic DURATION_SEC=20 REPS=10 Rscript bench.R # full run
Rscript plot.R                          # figures
```

Output `results/rates.csv`: `backend, op, category, rep, count, elapsed, rate`
(`rate` = ops/second). `results/failures.csv`: `backend, op, rep, error`.

## Data

Real dsBaseClient test data from `tests/testthat/data_files` (`DSBASECLIENT_DATA`
/ `DATA_DIR`), inflated in `setup.R` to `N_ROWS` × ~`N_VARS` (default 100,000 ×
30). The `DATASETS` registry maps each dataset → `.rda`, table name, server
symbol, inflation `kind`:
- **flat** (CNSIM, CNSIM_B, GAMLSS, anthro): rows upsampled with replacement
  (preserving distributions, factor levels, NAs); unique `entity_id` + a `key`
  join column prepended; padded with synthetic columns to ~`N_VARS`.
- **survival / cluster**: tiled with identifier columns re-numbered per tile, so
  subject ids stay unique and cluster groups scale but stay valid.

CNSIM keeps its real ~15% NAs — the same data the dsBaseClient tests use.

## Notes

- Local Armadillo uses basic auth (`admin`/`admin`); set `ARMA_AUTH=basic`.
  Both Armadillo profiles (`ARMA_PROFILE` default, `ARMA_RSERVE_PROFILE` rserve)
  must exist on the server.
- `ds.merge` joins `D` and `D2` on a dedicated `key` column — not `entity_id`,
  which Opal reserves as the (hidden) entity identifier.
- Some ops require server-side packages (`lme4`, `survival`, `gamlss`, `mice`)
  and a **permissive** privacy level (RNG/`ds.log`/`ds.c` etc. are blocked on a
  non-permissive server). A handful are structurally N/A in a one-server-per-
  backend setup (e.g. `ds.dataFrameFill` harmonizes *across* servers) or need a
  resource (`datashield.resource_status`); these fail-log rather than abort.
- `Rscript plot.R` draws each Armadillo backend's rate ÷ Opal's rate (Opal = 1×
  baseline) per function and per category, with min–max whiskers across reps,
  in Armadillo blue / Rock-rserve gold.
