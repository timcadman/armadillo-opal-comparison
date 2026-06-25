# Benchmark refactor plan (DRY / de-hack)

Goal: split `bench.R`'s several modes into focused, top-to-bottom-readable scripts
driven by a shared primitive set, and pull every cross-cutting helper into one
sourced library. No new abstractions beyond what removes real duplication.

## Target file layout

```
config.R          # URLs / creds / datasets / settings (trimmed)
bench_lib.R       # shared helpers, sourced by every script        [created]
setup.R           # uploads + workspaces
capture.R         # was CAPTURE mode -> results/primitives.csv
speed_true.R      # TRUE server compute (timestamps, many reps)     [created]
speed_client.R    # CLIENT speed (high-level calls, 50ms poll)      [created]
probe.R           # was PROBE mode; validate call forms (optional)
ops.R             # the ds_ops registry (only if the broad client survey is kept)
plot.R            # client-speed plot
plot_compute.R    # server-compute plot
docs/core-functions.md
```

`bench.R` is deleted once its four modes (PROBE / CAPTURE / COMPUTE / throughput)
are replaced. `[created]` = already in place from the current work.

## `bench_lib.R` — the shared library

**Connections / login / logout.** The two login builders (`build_logins`,
`build_discordant_login`) duplicate all the token-vs-basic-auth + profile
branching. Collapse to single row-appenders:
- `arma_append(builder, server, table, profile)` — the one place that knows token/basic + profile.
- `opal_append(builder, server, table)`.
- `build_logins()` and `build_discordant_login(be)` both reduce to a few `*_append` calls.
- `connect_be(be, logindata)` / `build_conns(...)` move out of bench.R (parameterised, not closing over globals).
- `logout_all(conns)` replaces the **logout loop copy-pasted 5×** (bench.R:237,290,400,542 + setup.R). Use `on.exit(logout_all(conns), add=TRUE)` so cleanup runs even on error.
- The `disc_conn` cache moves here (only the client script uses it).

**Server-command timing.** `.parse_iso(x)` + `command_compute_ms(conn, res)` —
the function the TRUE-server script needs. Keep here so the one hacky spot (the
`:::` private-API calls) is isolated to one file.

**CSV I/O.** Three hand-rolled init+append blocks (COMPUTE, rates, CAPTURE) →
`csv_init(path, cols)` + `csv_append(path, df, cols)`. (Implemented as `open_csv`.)

**Workspace reset / default connection.** Move `use_conn(cn)`, `reset(cn)`,
`BASE_SYMBOLS` as-is.

**Primitive set (the new shared contract).**
- `write_primitives(conns, path)` — the body of CAPTURE, as a plain function.
- `read_primitives(path)` — both speed scripts call this, so the primitive set is
  defined once (in `results/primitives.csv`), not duplicated in code.
- `primitive_submit(c1, prim)` / `primitive_hl(cn, prim)` — turn a `{kind,expr}`
  row into the low-level async submit and the high-level call. **Replaces** the
  hard-coded `compute_primitives()` whose closures re-encode expressions CAPTURE
  already discovered. Primitive list becomes *data, not duplicated code*.
- Note: `assign.table` is not produced by the trace (it isn't an aggregate /
  assign-expr command) — keep it as one explicit special-case row.

## The scripts (each just sources the lib + runs one mode)

- **`capture.R`** — `build_conns(BACKENDS[1])` → `write_primitives(...)`. Keeping the
  `trace()` hack isolated in a regenerate-only script is itself a readability win.
- **`speed_true.R`** — `read_primitives()`; per backend/primitive, warm-up then N
  reps of submit→poll(2ms)→`command_compute_ms`→fetch. High rep count.
- **`speed_client.R`** — same primitives via `primitive_hl()` (default 50ms poll).
  Fewer reps. Keeps the broad client-run resilience (`heal`, work-queue,
  `session_rows`) — that logic is client-run-specific and must NOT move to the lib.
- **`probe.R`** — trivial once the lib exists; validate call forms.

## Where the `ds_ops` registry lives

`ds_ops`/`flatten_ops`/`PREP_FOR` matter only to the broad client survey + probe.
- **Option A:** retire `ds_ops` — the primitive set replaces it (big deletion), but
  loses the broad-coverage value the README advertises.
- **Option B (recommended):** keep `ops.R` for the broad client survey *and* have
  both speed scripts share `primitives.csv`. Best of both.
This is the single biggest "how DRY" lever — decide explicitly.

## Hacky things to contain

- **`:::` internal calls** (`DSMolgenisArmadillo:::.get_auth_header`,
  `DSOpal:::.datashield.command`): unavoidable (no public API for the command
  record). Isolate in `command_compute_ms`, `tryCatch`→`NA`, comment as a
  private-API / version-pin risk. Do not reimplement.
- **trace-based CAPTURE**: contain in `write_primitives()`; pass the capture env to
  the tracer instead of leaking `rec`/`CAP` into `.GlobalEnv`; always
  `on.exit(untrace(...))` (currently never untraced).
- **Discordant dual-login** for `ds.dataFrameFill`: after the `*_append` refactor it
  shrinks to a loop. If the client survey drops `dataFrameFill`, the whole
  apparatus (config + setup + `disc_conn` + `DISC_COLS`) can be deleted.
- **docker `heal()`/`OPAL_COMPOSE`**: keep only in the client script; the
  server-compute script does short reps and needs only reconnect-on-failure.
- **Back-compat `OPAL_TABLE_*`/`ARMA_TABLE_*` constants**: delete; use `ds_table_ref()`.

## Sequencing (low-risk, behaviour-preserving first)

1. Create `bench_lib.R` by **moving** (not rewriting) existing functions; source it
   from the intact `bench.R`; confirm every mode still runs.
2. Collapse the two login builders via `arma_append`/`opal_append`; delete the
   back-compat table constants. Smoke-test PROBE/COMPUTE.
3. Add `read/write_primitives` + `primitive_submit/_hl`; have COMPUTE consume
   `read_primitives` instead of `compute_primitives`; verify output matches.
4. Split into `capture.R` / `speed_true.R` / `speed_client.R` (+ optional
   `probe.R` / `ops.R`); delete `bench.R`.
5. Point `plot.R`/`plot_compute.R` at the lib for shared paths; update README +
   `docs/core-functions.md` invocation lines.

## Risks / flags

- **`:::` version skew** — the private-API readers can break on a DSOpal /
  DSMolgenisArmadillo upgrade. Isolated + `tryCatch`'d; pin package versions.
- **`on.exit(logout_all)` ordering** — clean the `.dscn` default connection too.
- **`primitives.csv` as a contract** — speed scripts must fail clearly if it's
  missing (point the user at `capture.R`).
- **`assign.table`** is not produced by the trace — don't lose it when retiring
  `compute_primitives`.
- **Scope creep** — keeping-vs-dropping `ds_ops` and the discordant/`dataFrameFill`
  machinery is one explicit decision, not an incidental side effect.

---

## testthat framework fit

**Recommendation: keep the benchmark STANDALONE.** Borrow dsBaseClient's
connection/login *patterns* and its perf-regression idea, but do not run under
`testthat::test_dir`, do not adopt the `ds.test_env` global, and do not express
timings as `expect_*`.

**Decisive precedent — dsBaseClient already does exactly this.** Its
`tests/testthat/perf_tests/perf_rate.R` is a *side framework*, not assertion
tests: per-driver/platform reference CSVs (`<driver>_<platform>_perf-profile.csv`),
`tolerance.lower/upper` bands, and a `PERF_DURATION_SEC` knob — measurement with
regression bands, sourced from `setup.R` but kept **out** of the `test_that`
files. Even the canonical suite treats timing as reference-tracking, not pass/fail.

**Why testthat fights this benchmark:**
- Timings aren't assertions — `expect_lt(time, ref*tol)` goes red on a loaded
  machine / slow network (false failures); that's *why* dsBaseClient segregates perf.
- Many reps × duration × 3 backends = minutes–hours; testthat assumes fast,
  isolated, deterministic units. The shuffled-per-rep blocks + heal/work-queue
  resilience and the CAPTURE→speed_true/speed_client ordering don't map to
  independent test files.
- Outputs are CSVs/PNGs + derived fold-change, not snapshot-able expectations.
- Needs 3 live backends → testthat convention is `skip_if_not()`, so the suite
  would skip-everything and show a misleading green.
- The `:::` private-API readers and `trace()` CAPTURE are doubly out of place in a
  package test suite.

**testthat *infrastructure* worth borrowing (without being a suite):**
- The **reference-CSV + tolerance-band** pattern from `perf_rate.R` → an optional
  `check.R` that compares fresh `speed_true.csv`/`speed_client.csv` against a
  committed baseline and flags out-of-band rows. The one real benefit (regression
  detection) without the framework.
- The **login-builder appender style** (`builder$append(...)` per driver) →
  confirms the planned `arma_append`/`opal_append` factoring is idiomatic; keep
  credentials in `config.R`/`ENV_FILE`, not `ds.test_env`.
- Align env-knob names with the dsBaseClient perf convention (`PERF_DURATION_SEC`
  ↔ our `DURATION_SEC`/`*_REPS`).
- Keep using the dsBaseClient `.rda` test-data provenance, but do **not** source
  their `init_*_datasets.R` (they assume the suite's `ds.test_env` + fixed layout).

**Do NOT borrow:** `ds.test_env` global state, `login_details.R`/`local_settings.csv`,
or the fixed 3-study discordant fixture (our single-backend dual-session discordant
model is deliberately simpler).

**Target-repo evidence (molgenis-service-armadillo `scripts/release`).** That suite
is a *correctness/release* harness, not measurement: pure value assertions
(`expect_equal(round(ds_mean[1],3), 431.105)`) against **one** backend, iterating
profiles **one at a time** (`run_tests_for_profile`), operator-invoked, and its
README notes CI runs only as admin (`armadillo.get_token` fails in CICD) — i.e. not
a live multi-backend green/red gate. The benchmark must hold **all three backends
open at once** and is measurement, so testthat actively obstructs it (a dropped
backend is *not* a test failure; the heal/work-queue re-queue has no `expect_*`; the
Opal/dsBase **version matrix** is a Docker/shell concern outside R — you'd wrap
testthat in `benchmark.sh` anyway, so it buys nothing at the layer that matters).

The **two suites map to flags, not test files** (`COMPUTE=1` = true-server-speed;
default + `POLL_SLEEP0` = client-speed) — cleaner than two testthat dirs.

**One caveat (both agents):** if the goal ever shifts to a regression *gate*
("assert Armadillo ≥ Opal − X%"), put a thin testthat wrapper around the produced
`rates.csv`/`speed_*.csv` (read CSV → `expect_gt(ratio, threshold)`) — assert on the
*artifact*, never inside the timed loop.
