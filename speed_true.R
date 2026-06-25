# ==============================================================================
# SUITE 1 -- TRUE server speed. For each extracted single-command primitive
# (results/primitives.csv) on each backend, measure the server's own execution
# time (endDate - startDate) plus a tight-poll round trip. No 50ms poll-sleep,
# so we can afford many reps.
#
#   CAPTURE=1 ARMA_AUTH=basic Rscript bench.R     # (once) build primitives.csv
#   SPEED_REPS=1000 ARMA_AUTH=basic Rscript speed_true.R
#
# Output: results/speed_true.csv  (backend, pid, fn, kind, rep, compute_ms, roundtrip_ms)
# ==============================================================================

source("bench_lib.R")
set.seed(1)
REPS <- as.integer(Sys.getenv("SPEED_REPS", "1000"))
OUT  <- Sys.getenv("SPEED_TRUE_CSV", file.path(dirname(OUT_CSV), "speed_true.csv"))

prims <- read_primitives()
conns <- connect_all()
cols  <- c("backend", "pid", "fn", "kind", "rep", "compute_ms", "roundtrip_ms")
append_rows <- open_csv(OUT, cols)

# One low-level submit -> tight poll -> read compute -> fetch. Returns c(compute, roundtrip) ms.
time_one <- function(c1, kind, expr) {
  t0 <- Sys.time()
  res <- submit_primitive(c1, kind, expr)
  repeat { if (dsIsCompleted(res)) break; Sys.sleep(0.002) }
  cms <- command_compute_ms(c1, res)
  dsFetch(res)
  c(cms, secs_since(t0) * 1000)
}

cat(sprintf("TRUE speed: %d primitives x %d reps x %d backend(s) -> %s\n",
            nrow(prims), REPS, length(conns), OUT))
for (be in names(conns)) {
  c1 <- conns[[be]][[1]]
  cat(sprintf("\n== %s ==\n", be))
  for (i in seq_len(nrow(prims))) {
    kind <- prims$kind[i]; expr <- prims$expr[i]; fn <- prims$fn[i]
    try(time_one(c1, kind, expr), silent = TRUE)            # warm-up (excluded)
    cms <- rep(NA_real_, REPS); rts <- rep(NA_real_, REPS)
    for (r in seq_len(REPS))
      try({ m <- time_one(c1, kind, expr); cms[r] <- m[1]; rts[r] <- m[2] }, silent = TRUE)
    append_rows(data.frame(backend = be, pid = i, fn = fn, kind = kind, rep = seq_len(REPS),
                           compute_ms = round(cms, 3), roundtrip_ms = round(rts, 3)))
    cat(sprintf("  %-18s compute %6.2f | roundtrip %6.2f ms (median, n=%d)\n",
                fn, median(cms, na.rm = TRUE), median(rts, na.rm = TRUE), sum(!is.na(cms))))
  }
}
for (be in names(conns)) try(datashield.logout(conns[[be]]), silent = TRUE)
cat(sprintf("\nWrote %s\n", OUT))
