# ==============================================================================
# Shared configuration for the Opal-vs-Armadillo DataSHIELD benchmark.
#
# This is the ONLY file you edit to move from localhost to external servers:
# change the URLs / credentials below. Everything else is derived.
# ==============================================================================

suppressMessages({
  library(DSI)
  library(DSOpal)
  library(DSMolgenisArmadillo)
})

# --- Opal -------------------------------------------------------------------
OPAL_URL  <- Sys.getenv("OPAL_URL",  "http://localhost:8080")
OPAL_USER <- Sys.getenv("OPAL_USER", "administrator")
OPAL_PASS <- Sys.getenv("OPAL_PASS", "datashield_test&")

# --- Armadillo --------------------------------------------------------------
# Local dev Armadillo uses basic auth (admin/admin). For an OAuth-protected
# server, set ARMA_TOKEN (fetched once, OUTSIDE the timed login step) and the
# login builder will use the token instead of user/password.
ARMA_URL   <- Sys.getenv("ARMA_URL",   "http://localhost:8081")
ARMA_USER  <- Sys.getenv("ARMA_USER",  "admin")
ARMA_PASS  <- Sys.getenv("ARMA_PASS",  "admin")
ARMA_TOKEN <- Sys.getenv("ARMA_TOKEN", "")   # blank => basic auth (local)

# --- Data -------------------------------------------------------------------
PROJECT <- "perf"
FOLDER  <- "bench"          # Armadillo folder (Opal has no folders)
TABLE_A <- "tableA"
TABLE_B <- "tableB"
N_ROWS  <- as.integer(Sys.getenv("N_ROWS", "100000"))

# How each backend names a table reference passed to datashield.assign.table().
OPAL_TABLE_A <- paste0(PROJECT, ".", TABLE_A)
OPAL_TABLE_B <- paste0(PROJECT, ".", TABLE_B)
ARMA_TABLE_A <- paste(PROJECT, FOLDER, TABLE_A, sep = "/")
ARMA_TABLE_B <- paste(PROJECT, FOLDER, TABLE_B, sep = "/")

# --- Benchmark settings -----------------------------------------------------
DURATION_SEC <- as.numeric(Sys.getenv("DURATION_SEC", "20"))  # seconds per cell
REPS         <- as.integer(Sys.getenv("REPS", "10"))          # repeats per cell
SEED         <- as.integer(Sys.getenv("SEED", "1"))           # shuffle seed
WORKSPACE    <- "perf_ws"                                     # saved in setup.R

BACKENDS  <- c("opal", "armadillo")
OUT_CSV   <- file.path("results", "rates.csv")

# --- Per-backend helpers ----------------------------------------------------
table_a_ref <- function(be) if (be == "opal") OPAL_TABLE_A else ARMA_TABLE_A
table_b_ref <- function(be) if (be == "opal") OPAL_TABLE_B else ARMA_TABLE_B

# Build a multi-server logindata object; subset per backend with login_for().
build_logins <- function() {
  b <- DSI::newDSLoginBuilder(.silent = TRUE)
  b$append(server = "opal", url = OPAL_URL, user = OPAL_USER, password = OPAL_PASS,
           table = OPAL_TABLE_A, driver = "OpalDriver")
  if (nzchar(ARMA_TOKEN)) {
    b$append(server = "armadillo", url = ARMA_URL, token = ARMA_TOKEN,
             table = ARMA_TABLE_A, driver = "ArmadilloDriver")
  } else {
    b$append(server = "armadillo", url = ARMA_URL, user = ARMA_USER, password = ARMA_PASS,
             table = ARMA_TABLE_A, driver = "ArmadilloDriver")
  }
  b$build()
}

# A single-server logindata row for one backend.
login_for <- function(logindata, be) logindata[logindata$server == be, , drop = FALSE]
