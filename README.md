# armadillo-opal-comparison

A benchmark comparing DataSHIELD backends — **Opal**, **Armadillo** (default
profile), and **Armadillo** on its **Rock/Rserve profile** — by measuring
**operations per second** for the dsBaseClient `ds.*` and DSI `datashield.*`
functions, plus **login / logout / workspace_load**. Localhost by default,
swappable to external servers via one config block.

## What it measures

Two complementary measurements over a shared **operation registry** (`ops.R`):

**1. Broad throughput survey** (`bench.R`) — runs `ds_ops()`, a nested
`category → op-name → function(cn)` list of **43 ops** (35 `ds.*` + 8
server-side DSI `datashield.*`) across **15 categories** (io, descriptive,
correlation, metadata, coercion, transform, recode, vector, dataframe, reshape,
tabulation, glm, mixed-model, objects, dsi). Each op's call form is taken from
that function's dsBaseClient smoke test (`tests/testthat/test-smk-ds.*`), with
the connect/expect scaffolding stripped. The category travels with each op into
the output, so the plot needs no separate map. Add a function = one line in the
right category in `ops.R` (+ a `PREP_FOR` entry if it needs a prerequisite
object). Each `(backend × op × rep)` cell: reset the workspace → untimed warm-up
→ run the op for `DURATION_SEC`, counting completed calls (`rate = count/elapsed`);
repetitions are independent blocks, each shuffled into a fresh random order.

**2. Primitive true-vs-client speed** (`capture.R` → `speed_true.R` /
`speed_client.R`) — `capture.R` traces the registry to extract the
single-command serverside calls each op issues (`results/primitives.csv`);
`speed_true.R` then times the server's own execution (`endDate − startDate`) and
`speed_client.R` times the same calls as the client observes them (high-level
call through the DSI async poll loop). The gap between the two is the
client-side polling penalty.

Server symbols (datasets): `D` = CNSIM, `D2` = CNSIM_B (merge partner),
`DS` = survival, `DC` = cluster.

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
- **`Rscript probe.R`** — runs each op once (no timing) and prints a per-backend
  OK/FAIL tally; use it to validate call forms before a timed run.

## Files

| file               | role                                                        |
|--------------------|-------------------------------------------------------------|
| `config.R`         | URLs/credentials, project-local lib, `DATASETS` registry, settings |
| `bench_lib.R`      | shared helpers sourced by every script (connections, timing, CSV I/O, primitive I/O) |
| `ops.R`            | the `ds_ops()` operation registry (43 ops) + `flatten_ops` + `PREP_FOR` |
| `start_servers.sh` | start Opal (docker) + Armadillo (gradlew) on localhost      |
| `setup.R`          | load real dsBaseClient datasets, inflate to `N_ROWS`×`N_VARS`, upload to both backends, save workspaces |
| `probe.R`          | validate every op's call form once per backend (no timing)  |
| `bench.R`          | broad throughput survey → `results/rates.csv` (+ `failures.csv`) |
| `capture.R`        | extract single-command serverside primitives → `results/primitives.csv` |
| `speed_true.R`     | true server compute time of those primitives → `results/speed_true.csv` |
| `speed_client.R`   | client-observed time of those primitives → `results/speed_client.csv` |
| `plot.R`           | throughput ratio-vs-Opal figure → `results/comparison.png`  |
| `plot_compute.R`   | server-compute vs round-trip vs client figure → `results/compute.png` |

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
ARMA_AUTH=basic Rscript probe.R                  # validate all call forms

# Scenario 1 -- broad throughput survey:
ARMA_AUTH=basic DURATION_SEC=2 REPS=1 POLL_SLEEP0=0.002 Rscript bench.R   # quick smoke
ARMA_AUTH=basic DURATION_SEC=20 REPS=10 POLL_SLEEP0=0.002 Rscript bench.R # full run
Rscript plot.R                          # -> results/comparison.png

# Scenario 2 -- primitive true-vs-client speed:
ARMA_AUTH=basic Rscript capture.R                # once: build results/primitives.csv
ARMA_AUTH=basic SPEED_REPS=1000 Rscript speed_true.R
ARMA_AUTH=basic SPEED_REPS=100  Rscript speed_client.R
Rscript plot_compute.R                  # -> results/compute.png
```

Output `results/rates.csv`: `backend, op, category, rep, count, elapsed, rate`
(`rate` = ops/second). `results/failures.csv`: `backend, op, rep, error`.
`results/speed_true.csv`: `backend, pid, fn, kind, rep, compute_ms, roundtrip_ms`;
`results/speed_client.csv`: `backend, pid, fn, kind, rep, client_ms`.

## Data

Real dsBaseClient test data from `tests/testthat/data_files` (`DSBASECLIENT_DATA`
/ `DATA_DIR`), inflated in `setup.R` to `N_ROWS` × ~`N_VARS` (default 100,000 ×
30). The `DATASETS` registry maps each dataset → `.rda`, table name, server
symbol, inflation `kind`:
- **flat** (CNSIM, CNSIM_B): rows upsampled with replacement (preserving
  distributions, factor levels, NAs); unique `entity_id` + a `key` join column
  prepended; padded with synthetic columns to ~`N_VARS`.
- **survival / cluster**: tiled with identifier columns re-numbered per tile, so
  subject ids stay unique and cluster groups scale but stay valid.

CNSIM keeps its real ~15% NAs — the same data the dsBaseClient tests use.

## Notes

- Local Armadillo uses basic auth (`admin`/`admin`); set `ARMA_AUTH=basic`.
  Both Armadillo profiles (`ARMA_PROFILE` default, `ARMA_RSERVE_PROFILE` rserve)
  must exist on the server.
- `ds.merge` joins `D` and `D2` on a dedicated `key` column — not `entity_id`,
  which Opal reserves as the (hidden) entity identifier.
- Some ops require server-side packages (`lme4` for `ds.lmerSLMA`) and a
  **permissive** privacy level (recode/Boole thresholds etc. are blocked on a
  non-permissive server); these fail-log rather than abort the run.
- `Rscript plot.R` draws each Armadillo backend's throughput relative to Opal
  (Opal = 1× baseline), per op, as signed ×-faster/slower bars → `comparison.png`.
- `Rscript plot_compute.R` draws server-compute vs round-trip vs client time per
  primitive → `compute.png`; the green-to-red gap is the DSI poll-sleep penalty.
