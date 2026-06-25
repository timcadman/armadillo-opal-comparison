# ==============================================================================
# SUITE 2 -- CLIENT speed (end-user experience). The SAME extracted primitives
# (results/primitives.csv), but timed as the client observes them: the high-level
# datashield.aggregate / datashield.assign.expr call through the DSI async poll
# loop (default 50ms poll-sleep). Directly comparable to speed_true.R. Slower per
# call, so fewer reps.
#
#   SPEED_REPS=100 ARMA_AUTH=basic Rscript speed_client.R
#
# Output: results/speed_client.csv  (backend, pid, fn, kind, rep, client_ms)
# ==============================================================================

source("bench_lib.R")
set.seed(1)
REPS <- as.integer(Sys.getenv("SPEED_REPS", "100"))
OUT  <- Sys.getenv("SPEED_CLIENT_CSV", file.path(dirname(OUT_CSV), "speed_client.csv"))

prims <- read_primitives()
conns <- connect_all()
cols  <- c("backend", "pid", "fn", "kind", "rep", "client_ms")
append_rows <- open_csv(OUT, cols)

cat(sprintf("CLIENT speed: %d primitives x %d reps x %d backend(s) -> %s\n",
            nrow(prims), REPS, length(conns), OUT))
for (be in names(conns)) {
  cn <- conns[[be]]
  cat(sprintf("\n== %s ==\n", be))
  for (i in seq_len(nrow(prims))) {
    kind <- prims$kind[i]; expr <- prims$expr[i]; fn <- prims$fn[i]
    try(run_primitive_hl(cn, kind, expr), silent = TRUE)    # warm-up (excluded)
    clm <- rep(NA_real_, REPS)
    for (r in seq_len(REPS))
      try({ s <- Sys.time(); run_primitive_hl(cn, kind, expr); clm[r] <- secs_since(s) * 1000 }, silent = TRUE)
    append_rows(data.frame(backend = be, pid = i, fn = fn, kind = kind,
                           rep = seq_len(REPS), client_ms = round(clm, 3)))
    cat(sprintf("  %-18s client %7.2f ms (median, n=%d)\n",
                fn, median(clm, na.rm = TRUE), sum(!is.na(clm))))
  }
}
for (be in names(conns)) try(datashield.logout(conns[[be]]), silent = TRUE)
cat(sprintf("\nWrote %s\n", OUT))
