# ==============================================================================
# The benchmark. Measures operations/second for each DataSHIELD ds.* /
# datashield.* function on each backend, plus login / logout / workspace_load.
#
#   Rscript bench.R
#   DURATION_SEC=2 REPS=1 Rscript bench.R     # quick smoke run
#   PROBE=1 Rscript bench.R                    # validate every call form, no timing
#
# Each (backend x op x rep) cell runs the op for DURATION_SEC, counting completed
# calls. Repetitions are independent blocks, each shuffled into a fresh random
# order. Results are written incrementally to results/rates.csv and failures to
# results/failures.csv. A dropped backend is healed (Opal auto-restarted if
# OPAL_COMPOSE is set) and retried; one that cannot be healed is skipped for the
# rest of the run and re-probed at the next repetition.
# Output columns: backend, op, category, rep, count, elapsed, rate
# ==============================================================================

source("config.R")
suppressMessages(library(dsBaseClient))
set.seed(SEED)

secs_since <- function(t0) as.numeric(Sys.time() - t0, units = "secs")

# Run `op` (a no-arg thunk) repeatedly until DURATION_SEC elapses.
time_op <- function(op, secs) {
  n <- 0L; t0 <- Sys.time()
  repeat { op(); n <- n + 1L; if (secs_since(t0) >= secs) break }
  el <- secs_since(t0)
  data.frame(count = n, elapsed = el, rate = n / el)
}

# --- Connections ------------------------------------------------------------
logindata <- build_logins()

# Build connections inside functions so no bare connection object leaks into the
# global env (multiple visible connections confuse functions that auto-detect
# one, e.g. ds.skewness).
connect_be <- function(be) {
  cn <- datashield.login(login_for(logindata, be), assign = FALSE)
  for (d in DATASETS) datashield.assign.table(cn, d$symbol, ds_table_ref(be, d$table))
  cn
}
build_conns <- function() {
  cs <- list()
  for (be in BACKENDS) {
    cat(sprintf("Connecting + assigning tables on %s...\n", be))
    cn <- tryCatch(connect_be(be), error = function(e) {
      message(sprintf("  skipping backend '%s' (unavailable): %s", be, conditionMessage(e))); NULL })
    if (!is.null(cn)) cs[[be]] <- cn
  }
  cs
}
conns <- build_conns()
if (!length(conns)) stop("No backends available; nothing to benchmark.")

# Designate a connection as the DSI default so functions that don't forward
# `datasources` to their internal calls still resolve it.
use_conn <- function(cn) {
  assign(".dscn", cn, envir = globalenv())
  DSI::datashield.connections_default(".dscn", env = globalenv())
}

# Keep only the base dataset symbols between tests; remove everything else so
# each function starts from the same clean state (as the dsBaseClient tests do).
BASE_SYMBOLS <- vapply(DATASETS, function(d) d$symbol, character(1))
reset <- function(cn) {
  info <- tryCatch(ds.ls(datasources = cn), error = function(e) NULL)
  for (o in setdiff(unique(unlist(lapply(info, `[[`, "objects.found"))), BASE_SYMBOLS))
    try(ds.rm(x.names = o, datasources = cn), silent = TRUE)
}

# --- Operation registry -----------------------------------------------------
# Nested  category -> op-name -> function(cn).  The category travels with each op
# (so it reaches the output CSV and the plot needs no separate map), and every op
# takes the LIVE connection `cn` as an argument (resolved per cell), so a
# reconnect after a crash is actually used. Call forms are taken from each
# function's dsBaseClient smoke test (tests/testthat/test-smk-ds.*). Server
# symbols: D = CNSIM, D2 = CNSIM_B (merge), DS = survival, DC = cluster, DG = gamlss.
# Add a function by adding one line in the right category (+ a PREP_FOR entry if
# it needs a prerequisite object).
ds_ops <- function(be) list(
  io = list(
    datashield.assign.table = function(cn) datashield.assign.table(cn, "scratch", table_a_ref(be))
  ),
  descriptive = list(
    ds.mean         = function(cn) ds.mean(x = "D$LAB_TSC", type = "combine", datasources = cn),
    ds.var          = function(cn) ds.var(x = "D$LAB_TSC", type = "combine", datasources = cn),
    ds.quantileMean = function(cn) ds.quantileMean(x = "D$LAB_HDL", datasources = cn),
    ds.meanSdGp     = function(cn) ds.meanSdGp(x = "D$LAB_TSC", y = "D$GENDER", type = "combine", datasources = cn),
    ds.meanByClass  = function(cn) ds.meanByClass(x = "D", outvar = "LAB_TSC", covar = "GENDER", datasources = cn),
    ds.skewness     = function(cn) ds.skewness(x = "D$LAB_TSC", method = 1, type = "combine", datasources = cn),
    ds.kurtosis     = function(cn) ds.kurtosis(x = "D$LAB_TSC", method = 1, type = "combine", datasources = cn),
    ds.summary      = function(cn) ds.summary(x = "D$LAB_TSC", datasources = cn)
  ),
  correlation = list(
    ds.cor     = function(cn) ds.cor(x = "D$LAB_TSC", y = "D$LAB_HDL", type = "combine", datasources = cn),
    ds.cov     = function(cn) ds.cov(x = "D$LAB_TSC", y = "D$LAB_HDL", type = "combine", datasources = cn),
    ds.corTest = function(cn) ds.corTest(x = "D$LAB_TSC", y = "D$LAB_HDL", method = "pearson", datasources = cn),
    ds.hetcor  = function(cn) ds.hetcor(data = "D", datasources = cn)
  ),
  metadata = list(
    ds.dim        = function(cn) ds.dim(x = "D", type = "combine", datasources = cn),
    ds.length     = function(cn) ds.length(x = "D$LAB_TSC", type = "combine", datasources = cn),
    ds.colnames   = function(cn) ds.colnames(x = "D", datasources = cn),
    ds.names      = function(cn) ds.names(xname = "D", datasources = cn),
    ds.class      = function(cn) ds.class(x = "D$LAB_TSC", datasources = cn),
    ds.exists     = function(cn) ds.exists(x = "D", datasources = cn),
    ds.testObjExists = function(cn) ds.testObjExists(test.obj.name = "D", datasources = cn),
    ds.metadata   = function(cn) ds.metadata(x = "D", datasources = cn),
    ds.isNA       = function(cn) ds.isNA(x = "D$LAB_HDL", datasources = cn),
    ds.isValid    = function(cn) ds.isValid(x = "D$LAB_TSC", datasources = cn),
    ds.numNA      = function(cn) ds.numNA(x = "D$LAB_HDL", datasources = cn),
    ds.levels     = function(cn) ds.levels(x = "D$GENDER", datasources = cn),
    ds.ls         = function(cn) ds.ls(datasources = cn),
    ds.message    = function(cn) ds.message(message.obj.name = "D", datasources = cn),
    ds.look       = function(cn) ds.look(toAggregate = "lengthDS('D$LAB_TSC')", datasources = cn),
    ds.listServersideFunctions = function(cn) ds.listServersideFunctions(datasources = cn),
    ds.listClientsideFunctions = function(cn) ds.listClientsideFunctions(),
    ds.listDisclosureSettings  = function(cn) ds.listDisclosureSettings(datasources = cn),
    ds.listOpals  = function(cn) ds.listOpals(),
    ds.setDefaultOpals = function(cn) ds.setDefaultOpals(opal.name = ".dscn")
  ),
  coercion = list(
    ds.asNumeric     = function(cn) ds.asNumeric(x.name = "D$GENDER", newobj = "an", datasources = cn),
    ds.asInteger     = function(cn) ds.asInteger(x.name = "D$GENDER", newobj = "ai", datasources = cn),
    ds.asCharacter   = function(cn) ds.asCharacter(x.name = "D$GENDER", newobj = "ac", datasources = cn),
    ds.asLogical     = function(cn) ds.asLogical(x.name = "D$LAB_TSC", newobj = "alo", datasources = cn),
    ds.asFactor      = function(cn) ds.asFactor(input.var.name = "D$DIS_CVA", newobj.name = "af", datasources = cn),
    ds.asFactorSimple = function(cn) ds.asFactorSimple(input.var.name = "D$DIS_CVA", newobj.name = "afs", datasources = cn),
    ds.asList        = function(cn) ds.asList(x.name = "D", newobj = "al", datasources = cn),
    ds.asMatrix      = function(cn) ds.asMatrix(x.name = "D$LAB_TSC", newobj = "am", datasources = cn),
    ds.asDataMatrix  = function(cn) ds.asDataMatrix(x.name = "D$GENDER", newobj = "adm", datasources = cn)
  ),
  transform = list(
    ds.assign       = function(cn) ds.assign(toAssign = "D$LAB_TSC*2", newobj = "ao", datasources = cn),
    ds.make         = function(cn) ds.make(toAssign = "D$LAB_TSC*2", newobj = "md", datasources = cn),
    ds.Boole        = function(cn) ds.Boole(V1 = "D$LAB_TSC", V2 = "D$LAB_TRIG", Boolean.operator = "==", newobj = "bo", datasources = cn),
    ds.log          = function(cn) ds.log(x = "D$LAB_HDL", newobj = "lg", datasources = cn),
    ds.exp          = function(cn) ds.exp(x = "D$LAB_HDL", newobj = "ex", datasources = cn),
    ds.sqrt         = function(cn) ds.sqrt(x = "D$LAB_HDL", newobj = "sq", datasources = cn),
    ds.abs          = function(cn) ds.abs(x = "D$LAB_TSC", newobj = "ab", datasources = cn),
    ds.vectorCalc   = function(cn) ds.vectorCalc(x = c("D$LAB_TSC", "D$LAB_HDL"), calc = "+", newobj = "vc", datasources = cn)
  ),
  recode = list(
    ds.recodeValues  = function(cn) ds.recodeValues(var.name = "D$DIS_CVA", values2replace.vector = c(0, 1), new.values.vector = c(10, 20), newobj = "rv", datasources = cn),
    ds.recodeLevels  = function(cn) ds.recodeLevels(x = "D$GENDER", newCategories = c("g0", "g1"), newobj = "rl", datasources = cn),
    ds.changeRefGroup = function(cn) ds.changeRefGroup(x = "D$GENDER", ref = "1", newobj = "crg", datasources = cn)
  ),
  vector = list(
    ds.c           = function(cn) ds.c(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "cc", datasources = cn),
    ds.unique      = function(cn) ds.unique(x.name = "D$GENDER", newobj = "uq", datasources = cn),
    ds.seq         = function(cn) ds.seq(FROM.value.char = "1", BY.value.char = "1", LENGTH.OUT.value.char = "10", newobj = "sq2", datasources = cn),
    ds.rep         = function(cn) ds.rep(x1 = 4, times = 6, length.out = NA, each = 1, source.x1 = "clientside", source.times = "c", source.length.out = NULL, source.each = "c", x1.includes.characters = FALSE, newobj = "rep1", datasources = cn),
    ds.replaceNA   = function(cn) ds.replaceNA(x = "D$LAB_HDL", forNA = list(0), newobj = "rna", datasources = cn),
    ds.completeCases = function(cn) ds.completeCases(x1 = "D", newobj = "ccx", datasources = cn)
  ),
  list = list(
    ds.list   = function(cn) ds.list(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "li", datasources = cn),
    ds.unList = function(cn) ds.unList(x.name = "li", newobj = "ul", datasources = cn)
  ),
  dataframe = list(
    ds.dataFrameSubset_row = function(cn) ds.dataFrameSubset(df.name = "D", V1.name = "D$LAB_TSC", V2.name = "D$LAB_HDL", Boolean.operator = "!=", newobj = "sub_row", datasources = cn),
    ds.dataFrameSubset_col = function(cn) ds.dataFrameSubset(df.name = "D", V1.name = "D$LAB_TSC", V2.name = "D$LAB_TSC", Boolean.operator = ">=", keep.cols = c(1, 2, 3), newobj = "sub_col", datasources = cn),
    ds.dataFrameSort = function(cn) ds.dataFrameSort(df.name = "D", sort.key.name = "D$LAB_TSC", newobj = "sorted", datasources = cn),
    ds.dataFrame  = function(cn) ds.dataFrame(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "df2", datasources = cn),
    ds.dataFrameFill = function(cn) ds.dataFrameFill(df.name = "D", newobj = "filled", datasources = cn),
    ds.dmtC2S     = function(cn) ds.dmtC2S(dfdata = data.frame(a = 1:5, b = 6:10), newobj = "dmt", datasources = cn),
    ds.cbind      = function(cn) ds.cbind(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "cb", datasources = cn),
    ds.rbind      = function(cn) ds.rbind(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "rb", datasources = cn),
    ds.merge      = function(cn) ds.merge(x.name = "D", y.name = "D2", by.x.names = "key", by.y.names = "key", newobj = "mg", datasources = cn),
    ds.sample     = function(cn) ds.sample(x = "D", size = 100, newobj = "smp", datasources = cn)
  ),
  reshape = list(
    ds.reShape       = function(cn) ds.reShape(data.name = "DS", v.names = "age.60", timevar.name = "time.id", idvar.name = "id", direction = "wide", newobj = "rsh", datasources = cn),
    ds.subset        = function(cn) ds.subset(x = "D", subset = "subD", rows = c(1:50), cols = c(1, 2), datasources = cn),
    ds.subsetByClass = function(cn) ds.subsetByClass(x = "D", subsets = "sbc", variables = "GENDER", datasources = cn)
  ),
  tabulation = list(
    ds.table         = function(cn) ds.table(rvar = "D$GENDER", cvar = "D$DIS_CVA", datasources = cn),
    ds.table1D       = function(cn) ds.table1D(x = "D$GENDER", datasources = cn),
    ds.table2D       = function(cn) ds.table2D(x = "D$DIS_DIAB", y = "D$GENDER", datasources = cn),
    ds.tapply        = function(cn) ds.tapply(X.name = "D$LAB_TSC", INDEX.names = "D$GENDER", FUN.name = "mean", datasources = cn),
    ds.tapply.assign = function(cn) ds.tapply.assign(X.name = "D$LAB_TSC", INDEX.names = "D$GENDER", FUN.name = "mean", newobj = "ta", datasources = cn)
  ),
  matrix = list(
    ds.matrix          = function(cn) ds.matrix(mdata = 2, from = "clientside.scalar", nrows.scalar = 3, ncols.scalar = 4, newobj = "m2", datasources = cn),
    ds.matrixDet       = function(cn) ds.matrixDet(M1 = "mat", newobj = "mdet", datasources = cn),
    ds.matrixDet.report = function(cn) ds.matrixDet.report(M1 = "mat", datasources = cn),
    ds.matrixInvert    = function(cn) ds.matrixInvert(M1 = "mat", newobj = "minv", datasources = cn),
    ds.matrixMult      = function(cn) ds.matrixMult(M1 = "mat", M2 = "mat", newobj = "mmul", datasources = cn),
    ds.matrixTranspose = function(cn) ds.matrixTranspose(M1 = "mat", newobj = "mtr", datasources = cn),
    ds.matrixDiag      = function(cn) ds.matrixDiag(x1 = "mat", aim = "serverside.matrix.2.vector", newobj = "mdg", datasources = cn),
    ds.matrixDimnames  = function(cn) ds.matrixDimnames(M1 = "mat", dimnames = list(c("a", "b", "c", "d"), c("a", "b", "c", "d")), newobj = "mdn", datasources = cn),
    ds.rowColCalc      = function(cn) ds.rowColCalc(x = "numdf", operation = "rowSums", newobj = "rcc", datasources = cn)
  ),
  spline = list(
    ds.ns       = function(cn) ds.ns(x = "D$PM_BMI_CONTINUOUS", df = 3, newobj = "nsDS", datasources = cn),
    ds.lspline  = function(cn) ds.lspline(x = "D$PM_BMI_CONTINUOUS", knots = c(15, 25, 35), newobj = "lsp", datasources = cn),
    ds.qlspline = function(cn) ds.qlspline(x = "D$PM_BMI_CONTINUOUS", q = 4, na.rm = TRUE, newobj = "qsp", datasources = cn),
    ds.elspline = function(cn) ds.elspline(x = "D$PM_BMI_CONTINUOUS", n = 3, newobj = "esp", datasources = cn)
  ),
  glm = list(
    ds.glm          = function(cn) ds.glm(formula = "LAB_TSC ~ LAB_TRIG", data = "D", family = "gaussian", datasources = cn),
    ds.glm_binomial = function(cn) ds.glm(formula = "DIS_DIAB ~ LAB_TSC + GENDER", data = "D", family = "binomial", datasources = cn),
    ds.glmSLMA      = function(cn) ds.glmSLMA(formula = "LAB_TSC ~ LAB_TRIG", family = "gaussian", dataName = "D", newobj = "glmslma", datasources = cn),
    ds.glmSummary   = function(cn) ds.glmSummary(x = "glm.mod", datasources = cn),
    ds.glmPredict   = function(cn) ds.glmPredict("glm.mod", newdataname = NULL, output.type = "response", se.fit = FALSE, na.action = "na.pass", datasources = cn),
    ds.auc          = function(cn) ds.auc(pred = "D$LAB_TSC", y = "D$DIS_DIAB", datasources = cn)
  ),
  `mixed-model` = list(
    ds.lmerSLMA  = function(cn) ds.lmerSLMA(formula = "incid_rate ~ trtGrp + Male + (1|idDoctor)", dataName = "DC", datasources = cn),
    ds.glmerSLMA = function(cn) ds.glmerSLMA(formula = "incid_rate ~ trtGrp + Male + (1|idDoctor)", family = "poisson", dataName = "DC", datasources = cn)
  ),
  survival = list(
    ds.lexis = function(cn) ds.lexis(data = "DS", intervalWidth = c(1.0, 1.5, 2.5), idCol = "DS$id", entryCol = "DS$starttime", exitCol = "DS$endtime", statusCol = "DS$cens", variables = c("DS$age.60"), expandDF = "EM.new", datasources = cn)
  ),
  distributional = list(
    ds.gamlss = function(cn) ds.gamlss(formula = "e3_bw ~ e3_gac_None", sigma.formula = "e3_bw ~ e3_gac_None", data = "DG", family = "NO()", centiles = TRUE, xvar = "DG$e3_gac_None", newobj = "z_scores", datasources = cn)
  ),
  imputation = list(
    ds.mice      = function(cn) ds.mice(data = "D", m = 1, seed = "NA", datasources = cn),
    ds.mdPattern = function(cn) ds.mdPattern(x = "D", datasources = cn)
  ),
  growth = list(
    ds.getWGSR       = function(cn) ds.getWGSR(sex = "DA$sex", firstPart = "DA$weight", secondPart = "DA$height", index = "wfh", newobj = "wgsr", datasources = cn),
    ds.bp_standards  = function(cn) ds.bp_standards(sex = "DA$sex", age = "DA$age", height = "DA$height", bp = "DA$muac", systolic = TRUE, newobj = "bps", datasources = cn),
    ds.igb_standards = function(cn) ds.igb_standards(gagebrth = "ga_days", val = "DA$weight", sex = "sexMF", var = "wtkg", newobj = "igb", datasources = cn)
  ),
  plot = list(
    ds.histogram   = function(cn) ds.histogram(x = "D$LAB_TSC", datasources = cn),
    ds.boxPlot     = function(cn) ds.boxPlot(x = "D$LAB_TSC", datasources = cn),
    ds.scatterPlot = function(cn) ds.scatterPlot(x = "D$LAB_TSC", y = "D$LAB_HDL", datasources = cn),
    ds.heatmapPlot = function(cn) ds.heatmapPlot(x = "D$LAB_TSC", y = "D$LAB_HDL", datasources = cn),
    ds.contourPlot = function(cn) ds.contourPlot(x = "D$LAB_TSC", y = "D$LAB_HDL", datasources = cn),
    ds.densityGrid = function(cn) ds.densityGrid(x = "D$LAB_TSC", y = "D$LAB_HDL", datasources = cn),
    ds.forestplot  = function(cn) ds.forestplot(mod = ds.glmSLMA(formula = "LAB_TSC ~ LAB_TRIG", family = "gaussian", dataName = "D", datasources = cn))
  ),
  random = list(
    ds.rNorm   = function(cn) ds.rNorm(samp.size = 1000, mean = 0, sd = 1, newobj = "rn", seed.as.integer = 27, datasources = cn),
    ds.rUnif   = function(cn) ds.rUnif(samp.size = 1000, min = 0, max = 1, newobj = "ru", seed.as.integer = 27, datasources = cn),
    ds.rPois   = function(cn) ds.rPois(samp.size = 1000, lambda = 1, newobj = "rp", seed.as.integer = 27, datasources = cn),
    ds.rBinom  = function(cn) ds.rBinom(samp.size = 1000, size = 10, prob = 0.5, newobj = "rbn", seed.as.integer = 27, datasources = cn),
    ds.setSeed = function(cn) ds.setSeed(seed.as.integer = 1234, datasources = cn)
  ),
  objects = list(
    ds.rm = function(cn) { ds.assign(toAssign = "D$LAB_TSC", newobj = "torm", datasources = cn); ds.rm(x.names = "torm", datasources = cn) }
  ),
  # DSI infrastructure (datashield.*) that hits the server. login/logout/
  # workspace_load are timed separately by session_rows().
  dsi = list(
    datashield.symbols        = function(cn) datashield.symbols(cn),
    datashield.tables         = function(cn) datashield.tables(cn),
    datashield.table_status   = function(cn) datashield.table_status(cn, table_a_ref(be)),
    datashield.pkg_check      = function(cn) datashield.pkg_check(cn, "dsBase"),
    datashield.pkg_status     = function(cn) datashield.pkg_status(cn),
    datashield.methods        = function(cn) datashield.methods(cn),
    datashield.method_status  = function(cn) datashield.method_status(cn),
    datashield.profiles       = function(cn) datashield.profiles(cn),
    datashield.sessions       = function(cn) datashield.sessions(cn),
    datashield.resources      = function(cn) datashield.resources(cn),
    datashield.resource_status = function(cn) datashield.resource_status(cn),
    datashield.workspaces     = function(cn) datashield.workspaces(cn),
    datashield.aggregate      = function(cn) datashield.aggregate(cn, "dimDS('D')"),
    datashield.assign.expr    = function(cn) datashield.assign.expr(cn, "ae2", "D$LAB_TSC * 2"),
    datashield.workspace_save = function(cn) datashield.workspace_save(cn, "benchws"),
    datashield.rm             = function(cn) { datashield.assign.expr(cn, "torm2", "D$LAB_TSC"); datashield.rm(cn, "torm2") }
  )
)

# Flatten the nested registry to a list of {op, category, fn} for one backend.
flatten_ops <- function(be) {
  nested <- ds_ops(be)
  out <- list()
  for (cat in names(nested))
    for (op in names(nested[[cat]]))
      out[[length(out) + 1]] <- list(op = op, category = cat, fn = nested[[cat]][[op]])
  out
}

# Prerequisite builders: run untimed (after reset) for ops that need a prior
# server object. Keyed by op name; ops not listed need no prep. The matrix is a
# diagonal (invertible) matrix so matrixInvert works as well as det/mult/transpose.
build_mat <- function(cn) ds.matrixDiag(x1 = 2, aim = "clientside.scalar.2.matrix",
  nrows.scalar = 4, newobj = "mat", datasources = cn)
build_glm <- function(cn) ds.glmSLMA(formula = "D$LAB_TSC~D$LAB_TRIG",
  family = "gaussian", newobj = "glm.mod", datasources = cn)
build_list <- function(cn) ds.list(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "li", datasources = cn)
build_numdf <- function(cn) ds.dataFrame(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "numdf", datasources = cn)
# igb_standards needs a gestational-age-in-days variable (the anthro `age` is
# child age in months, out of the 168-294 day INTERGROWTH range) and a sex
# variable coded Male/Female (the data codes it 1/2).
build_igb <- function(cn) {
  ds.assign(toAssign = "DA$age*0+280", newobj = "ga_days", datasources = cn)
  ds.recodeValues(var.name = "DA$sex", values2replace.vector = c("1", "2"),
                  new.values.vector = c("Male", "Female"), newobj = "sexMF", datasources = cn)
}
PREP_FOR <- list(
  ds.matrixDet = build_mat, ds.matrixDet.report = build_mat, ds.matrixInvert = build_mat,
  ds.matrixMult = build_mat, ds.matrixTranspose = build_mat, ds.matrixDiag = build_mat,
  ds.matrixDimnames = build_mat,
  ds.rowColCalc = build_numdf,
  ds.glmSummary = build_glm, ds.glmPredict = build_glm,
  ds.unList = build_list,
  ds.igb_standards = build_igb
)

# --- Session timing (login / logout / workspace_load) -----------------------
# Throwaway connections so it doesn't disturb the persistent ones. Returns rows
# tagged category "session".
session_rows <- function(be, rep) {
  ld <- login_for(logindata, be)

  n <- 0L; lt <- 0; ot <- 0; t0 <- Sys.time()
  repeat {
    s <- Sys.time(); cn <- datashield.login(ld, assign = FALSE); lt <- lt + secs_since(s)
    s <- Sys.time(); datashield.logout(cn);                       ot <- ot + secs_since(s)
    n <- n + 1L
    if (secs_since(t0) >= DURATION_SEC) break
  }

  m <- 0L; wt <- 0; t0 <- Sys.time()
  repeat {
    s <- Sys.time(); cn <- datashield.login(ld, assign = FALSE, restore = WORKSPACE); wt <- wt + secs_since(s)
    datashield.logout(cn)
    m <- m + 1L
    if (secs_since(t0) >= DURATION_SEC) break
  }

  data.frame(
    backend = be, op = c("login", "logout", "workspace_load"), category = "session",
    rep = rep, count = c(n, n, m), elapsed = c(lt, ot, wt),
    rate = c(n / lt, n / ot, m / wt)
  )
}

# --- PROBE mode: run each op once per backend, report OK/FAIL, then exit -----
# PROBE=1 Rscript bench.R  -- fast validation of every call form (no timing).
if (nzchar(Sys.getenv("PROBE"))) {
  for (be in names(conns)) {
    cn <- conns[[be]]
    ops <- flatten_ops(be)
    cat(sprintf("\n== PROBE %s (%d ops) ==\n", be, length(ops)))
    nok <- 0L
    for (o in ops) {
      reset(cn)
      use_conn(cn)
      if (!is.null(PREP_FOR[[o$op]])) try(PREP_FOR[[o$op]](cn), silent = TRUE)
      msg <- tryCatch({ o$fn(cn); "OK" }, error = function(e) paste("FAIL:", conditionMessage(e)))
      if (identical(msg, "OK")) nok <- nok + 1L
      cat(sprintf("  %-28s %s\n", o$op, msg))
    }
    cat(sprintf("  -- %s: %d/%d OK, %d FAIL --\n", be, nok, length(ops), length(ops) - nok))
  }
  for (be in names(conns)) try(datashield.logout(conns[[be]]), silent = TRUE)
  quit(save = "no")
}

# --- Build cells (each carries its identity), shuffled per repetition --------
# A cell's run(): resolve the LIVE connection -> reset workspace -> set default
# connection -> build prerequisite (untimed) -> one untimed warm-up call
# (exclude cold-start) -> timed loop.
make_cell <- function(be, op, category, rep, fn) {
  force(be); force(op); force(category); force(rep); force(fn)  # avoid lazy capture
  list(
    be = be, op = op, rep = rep,
    run = function() {
      cn <- conns[[be]]
      reset(cn)
      use_conn(cn)
      if (!is.null(PREP_FOR[[op]])) try(PREP_FOR[[op]](cn), silent = TRUE)
      try(fn(cn), silent = TRUE)           # warm-up, excluded from timing
      r <- time_op(function() fn(cn), DURATION_SEC)
      data.frame(backend = be, op = op, category = category, rep = rep, r)
    })
}

cells <- list()
for (rep in seq_len(REPS)) {
  rep_cells <- list()
  for (be in names(conns)) {
    for (o in flatten_ops(be))
      rep_cells[[length(rep_cells) + 1]] <- make_cell(be, o$op, o$category, rep, o$fn)
    local({
      be_ <- be; rep_ <- rep
      rep_cells[[length(rep_cells) + 1]] <<- list(be = be_, op = "session", rep = rep_,
        run = function() session_rows(be_, rep_))
    })
  }
  cells <- c(cells, rep_cells[sample(length(rep_cells))])   # fresh shuffle per rep
}

cat(sprintf("Running %d cells (%g s each), order reshuffled per repetition...\n",
            length(cells), DURATION_SEC))

backend_alive <- function(be)
  tryCatch({ ds.ls(datasources = conns[[be]]); TRUE }, error = function(e) FALSE)

# Heal a dropped backend: restart Opal's container (if OPAL_COMPOSE set), then
# reconnect, waiting up to ~2 min. Updates the global `conns`.
heal <- function() {
  for (be in names(conns)) {
    if (backend_alive(be)) next
    message(sprintf("  %s connection lost; healing...", be))
    if (be == "opal" && nzchar(OPAL_COMPOSE)) {
      message("  restarting Opal container (docker compose up -d)...")
      try(system2("docker", c("compose", "-f", OPAL_COMPOSE, "up", "-d"),
                  stdout = FALSE, stderr = FALSE), silent = TRUE)
    }
    newcn <- NULL
    for (k in seq_len(24)) {                  # wait up to ~2 min for it to recover
      newcn <- tryCatch(connect_be(be), error = function(e) NULL)
      if (!is.null(newcn)) break
      Sys.sleep(5)
    }
    if (!is.null(newcn)) { conns[[be]] <<- newcn; message(sprintf("  %s reconnected", be)) }
    else message(sprintf("  %s still unavailable", be))
  }
}

# Run a cell's closure, capturing result, error message, and warnings.
run_cell <- function(run) {
  warns <- character(0); err <- NA_character_
  res <- withCallingHandlers(
    tryCatch(run(), error = function(e) { err <<- conditionMessage(e); NULL }),
    warning = function(w) { warns[[length(warns) + 1L]] <<- conditionMessage(w); invokeRestart("muffleWarning") })
  if (length(warns)) {
    counts <- table(warns)
    for (m in names(counts)) message(sprintf("  warning (x%d): %s", counts[[m]], m))
  }
  list(res = res, err = err)
}

# Results written incrementally (a crash never loses completed cells); failures
# recorded to a sibling file so missing rows are explained, not silent.
COLS <- c("backend", "op", "category", "rep", "count", "elapsed", "rate")
FAIL_CSV <- file.path(dirname(OUT_CSV), sub("^rates", "failures", basename(OUT_CSV)))
dir.create(dirname(OUT_CSV), showWarnings = FALSE, recursive = TRUE)
write.csv(setNames(data.frame(lapply(COLS, function(x) character(0))), COLS), OUT_CSV, row.names = FALSE)
write.csv(data.frame(backend = character(0), op = character(0), rep = integer(0), error = character(0)),
          FAIL_CSV, row.names = FALSE)
append_res <- function(df)
  write.table(df[, COLS], OUT_CSV, sep = ",", row.names = FALSE, col.names = FALSE, append = TRUE)
log_fail <- function(be, op, rep, msg)
  write.table(data.frame(backend = be, op = op, rep = rep, error = gsub("[\r\n,]", " ", msg)),
              FAIL_CSV, sep = ",", row.names = FALSE, col.names = FALSE, append = TRUE)

# Pass-based work queue so a crash misses no measurements. Each pass runs every
# cell whose backend is currently up; a cell whose backend is DOWN is deferred
# (not the op's fault) and a genuine op failure on a live backend is logged once.
# Between passes the down backends are healed (Opal restarted), and deferred
# cells are retried next pass -- so a crashed-then-recovered backend still gets
# every (op x rep) measured. A backend down for MAX_FRUITLESS_PASSES in a row is
# given up on (its cells logged "backend unavailable") so the run can't hang.
MAX_FRUITLESS_PASSES <- 5L
HEAL_WAIT <- 20L                                    # seconds between fruitless passes
be_of <- function(x) vapply(x, function(c) c$be, character(1))

pending <- cells
total <- length(cells)
n_written <- 0L; n_failed <- 0L; done <- 0L; fruitless <- 0L
while (length(pending)) {
  down <- character(0)                              # backends found down this pass
  next_pending <- list()
  progressed <- FALSE
  for (cl in pending) {
    if (cl$be %in% down) { next_pending[[length(next_pending) + 1L]] <- cl; next }
    out <- run_cell(cl$run)
    if (!is.null(out$res)) {
      append_res(out$res); n_written <- n_written + nrow(out$res); done <- done + 1L; progressed <- TRUE
    } else if (!backend_alive(cl$be)) {             # backend down -> defer, don't blame the op
      down <- union(down, cl$be)
      next_pending[[length(next_pending) + 1L]] <- cl
    } else {                                        # genuine op failure on a live backend
      log_fail(cl$be, cl$op, cl$rep, if (is.na(out$err)) "unknown error" else out$err)
      n_failed <- n_failed + 1L; done <- done + 1L
    }
    cat(sprintf("[%d/%d]\n", done, total))
  }
  if (!length(next_pending)) break
  message(sprintf("  %d cell(s) deferred on down backend(s): %s; healing...",
                  length(next_pending), paste(unique(be_of(next_pending)), collapse = ", ")))
  heal()
  recovered <- any(vapply(unique(be_of(next_pending)), backend_alive, logical(1)))
  fruitless <- if (progressed || recovered) 0L else fruitless + 1L
  if (fruitless >= MAX_FRUITLESS_PASSES) {
    for (cl in next_pending) {
      log_fail(cl$be, cl$op, cl$rep, "backend unavailable after retries"); n_failed <- n_failed + 1L; done <- done + 1L
    }
    message("  giving up on persistently-down backend(s) after retries"); break
  }
  if (!progressed && !recovered) Sys.sleep(HEAL_WAIT)
  pending <- next_pending
}

for (be in names(conns)) try(datashield.logout(conns[[be]]), silent = TRUE)
cat(sprintf("\nWrote %d result rows -> %s\n%d failures -> %s\n",
            n_written, OUT_CSV, n_failed, FAIL_CSV))
