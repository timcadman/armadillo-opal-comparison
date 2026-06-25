# Plan: extend the benchmark to all dsBaseClient + DSI functions

## Context

Today `bench.R` hand-picks ~13 ops. The goal is to benchmark **every dsBaseClient
function (118 `ds.*`) and every DSI function** across the three backends
(opal, armadillo, armadillo_rserve), categorise them, and produce **one plot per
function plus grouped category summaries**.

Decisions taken with the user:
- **Coverage:** best-effort — benchmark every function callable with synthetic
  tabular data; keep a **documented skip-list** for client-side-only, special-data,
  and non-timeable functions, each with a reason.
- **Output:** a multi-page **`results/comparison.pdf`** (category summary page +
  one facet page per category, a panel per function) **plus** a top-level
  **`results/comparison.png`** (the category summary).
- **Per-function metric:** keep the current **relative-to-Opal** encoding
  (× faster/slower than Opal), two bars per function (armadillo, armadillo_rserve).
- **Colours:** armadillo = **`#4285F4`** (classic blue), armadillo_rserve =
  **`#E6B96A`** (deeper gold). Sourced from `~/git-repos/presentations`
  (`theme/styles/index.css`, `build_deck.py` `BLUE_HEX`).

Source material located:
- dsBaseClient source + tests: `/Users/tcadman/git-repos/ds-core/dsBaseClient`
  (v6.3.6.9000; `R/`, `tests/testthat/`). Installed Rd help gives runnable examples
  via `tools::Rd_db("dsBaseClient")`.
- DSI docs: installed, `tools::Rd_db("DSI")` + `args()`.
- Armadillo release tests (real call forms + grouping):
  `/Users/tcadman/git-repos/ds-molgenis/molgenis-service-armadillo/scripts/release/testthat/tests/`
  (esp. `test-13-ds-base.R`, `test-19-dsi-functions.R`, `test-11-assigning.R`).

## Categorisation scheme

Every benchmarked function gets a `category` and `package` tag (written into the
CSV so the plot is data-driven). Categories:

| category | examples |
|---|---|
| Descriptive stats | ds.mean, ds.var, ds.cor, ds.cov, ds.quantileMean, ds.table(1D/2D), ds.tapply, ds.meanByClass, ds.meanSdGp, ds.skewness, ds.kurtosis, ds.summary, ds.corTest |
| Data manipulation | ds.cbind, ds.rbind, ds.c, ds.merge, ds.dataFrame, ds.dataFrameFill, ds.dataFrameSort, ds.dataFrameSubset, ds.subsetByClass, ds.reShape, ds.completeCases, ds.recodeValues, ds.recodeLevels, ds.replaceNA, ds.changeRefGroup |
| Type coercion | ds.asNumeric, ds.asInteger, ds.asCharacter, ds.asLogical, ds.asFactor(.Simple), ds.asMatrix, ds.asDataMatrix, ds.asList, ds.unList |
| Matrix algebra | ds.matrix, ds.matrixMult, ds.matrixInvert, ds.matrixTranspose, ds.matrixDet(.report), ds.matrixDiag, ds.matrixDimnames, ds.rowColCalc |
| Regression/modelling | ds.glm, ds.glmSLMA, ds.glmPredict, ds.glmSummary, ds.auc, ds.ns, ds.lspline, ds.elspline, ds.qlspline |
| Random generation | ds.rNorm, ds.rBinom, ds.rUnif, ds.rPois, ds.sample, ds.seq, ds.rep, ds.setSeed |
| Math/transform | ds.abs, ds.exp, ds.log, ds.sqrt, ds.Boole, ds.vectorCalc, ds.make, ds.assign |
| Inspection/metadata | ds.class, ds.dim, ds.length, ds.colnames, ds.names, ds.levels, ds.exists, ds.testObjExists, ds.isNA, ds.numNA, ds.isValid, ds.mdPattern, ds.unique, ds.quantileMean, ds.metadata, ds.ls, ds.rm, ds.summary |
| Graphics (server agg) | ds.histogram, ds.scatterPlot, ds.boxPlot, ds.contourPlot, ds.densityGrid, ds.heatmapPlot |
| DSI: assign/aggregate | datashield.aggregate, datashield.assign.table, datashield.assign.expr, datashield.assign, datashield.rm |
| DSI: introspection | datashield.symbols, datashield.tables, datashield.table_status, datashield.methods, datashield.method_status, datashield.profiles, datashield.pkg_status |
| DSI: workspace/session | datashield.workspace_save/restore/rm, datashield.workspaces, plus existing login/logout/workspace_load |

(Final assignment is one category per function; the table above is indicative.)

## Skip-list (documented in code + README, not silently dropped)

- **Client-side / admin (no meaningful server timing):** ds.listOpals,
  ds.setDefaultOpals, ds.look, ds.listClientsideFunctions, ds.listServersideFunctions,
  ds.listDisclosureSettings, ds.message.
- **Special data we don't synthesize (best-effort cutoff):** ds.lexis (survival),
  ds.bp_standards, ds.igb_standards, ds.getWGSR (growth standards), ds.mice
  (imputation), ds.gamlss, ds.hetcor, ds.glmerSLMA, ds.lmerSLMA (mixed models),
  ds.forestplot (needs SLMA model object), ds.dmtC2S, ds.ranksSecure.
- **DSI exclusions:** the 28 `ds*` S4 driver generics (driver-internal, not user
  API), the builder (`DSLoginBuilder`, `newDSLoginBuilder`), the 5 client-side
  accessors (`datashield.connections*`, `datashield.errors`,
  `datashield.errorMessages`), and resource functions
  (`datashield.assign.resource`, `datashield.resources`, `datashield.resource_status`)
  since this benchmark has no resources.

The skip-list lives as a named vector `SKIP <- c(fn = "reason", ...)` in `bench.R`
so it is explicit and greppable.

## File changes

### `setup.R` — widen synthetic data
Add columns to `tableA` so all families have valid inputs:
- `log1` (logical), `char1` (character), `num_na` (numeric with ~5% `NA`s, for
  ds.numNA/ds.replaceNA/ds.completeCases/ds.dataFrameFill/ds.mdPattern).
Keep `id/key/num1-4/int1-2/fac1-2/bin_outcome`. Re-upload needs `FORCE=1`.

### `bench.R` — registry-driven ops
- Replace `ds_ops()` with a **`REGISTRY`**: a list of entries
  `list(name=, category=, package=, call=function(cn) <exact call>, newobj=<NA|"sym">)`.
  Exact call forms taken from dsBaseClient Rd examples + `ds-core` testthat +
  release tests. Functions reference `D`/`D2` columns (e.g. `"D$num1"`, `"D$fac1"`).
- **Persistent-session prerequisites** (created once, untimed, alongside `D`/`D2`):
  a numeric matrix `M` (`ds.asMatrix` of numeric cols) + `M2` for matrix ops; a
  fitted `glm.obj` (for ds.glmPredict/ds.glmSummary); a factor `f1`. Documented in
  a `setup_session()` helper.
- Build cells from `REGISTRY × BACKENDS × REPS`; reuse existing `time_op()`.
- Reuse the **per-cell `ds.rm()` cleanup** already added (driven by `entry$newobj`).
- Add **DSI op cells** (the benchmarkable `datashield.*` set above). `datashield.rm`
  / `assign.*` create/remove symbols — handle via `newobj`.
- Keep `session_rows()` (login/logout/workspace_load) unchanged.
- **CSV schema gains `category` + `package` columns**:
  `backend, op, category, package, rep, count, elapsed, rate` → `results/rates.csv`.
- New env knobs (cell count explodes to ~120×3×REPS): `CATEGORY=` and `OPS=` filters
  to run a subset, documented at top. Keep existing `DURATION_SEC/REPS/SEED`.

### `plot.R` — per-function + grouped, multi-page PDF
- Read the now-richer `rates.csv` (has `category`/`package`); keep the
  fold-vs-Opal computation (generalised over all ops).
- **`results/comparison.pdf`** via `pdf(...)` + a `print(ggplot)` loop:
  - Page 1: **category summary** — mean fold per category, 2 bars (armadillo, rserve).
  - Pages 2..N: **one page per category**, `facet_wrap(~op, scales="free_x")`, a
    fold bar pair per function (free x so small/large folds both legible).
- **`results/comparison.png`** = the category-summary page (top-level glance).
- Colours: `scale_fill_manual(values = c(armadillo = "#4285F4", armadillo_rserve = "#E6B96A"))`.
- Keep the signed-fold encoding, `0 = parity`, `%g×` labels; major/minor breaks per
  facet via `scales="free_x"` (drop the global 5×/2.5× breaks on faceted pages,
  keep them on the single summary).

### `README.md`
Update "Functions measured" to describe the registry + categories, the skip-list
and why, the new CSV columns, the PDF/PNG outputs, the `CATEGORY`/`OPS` filters,
and a runtime warning.

## Runtime & memory caveats (call out in README)
- ~120 functions × 3 backends × REPS cells, each `DURATION_SEC` long. A full
  `REPS=10, DURATION_SEC=20` run is many hours. Recommend **`DURATION_SEC=2 REPS=1`**
  for smoke and a category-at-a-time approach via `CATEGORY=` for full runs.
- More ops ⇒ more transient server memory; the per-cell `ds.rm()` keeps the
  persistent session lean, but the known **Opal container OOM** (`-Xmx2G`, 8 GB VM,
  `OOMKilled=true`) can recur on long runs — watch `docker stats opal-localhost-opal-1`.

## Verification
1. `Rscript -e 'invisible(parse("bench.R"))'` and same for `plot.R` (syntax).
2. Start servers (`bash start_servers.sh`), `FORCE=1 Rscript setup.R` (new columns).
3. Smoke: `DURATION_SEC=2 REPS=1 Rscript bench.R` — confirm cells run, the
   `cell N warning/failed` lines attribute any issues, and `rates.csv` has the new
   columns with rows across categories.
4. Single category check: `CATEGORY="Matrix algebra" DURATION_SEC=2 REPS=1 Rscript bench.R`.
5. `Rscript plot.R` → inspect `results/comparison.pdf` (summary page + per-category
   facet pages) and `results/comparison.png`; confirm blue/gold and per-function panels.
6. Spot-check a few functions' call forms against `ds-core/dsBaseClient` Rd examples.
