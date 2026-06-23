# ==============================================================================
# The benchmark. Measures operations/second for each DataSHIELD function on each
# backend, plus the speed of login / logout / workspace-load.
#
#   Rscript bench.R
#   DURATION_SEC=2 REPS=1 Rscript bench.R     # quick smoke run
#
# Each (backend x op x rep) cell runs for DURATION_SEC, counting completed ops.
# All cells are shuffled into a single random order (SEED) for reliability.
# Output: results/rates.csv  ->  backend, op, rep, count, elapsed, rate
# ==============================================================================

source("config.R")
suppressMessages(library(dsBaseClient))
set.seed(SEED)

secs_since <- function(t0) as.numeric(Sys.time() - t0, units = "secs")

# Run `op` repeatedly until DURATION_SEC elapses; return count/elapsed/rate.
time_op <- function(op, secs) {
  n <- 0L
  t0 <- Sys.time()
  repeat {
    op()
    n <- n + 1L
    if (secs_since(t0) >= secs) break
  }
  el <- secs_since(t0)
  data.frame(count = n, elapsed = el, rate = n / el)
}

# --- Persistent connections + server-side symbols (D, D2) -------------------
logindata <- build_logins()
conns <- list()
for (be in BACKENDS) {
  cat(sprintf("Connecting + assigning tables on %s...\n", be))
  cn <- datashield.login(login_for(logindata, be), assign = FALSE)
  datashield.assign.table(cn, "D",  table_a_ref(be))
  datashield.assign.table(cn, "D2", table_b_ref(be))
  conns[[be]] <- cn
}

# --- One closure per target ds.* op, bound to a backend's connection --------
ds_ops <- function(be) {
  cn <- conns[[be]]
  list(
    datashield.assign.table = function() datashield.assign.table(cn, "scratch", table_a_ref(be)),
    ds.dataFrameSubset_row = function() ds.dataFrameSubset(df.name = "D", V1.name = "D$num1", V2.name = "D$num4", Boolean.operator = ">", newobj = "sub_row", datasources = cn),
    ds.dataFrameSubset_col = function() ds.dataFrameSubset(df.name = "D", V1.name = "D$num1", V2.name = "D$num1", Boolean.operator = ">=", keep.cols = c(1, 2, 3), newobj = "sub_col", datasources = cn),
    ds.Boole  = function() ds.Boole(V1 = "D$num1", V2 = "0", Boolean.operator = ">", newobj = "bo", datasources = cn),
    ds.assign = function() ds.assign(toAssign = "D$num1*2", newobj = "ao", datasources = cn),
    ds.mean   = function() ds.mean(x = "D$num1", datasources = cn),
    ds.table  = function() ds.table(rvar = "D$fac1", cvar = "D$fac2", datasources = cn),
    ds.glm    = function() ds.glm(formula = "bin_outcome ~ num1 + int1", data = "D", family = "binomial", datasources = cn),
    ds.glmSLMA = function() ds.glmSLMA(formula = "bin_outcome ~ num1 + int1", family = "binomial", dataName = "D", datasources = cn),
    ds.merge  = function() ds.merge(x.name = "D", y.name = "D2", by.x.names = "key", by.y.names = "key", newobj = "mg", datasources = cn)
  )
}

# Server-side object each op leaves behind (ops not listed are aggregates that
# create nothing). Removed between cells so the persistent session doesn't
# accumulate large objects over the run. NA => nothing to clear.
NEWOBJ <- c(
  datashield.assign.table = "scratch",
  ds.dataFrameSubset_row  = "sub_row",
  ds.dataFrameSubset_col  = "sub_col",
  ds.Boole                = "bo",
  ds.assign               = "ao",
  ds.glmSLMA              = "new.glm.obj",
  ds.merge                = "mg"
)

# --- Session timing (login / logout / workspace_load) -----------------------
# Uses throwaway connections so it doesn't disturb the persistent ones. Login
# and logout are timed separately within one duration window; workspace_load is
# its own window (timed login-with-restore, untimed logout cleanup).
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
    backend = be, rep = rep,
    op    = c("login", "logout", "workspace_load"),
    count = c(n, n, m),
    elapsed = c(lt, ot, wt),
    rate  = c(n / lt, n / ot, m / wt)
  )
}

# --- Build every cell, then shuffle into one random order -------------------
cells <- list()
add <- function(f) cells[[length(cells) + 1]] <<- f

for (rep in seq_len(REPS)) {
  for (be in BACKENDS) {
    ops <- ds_ops(be)
    for (fn in names(ops)) {
      local({
        be_ <- be; fn_ <- fn; rep_ <- rep; op_ <- ops[[fn]]
        add(function() {
          r <- time_op(op_, DURATION_SEC)
          obj <- unname(NEWOBJ[fn_])   # NA if this op leaves no server object
          if (!is.na(obj)) try(ds.rm(x.names = obj, datasources = conns[[be_]]), silent = TRUE)
          data.frame(backend = be_, op = fn_, rep = rep_, r)
        })
      })
    }
    local({
      be_ <- be; rep_ <- rep
      add(function() session_rows(be_, rep_))
    })
  }
}

ord <- sample(length(cells))
cat(sprintf("Running %d cells (%g s each)...\n", length(cells), DURATION_SEC))

results <- list()
for (i in seq_along(ord)) {
  warns <- character(0)
  res <- withCallingHandlers(
    tryCatch(cells[[ord[i]]](), error = function(e) {
      message(sprintf("  cell %d failed: %s", i, conditionMessage(e))); NULL
    }),
    warning = function(w) {
      warns[[length(warns) + 1L]] <<- conditionMessage(w)
      invokeRestart("muffleWarning")
    }
  )
  if (length(warns)) {
    counts <- table(warns)
    for (msg in names(counts))
      message(sprintf("  cell %d warning (x%d): %s", i, counts[[msg]], msg))
  }
  if (!is.null(res)) results[[length(results) + 1]] <- res
  cat(sprintf("[%d/%d]\n", i, length(cells)))
}

for (be in BACKENDS) try(datashield.logout(conns[[be]]), silent = TRUE)

out <- do.call(rbind, results)
out <- out[, c("backend", "op", "rep", "count", "elapsed", "rate")]
dir.create(dirname(OUT_CSV), showWarnings = FALSE, recursive = TRUE)
write.csv(out, OUT_CSV, row.names = FALSE)
cat(sprintf("\nWrote %d rows -> %s\n", nrow(out), OUT_CSV))
