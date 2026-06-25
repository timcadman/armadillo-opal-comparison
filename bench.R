# ==============================================================================
# The benchmark. Two scenarios over the analysis-driven core function set
# (docs/core-functions.md):
#
#   SCENARIO 1 -- primitives, true server compute time (single-command ops):
#     COMPUTE=1 Rscript bench.R                 # -> results/compute.csv
#
#   SCENARIO 2 -- full ds.*/datashield.* function calls, ops/sec, with the DSI
#     poll-sleep lowered so the client-side wait doesn't dominate fast ops:
#     POLL_SLEEP0=0.002 Rscript bench.R         # -> results/rates.csv
#
# Helpers:
#   DURATION_SEC=2 REPS=1 POLL_SLEEP0=0.002 Rscript bench.R   # quick smoke run
#   PROBE=1 Rscript bench.R                    # validate every call form, no timing
#
# Scenario 2: each (backend x op x rep) cell runs the op for DURATION_SEC,
# counting completed calls; reps are independent shuffled blocks. Results are
# written incrementally to results/rates.csv (failures to results/failures.csv).
# A dropped backend is healed (Opal auto-restarted if OPAL_COMPOSE is set) and
# retried; one that cannot be healed is skipped and re-probed next repetition.
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

# Cached discordant 2-session connection per backend, built lazily on first use.
# Only ds.dataFrameFill needs it (it harmonises studies with disagreeing columns).
.disc_cache <- new.env(parent = emptyenv())
disc_conn <- function(be) {
  if (is.null(.disc_cache[[be]]))
    .disc_cache[[be]] <- datashield.login(build_discordant_login(be), assign = TRUE, symbol = "D")
  .disc_cache[[be]]
}

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
    ds.summary      = function(cn) ds.summary(x = "D$LAB_TSC", datasources = cn)
  ),
  correlation = list(
    ds.cor = function(cn) ds.cor(x = "D$LAB_TSC", y = "D$LAB_HDL", type = "combine", datasources = cn)
  ),
  metadata = list(
    ds.dim      = function(cn) ds.dim(x = "D", type = "combine", datasources = cn),
    ds.length   = function(cn) ds.length(x = "D$LAB_TSC", type = "combine", datasources = cn),
    ds.colnames = function(cn) ds.colnames(x = "D", datasources = cn),
    ds.class    = function(cn) ds.class(x = "D$LAB_TSC", datasources = cn),
    ds.exists   = function(cn) ds.exists(x = "D", datasources = cn),
    ds.numNA    = function(cn) ds.numNA(x = "D$LAB_HDL", datasources = cn),
    ds.levels   = function(cn) ds.levels(x = "D$GENDER", datasources = cn),
    ds.ls       = function(cn) ds.ls(datasources = cn)
  ),
  coercion = list(
    ds.asInteger    = function(cn) ds.asInteger(x.name = "D$GENDER", newobj = "ai", datasources = cn),
    ds.asCharacter  = function(cn) ds.asCharacter(x.name = "D$GENDER", newobj = "ac", datasources = cn),
    ds.asFactor     = function(cn) ds.asFactor(input.var.name = "D$DIS_CVA", newobj.name = "af", datasources = cn),
    ds.asDataMatrix = function(cn) ds.asDataMatrix(x.name = "D$GENDER", newobj = "adm", datasources = cn)
  ),
  transform = list(
    ds.assign = function(cn) ds.assign(toAssign = "D$LAB_TSC*2", newobj = "ao", datasources = cn),
    ds.make   = function(cn) ds.make(toAssign = "D$LAB_TSC*2", newobj = "md", datasources = cn),
    ds.Boole  = function(cn) ds.Boole(V1 = "D$LAB_TSC", V2 = "D$LAB_TRIG", Boolean.operator = "==", newobj = "bo", datasources = cn)
  ),
  recode = list(
    ds.recodeValues   = function(cn) ds.recodeValues(var.name = "D$DIS_CVA", values2replace.vector = c(0, 1), new.values.vector = c(10, 20), newobj = "rv", datasources = cn),
    ds.recodeLevels   = function(cn) ds.recodeLevels(x = "D$GENDER", newCategories = c("g0", "g1"), newobj = "rl", datasources = cn),
    ds.changeRefGroup = function(cn) ds.changeRefGroup(x = "D$GENDER", ref = "1", newobj = "crg", datasources = cn)
  ),
  vector = list(
    ds.rep       = function(cn) ds.rep(x1 = 4, times = 6, length.out = NA, each = 1, source.x1 = "clientside", source.times = "c", source.length.out = NULL, source.each = "c", x1.includes.characters = FALSE, newobj = "rep1", datasources = cn),
    ds.replaceNA = function(cn) ds.replaceNA(x = "D$LAB_HDL", forNA = list(0), newobj = "rna", datasources = cn)
  ),
  dataframe = list(
    ds.dataFrameSubset = function(cn) ds.dataFrameSubset(df.name = "D", V1.name = "D$LAB_TSC", V2.name = "D$LAB_HDL", Boolean.operator = "!=", newobj = "sub_row", datasources = cn),
    ds.dataFrame       = function(cn) ds.dataFrame(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "df2", datasources = cn),
    ds.dataFrameFill   = function(cn) ds.dataFrameFill(df.name = "D", newobj = "filled", datasources = disc_conn(be)),
    ds.cbind           = function(cn) ds.cbind(x = c("D$LAB_TSC", "D$LAB_HDL"), newobj = "cb", datasources = cn),
    ds.merge           = function(cn) ds.merge(x.name = "D", y.name = "D2", by.x.names = "key", by.y.names = "key", newobj = "mg", datasources = cn)
  ),
  reshape = list(
    ds.reShape = function(cn) ds.reShape(data.name = "DS", v.names = "age.60", timevar.name = "time.id", idvar.name = "id", direction = "wide", newobj = "rsh", datasources = cn)
  ),
  tabulation = list(
    ds.table = function(cn) ds.table(rvar = "D$GENDER", cvar = "D$DIS_CVA", datasources = cn)
  ),
  glm = list(
    ds.glm     = function(cn) ds.glm(formula = "LAB_TSC ~ LAB_TRIG", data = "D", family = "gaussian", datasources = cn),
    ds.glmSLMA = function(cn) ds.glmSLMA(formula = "LAB_TSC ~ LAB_TRIG", family = "gaussian", dataName = "D", newobj = "glmslma", datasources = cn)
  ),
  `mixed-model` = list(
    ds.lmerSLMA = function(cn) ds.lmerSLMA(formula = "incid_rate ~ trtGrp + Male + (1|idDoctor)", dataName = "DC", datasources = cn)
  ),
  objects = list(
    ds.rm = function(cn) { ds.assign(toAssign = "D$LAB_TSC", newobj = "torm", datasources = cn); ds.rm(x.names = "torm", datasources = cn) }
  ),
  # DSI infrastructure (datashield.*) that hits the server. login/logout/
  # workspace_load are timed separately by session_rows().
  dsi = list(
    datashield.tables         = function(cn) datashield.tables(cn),
    datashield.pkg_status     = function(cn) datashield.pkg_status(cn),
    datashield.profiles       = function(cn) datashield.profiles(cn),
    datashield.workspaces     = function(cn) datashield.workspaces(cn),
    datashield.aggregate      = function(cn) datashield.aggregate(cn, "dimDS('D')"),
    datashield.assign.expr    = function(cn) datashield.assign.expr(cn, "ae2", "D$LAB_TSC * 2"),
    datashield.workspace_save = function(cn) datashield.workspace_save(cn, "benchws")
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
# server object. Keyed by op name; ops not listed need no prep. The current core
# function set has no such ops, so this is empty (kept so make_cell can look up).
PREP_FOR <- list()

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

# --- CAPTURE mode: dump the serverside calls each op issues -------------------
# Every op resolves to one or more datashield.aggregate / datashield.assign.expr
# calls; each is a single-command primitive. Tracing them lets the primitive set
# be derived from real usage rather than hand-picked.
#   CAPTURE=1 Rscript bench.R
if (nzchar(Sys.getenv("CAPTURE"))) {
  CAP <- new.env(parent = emptyenv()); CAP$list <- list()
  rec <- function(kind, e)
    CAP$list[[length(CAP$list) + 1L]] <-
      c(kind, if (is.character(e)) e else paste(deparse(e), collapse = " "))
  assign("rec", rec, envir = globalenv()); assign("CAP", CAP, envir = globalenv())
  suppressMessages({
    trace("datashield.aggregate",   tracer = quote(.GlobalEnv$rec("aggregate", expr)), print = FALSE, where = asNamespace("DSI"))
    trace("datashield.assign.expr", tracer = quote(.GlobalEnv$rec("assign",    expr)), print = FALSE, where = asNamespace("DSI"))
  })
  # Capture/validate on a stable backend (Opal is OOM-prone); the serverside
  # call expressions are backend-independent.
  be <- if ("armadillo" %in% names(conns)) "armadillo" else names(conns)[1]
  cn <- conns[[be]]; use_conn(cn)
  calls <- list()                                   # distinct (kind, expr)
  for (o in flatten_ops(be)) {
    reset(cn)
    CAP$list <- list()
    suppressWarnings(suppressMessages(try(o$fn(cn), silent = TRUE)))
    for (cl in CAP$list) {
      key <- paste0(cl[1], "\t", cl[2])
      if (is.null(calls[[key]])) calls[[key]] <- cl
    }
  }
  # Drop pure plumbing (existence / message checks) -- not real computations.
  is_plumbing <- function(expr) grepl("^(testObjExistsDS|messageDS|exists)\\(", expr)
  # Validate each call standalone on a freshly reset connection; keep those that
  # run without error (this drops calls referencing mid-op intermediate objects).
  rows <- list()
  for (cl in calls) {
    kind <- cl[1]; expr <- cl[2]
    if (is_plumbing(expr)) next
    reset(cn)
    ok <- tryCatch({
      if (kind == "aggregate") datashield.aggregate(cn, expr)
      else datashield.assign.expr(cn, "p_tmp", expr)
      TRUE
    }, error = function(e) FALSE)
    fn <- sub("\\(.*$", "", expr)
    cat(sprintf("%-9s %-22s %s\n", kind, fn, if (ok) "OK" else "skip (not standalone)"))
    if (ok) rows[[length(rows) + 1L]] <- data.frame(kind = kind, fn = fn, expr = expr, stringsAsFactors = FALSE)
  }
  out <- do.call(rbind, rows)
  prim_csv <- file.path(dirname(OUT_CSV), "primitives.csv")
  dir.create(dirname(prim_csv), showWarnings = FALSE, recursive = TRUE)
  write.csv(out, prim_csv, row.names = FALSE)
  cat(sprintf("\n-- %d standalone single-command primitives -> %s --\n", nrow(out), prim_csv))
  for (b in names(conns)) try(datashield.logout(conns[[b]]), silent = TRUE)
  quit(save = "no")
}

# --- COMPUTE mode: true server compute time of single-command primitives -----
# The throughput numbers above are client wall-clock and include the DSI async
# poll-sleep (default 50 ms), which dominates fast ops. Each server records true
# per-command execution timestamps; for ops that map to EXACTLY ONE server
# command we read them back and report compute_ms = endDate - startDate.
#   COMPUTE=1 Rscript bench.R   ->  results/compute.csv
# Armadillo retains only the LAST command (GET /lastcommand), so this is valid
# only for single-command primitives; Opal exposes the command by id. The
# ISO-8601 startDate/endDate fields were verified from each server's source.
# Columns: backend, op, rep, compute_ms, roundtrip_ms, client_ms
#   compute_ms   server endDate - startDate (true execution time)
#   roundtrip_ms low-level submit->poll(2 ms)->fetch wall-clock (~compute + network)
#   client_ms    high-level datashield.* call (default 50 ms poll) -- the penalised number

# Parse an ISO-8601 instant ("...Thh:mm:ss.SSSZ", or with a +HH:MM offset). We
# only ever subtract two stamps from the SAME server, so stripping the zone and
# parsing both as naive-UTC leaves the difference exact regardless of its zone.
.parse_iso <- function(x) {
  if (is.null(x) || length(x) != 1 || is.na(x) || !nzchar(x)) return(as.POSIXct(NA))
  as.POSIXct(sub("([Zz]|[+-][0-9]{2}:?[0-9]{2})$", "", x),
             format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
}

# True compute time (ms) of the just-completed command on a single node `conn`.
# Read BEFORE dsFetch. Armadillo: GET /lastcommand DTO; Opal: command-by-id.
command_compute_ms <- function(conn, res) tryCatch({
  if (methods::is(conn, "ArmadilloConnection")) {
    r <- httr::GET(handle = conn@handle, path = "/lastcommand",
                   config = httr::add_headers(DSMolgenisArmadillo:::.get_auth_header(conn)))
    cmd <- httr::content(r)
  } else if (methods::is(conn, "OpalConnection")) {
    cmd <- DSOpal:::.datashield.command(conn@opal, res@rval$rid)
  } else stop("unsupported backend connection: ", paste(class(conn), collapse = "/"))
  d <- as.numeric(.parse_iso(cmd$endDate) - .parse_iso(cmd$startDate), units = "secs") * 1000
  if (length(d) == 1 && !is.na(d)) d else NA_real_
}, error = function(e) NA_real_)

# Single-command primitives: a low-level async submit (returns a result handle so
# the command record is reachable) and the matching high-level call. Call forms
# match proven ops in the registry above.
compute_primitives <- function(be) {
  agg <- function(name, expr) list(op = name,
    submit = function(c1) dsAggregate(c1, expr, async = TRUE),
    hl     = function(cn) datashield.aggregate(cn, expr))
  asn <- function(name, sym, expr) list(op = name,
    submit = function(c1) dsAssignExpr(c1, sym, expr, async = TRUE),
    hl     = function(cn) datashield.assign.expr(cn, sym, expr))
  # Max testable subset of the core set: each is exactly ONE server command and
  # hand-callable. Aggregates wrap ds.dim/numNA/quantileMean/length/class/colnames;
  # the arithmetic assign wraps ds.assign/make; assign.table is datashield.assign.table.
  list(
    agg("dimDS",          "dimDS('D')"),
    agg("lengthDS",       "lengthDS('D$LAB_TSC')"),
    agg("classDS",        "classDS('D$LAB_TSC')"),
    agg("colnamesDS",     "colnamesDS('D')"),
    agg("numNaDS",        "numNaDS('D$LAB_HDL')"),
    agg("quantileMeanDS", "quantileMeanDS('D$LAB_HDL')"),
    asn("assign.expr",    "ae_c", "D$LAB_TSC * 2"),
    list(op = "assign.table",
         submit = function(c1) dsAssignTable(c1, "scratch_c", table_a_ref(be),
                                             NULL, FALSE, NULL, NULL, async = TRUE),
         hl     = function(cn) datashield.assign.table(cn, "scratch_c", table_a_ref(be)))
  )
}

if (nzchar(Sys.getenv("COMPUTE"))) {
  creps   <- as.integer(Sys.getenv("COMPUTE_REPS", as.character(REPS)))
  out_csv <- Sys.getenv("COMPUTE_CSV", file.path(dirname(OUT_CSV), "compute.csv"))
  ccols   <- c("backend", "op", "rep", "compute_ms", "roundtrip_ms", "client_ms")
  dir.create(dirname(out_csv), showWarnings = FALSE, recursive = TRUE)
  write.csv(setNames(data.frame(lapply(ccols, function(x) numeric(0))), ccols),
            out_csv, row.names = FALSE)
  append_c <- function(df)
    write.table(df[, ccols], out_csv, sep = ",", row.names = FALSE,
                col.names = FALSE, append = TRUE)

  cat(sprintf("COMPUTE: %d reps/primitive, true server compute time -> %s\n", creps, out_csv))
  for (be in names(conns)) {
    cn <- conns[[be]]; c1 <- cn[[1]]
    use_conn(cn)
    cat(sprintf("\n== COMPUTE %s ==\n", be))
    for (p in compute_primitives(be)) {
      reset(cn)
      try(p$hl(cn), silent = TRUE)                 # warm-up (excluded)
      for (rep in seq_len(creps)) {
        cms <- NA_real_; rt <- NA_real_; clm <- NA_real_
        try({
          t0  <- Sys.time()
          res <- p$submit(c1)
          repeat { if (dsIsCompleted(res)) break; Sys.sleep(0.002) }
          cms <- command_compute_ms(c1, res)        # read BEFORE fetch
          dsFetch(res)
          rt  <- secs_since(t0) * 1000
        }, silent = TRUE)
        s <- Sys.time(); try(p$hl(cn), silent = TRUE); clm <- secs_since(s) * 1000
        append_c(data.frame(backend = be, op = p$op, rep = rep,
                            compute_ms = cms, roundtrip_ms = rt, client_ms = clm))
      }
      sub <- read.csv(out_csv)
      sub <- sub[sub$backend == be & sub$op == p$op, ]
      cat(sprintf("  %-13s compute %6.1f | roundtrip %6.1f | client %6.1f  ms (median, n=%d)\n",
                  p$op, median(sub$compute_ms, na.rm = TRUE),
                  median(sub$roundtrip_ms, na.rm = TRUE),
                  median(sub$client_ms, na.rm = TRUE), nrow(sub)))
    }
  }
  for (be in names(conns)) try(datashield.logout(conns[[be]]), silent = TRUE)
  cat(sprintf("\nWrote compute timings -> %s\n", out_csv))
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
