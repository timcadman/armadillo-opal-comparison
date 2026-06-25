# Core DataSHIELD functions (analysis-driven benchmark set)

The benchmark's function set is derived from real analysis code plus the official
tutorials, so it reflects what analysts actually run rather than the full
dsBaseClient API.

## Sources
- `lc-env-pnd/R`, `lc-bmi-poc/code`, `lc-traj-ineq/code/datashield` (project scripts)
- `rstudio-export (6).zip` (additional analysis scripts)
- DataSHIELD wiki **analysis tutorials** (13 pages under `wiki.datashield.org/en/analysis-tutorials`)
- **dsHelper** (`dh.*`) — each used wrapper resolved to the `ds.*`/`datashield.*` it calls

## Union set

**`ds.*` (56)** — dsBaseClient:
```
arrange as_tibble asCharacter asDataFrame asDataMatrix asFactor asInteger assign
bind_cols bind_rows Boole boxPlot case_when cbind changeRefGroup class colnames
contourPlot cor dataFrame dataFrameFill dataFrameSubset dim distinct exists filter
forestplot glm glmSLMA group_by heatmapPlot histogram if_else length levels lmerSLMA
ls make mean merge mutate numNA quantileMean recodeLevels recodeValues rename rep
replaceNA reShape rm scatterPlot select slice summary table var
```

**`datashield.*` (11)** — DSI:
```
aggregate assign assign.table connections_find login logout pkg_status profiles
tables workspace_save workspaces
```

**`dh.*` (19)** — dsHelper:
```
anyData changeForm classDiscrepancy createTableOne defineCases defineCompleteCase
dropCols findVarsIndex getAnonPlotData getStats lmeMultPoly lmTab makeIQR makeLmerForm
makeOutcome renameVars subjHasData subsetBetween tidyEnv
```
Not in the installed dsHelper (older/renamed or project-local): `dh.changeForm`,
`dh.defineCompleteCase`, `dh.subsetBetween`.

## dh.* → ds.* wrapper map (used wrappers)
| dh.* | wraps |
|---|---|
| `dh.anyData` | `ds.colnames`, `ds.length`, `ds.numNA` |
| `dh.classDiscrepancy` | `datashield.aggregate` |
| `dh.defineCases` | `datashield.assign`, `ds.filter`, `ds.replaceNA` |
| `dh.dropCols` | `ds.dataFrame`, `ds.dataFrameSubset`, `ds.make`, `ds.select` |
| `dh.findVarsIndex` / `dh.getAnonPlotData` | `datashield.aggregate` |
| `dh.getStats` | `datashield.aggregate`, `ds.class`, `ds.dim`, `ds.exists`, `ds.levels` |
| `dh.lmeMultPoly` | `ds.lmerSLMA` |
| `dh.makeIQR` | `datashield.aggregate`, `datashield.assign`, `ds.dataFrame`, `ds.quantileMean` |
| `dh.makeOutcome` | `ds.arrange`, `ds.group_by`, `ds.slice` |
| `dh.renameVars` | `ds.assign`, `ds.dataFrame`, `ds.rename` |
| `dh.subjHasData` | `ds.filter` |
| `dh.tidyEnv` | `ds.ls`, `ds.rm` |
| `dh.createTableOne`, `dh.lmTab`, `dh.makeLmerForm` | (client-side only — no server calls) |

## Primitive-testability

The primitive test (COMPUTE mode) reads true server compute (`endDate − startDate`)
for **a single server command**. So a function is directly testable only if it issues
**exactly one** server command. Measured empirically by counting client-side
`datashield.aggregate`/`assign.*` calls per function:

| server commands | functions |
|--:|---|
| **1 — directly testable** | `ds.mean`, `ds.colnames`, `ds.exists` (confirmed); `ds.dim`, `ds.length` (expected) |
| 2 | `ds.class`, `ds.var`, `ds.assign` |
| 3–4 | `ds.Boole`, `ds.make`, `ds.asNumeric`, `ds.asFactor`, `ds.asInteger`, `ds.asCharacter`, `ds.recodeValues`, `ds.changeRefGroup`, `ds.dataFrameSubset` |
| 5–6 | `ds.summary`, `ds.table`, `ds.cor`, `ds.cbind`, `ds.dataFrame`, `ds.glm`, `ds.glmSLMA` |

Why most are multi-command: each `ds.*` wraps its real work in existence/class
checks + result validation (the "one round trip" refactor target).

**Three relationships to the primitive test:**
1. **Directly testable** — the single-command functions above.
2. **Testable via the underlying serverside call** — the function-as-used is
   multi-command, but its core computation is one serverside call you can time in
   isolation. Confirmed working single calls (Armadillo):
   `dimDS` (13 ms), `lengthDS` (3.8), `classDS` (4.6), `colnamesDS` (3.4),
   `numNaDS` (3.3), `quantileMeanDS` (6.4), `asNumericDS` (39), `asFactorSimpleDS` (20),
   plus arithmetic/`BooleDS`/`sqrt`/`abs` assigns.
3. **Not single-command** — `ds.glm`, `ds.glmSLMA`, `ds.lmerSLMA` are server-iterative
   (IRLS); inherently multi-command.

**Out of scope on the current servers:** the tidyverse verbs (`ds.filter`,
`ds.mutate`, `ds.case_when`, `ds.if_else`, `ds.select`, `ds.arrange`, `ds.group_by`,
`ds.slice`, `ds.distinct`, `ds.bind_rows`, `ds.bind_cols`, `ds.as_tibble`,
`ds.rename`, `ds.asDataFrame`) require the **dsTidyverse** serverside package, which
is not installed on these backends.

**Excluded from the runnable benchmark (documented here only):** the plotting
functions (`ds.histogram`, `ds.boxPlot`, `ds.scatterPlot`, `ds.heatmapPlot`,
`ds.contourPlot`, `ds.forestplot`) — not needed for the two timing scenarios.

## Two benchmark scenarios
1. **Primitives, true compute** — `COMPUTE=1 Rscript bench.R` times the
   single-command subset via the server's own timestamps (→ `results/compute.csv`).
2. **Full function calls, low poll-sleep** — `POLL_SLEEP0=0.002 Rscript bench.R`
   runs the full core `ds.*`/`datashield.*` set as ops/sec with the DSI poll-sleep
   lowered so client-side waiting doesn't dominate (→ `results/rates.csv`).

## Maximum testable primitive subset (in COMPUTE mode)
All map to a single server command and a core function; wired into `compute_primitives` in `bench.R`:
- Aggregates: `dimDS` (ds.dim), `lengthDS` (ds.length), `classDS` (ds.class), `colnamesDS` (ds.colnames), `numNaDS` (ds.numNA), `quantileMeanDS` (ds.quantileMean)
- Assign: `D$LAB_TSC * 2` (ds.assign/ds.make)
- Table load: `datashield.assign.table`
