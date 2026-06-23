# ==============================================================================
# One-time setup: generate synthetic data, upload it to BOTH backends, and save
# a DataSHIELD workspace on each (so the benchmark can time workspace loading).
#
#   Rscript setup.R
#
# Requires both servers running (see start_servers.sh). Idempotent: tables and
# workspaces that already exist are left alone (set FORCE=1 to overwrite tables).
# ==============================================================================

source("config.R")
suppressMessages({
  library(opalr)
  library(MolgenisArmadillo)
  library(tibble)
})

force <- nzchar(Sys.getenv("FORCE"))

# --- 1. Synthetic data ------------------------------------------------------
# tableA: `id` (entity identifier) + `key` (join key) + 9 mixed-type variables.
# tableB: `id` + `key` + 3 variables. `key` is a normal column on BOTH backends
# (Opal hides the `id` identifier from the assigned data frame), so ds.subset and
# ds.merge can reference / join on it identically on Opal and Armadillo.
set.seed(42)
make_tables <- function(n) {
  a <- data.frame(
    id          = seq_len(n),
    key         = seq_len(n),
    num1        = rnorm(n),
    num2        = rnorm(n, mean = 10, sd = 3),
    num3        = runif(n),
    num4        = rnorm(n, mean = -5, sd = 2),
    int1        = sample(1:100, n, replace = TRUE),
    int2        = sample(1:5,   n, replace = TRUE),
    fac1        = factor(sample(c("a", "b", "c"), n, replace = TRUE)),
    fac2        = factor(sample(c("x", "y"),      n, replace = TRUE)),
    bin_outcome = sample(0:1, n, replace = TRUE)
  )
  b <- data.frame(
    id = seq_len(n),
    key = seq_len(n),
    b1 = rnorm(n),
    b2 = factor(sample(letters[1:4], n, replace = TRUE)),
    b3 = runif(n, 0, 100)
  )
  list(a = a, b = b)
}

cat(sprintf("Generating synthetic data (%d rows)...\n", N_ROWS))
dat <- make_tables(N_ROWS)

# --- 2. Upload to Opal ------------------------------------------------------
upload_opal <- function(a, b) {
  cat("\n== Opal ==\n")
  o <- opal.login(OPAL_USER, OPAL_PASS, url = OPAL_URL)
  on.exit(opal.logout(o), add = TRUE)

  if (!opal.project_exists(o, PROJECT)) {
    dbs <- opal.projects_databases(o)
    db  <- if (is.data.frame(dbs)) dbs$name[1] else dbs[[1]]
    if (is.null(db) || is.na(db)) stop("No Opal data database available to host project '", PROJECT, "'.")
    cat(sprintf("Creating project '%s' on database '%s'\n", PROJECT, db))
    opal.project_create(o, PROJECT, database = db)
  }

  save_one <- function(df, tbl) {
    if (!force && opal.table_exists(o, PROJECT, tbl)) {
      cat(sprintf("skip (exists): %s.%s\n", PROJECT, tbl)); return(invisible())
    }
    opal.table_save(o, as_tibble(df), PROJECT, tbl, overwrite = TRUE, force = TRUE, id.name = "id")
    cat(sprintf("uploaded: %s.%s\n", PROJECT, tbl))
  }
  save_one(a, TABLE_A)
  save_one(b, TABLE_B)
}

# --- 3. Upload to Armadillo -------------------------------------------------
upload_arma <- function(a, b) {
  cat("\n== Armadillo ==\n")
  armadillo.login_basic(ARMA_URL, ARMA_USER, ARMA_PASS)
  if (!(PROJECT %in% armadillo.list_projects())) {
    cat(sprintf("Creating project '%s'\n", PROJECT))
    armadillo.create_project(PROJECT)
  }
  existing <- tryCatch(armadillo.list_tables(PROJECT), error = function(e) character(0))
  save_one <- function(df, tbl) {
    exists_tbl <- any(grepl(paste0(FOLDER, "/", tbl, "$"), existing))
    if (exists_tbl && !force) {
      cat(sprintf("skip (exists): %s/%s/%s\n", PROJECT, FOLDER, tbl)); return(invisible())
    }
    if (exists_tbl) armadillo.delete_table(PROJECT, FOLDER, tbl)   # force: overwrite
    armadillo.upload_table(PROJECT, FOLDER, df, tbl)
    cat(sprintf("uploaded: %s/%s/%s\n", PROJECT, FOLDER, tbl))
  }
  save_one(a, TABLE_A)
  save_one(b, TABLE_B)
}

upload_opal(dat$a, dat$b)
upload_arma(dat$a, dat$b)

# --- 4. Save a DataSHIELD workspace per backend -----------------------------
# Logs in (assigning tableA to D), saves the session as WORKSPACE, logs out.
# datashield.login(restore = WORKSPACE) in the benchmark then has data to load.
save_workspace <- function(be) {
  cat(sprintf("\n== Workspace (%s) ==\n", be))
  ld <- login_for(build_logins(), be)
  cn <- datashield.login(ld, assign = FALSE)
  datashield.assign.table(cn, "D", table_a_ref(be))
  datashield.workspace_save(cn, WORKSPACE)
  datashield.logout(cn)
  cat(sprintf("saved workspace '%s' on %s\n", WORKSPACE, be))
}
for (be in BACKENDS) save_workspace(be)

cat("\nSetup complete.\n")
