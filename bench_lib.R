# ==============================================================================
# Shared helpers for the two primitive speed scripts:
#   speed_true.R    -- true server compute time (server endDate - startDate)
#   speed_client.R  -- client-observed time (high-level call, default poll-sleep)
# Both run the SAME set of single-command serverside calls extracted into
# results/primitives.csv by `CAPTURE=1 Rscript bench.R`, so the two measurements
# are directly comparable.
# ==============================================================================

source("config.R")          # loads DSI/DSOpal/DSMolgenisArmadillo + URLs/helpers
options(digits.secs = 6)

secs_since <- function(t0) as.numeric(Sys.time() - t0, units = "secs")

# Parse an ISO-8601 instant; we only ever subtract two stamps from the same
# server, so stripping the zone and parsing both as naive-UTC keeps the diff exact.
.parse_iso <- function(x) {
  if (is.null(x) || length(x) != 1 || is.na(x) || !nzchar(x)) return(as.POSIXct(NA))
  as.POSIXct(sub("([Zz]|[+-][0-9]{2}:?[0-9]{2})$", "", x),
             format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
}

# True compute time (ms) of the just-completed command on a single node `conn`.
# Read BEFORE dsFetch. Armadillo: GET /lastcommand; Opal: command-by-id.
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

# Connect to every available backend, assigning the standard datasets (D, D2, ...).
connect_all <- function() {
  ld <- build_logins()
  cs <- list()
  for (be in BACKENDS) {
    cn <- tryCatch({
      x <- datashield.login(login_for(ld, be), assign = FALSE)
      for (d in DATASETS) datashield.assign.table(x, d$symbol, ds_table_ref(be, d$table))
      x
    }, error = function(e) { message(sprintf("  skip %s (unavailable): %s", be, conditionMessage(e))); NULL })
    if (!is.null(cn)) cs[[be]] <- cn
  }
  if (!length(cs)) stop("No backends available.")
  cs
}

# Extracted single-command serverside primitives (kind, fn, expr).
read_primitives <- function() {
  csv <- file.path(dirname(OUT_CSV), "primitives.csv")
  if (!file.exists(csv))
    stop("primitives.csv not found - run `CAPTURE=1 Rscript bench.R` first.", call. = FALSE)
  read.csv(csv, stringsAsFactors = FALSE)
}

# Submit one primitive ASYNC on a single node, returning the result handle.
submit_primitive <- function(conn, kind, expr, symbol = "p_tmp") {
  if (kind == "aggregate") dsAggregate(conn, expr, async = TRUE)
  else                     dsAssignExpr(conn, symbol, expr, async = TRUE)
}

# Run one primitive via the high-level DSI call (default poll-sleep) on `conns`.
run_primitive_hl <- function(conns, kind, expr, symbol = "p_tmp") {
  if (kind == "aggregate") datashield.aggregate(conns, expr)
  else                     datashield.assign.expr(conns, symbol, expr)
}

# Incremental CSV writer: header now, rows appended as we go.
open_csv <- function(path, cols) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  write.csv(setNames(data.frame(lapply(cols, function(x) character(0))), cols), path, row.names = FALSE)
  function(df) write.table(df[, cols], path, sep = ",", row.names = FALSE, col.names = FALSE, append = TRUE)
}
