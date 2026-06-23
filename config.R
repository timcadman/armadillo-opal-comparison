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
# Auth is token-based by default: if ARMA_TOKEN is unset, arma_token() fetches one
# once via armadillo.get_token() (OAuth), OUTSIDE the timed login step. Set
# ARMA_AUTH=basic to use user/password instead (e.g. a local dev Armadillo).
ARMA_URL   <- Sys.getenv("ARMA_URL",   "http://localhost:8081")
ARMA_USER  <- Sys.getenv("ARMA_USER",  "admin")
ARMA_PASS  <- Sys.getenv("ARMA_PASS",  "admin")
ARMA_TOKEN <- Sys.getenv("ARMA_TOKEN", "")   # blank => fetched via armadillo.get_token()

# DataSHIELD compute profiles on the SAME Armadillo server/data: the default
# profile and the Rserve profile are benchmarked as two separate backends.
ARMA_PROFILE        <- Sys.getenv("ARMA_PROFILE",        "default")
ARMA_RSERVE_PROFILE <- Sys.getenv("ARMA_RSERVE_PROFILE", "rserve")

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

BACKENDS  <- c("opal", "armadillo", "armadillo_rserve")
OUT_CSV   <- file.path("results", "rates.csv")

# --- Per-backend helpers ----------------------------------------------------
table_a_ref <- function(be) if (be == "opal") OPAL_TABLE_A else ARMA_TABLE_A
table_b_ref <- function(be) if (be == "opal") OPAL_TABLE_B else ARMA_TABLE_B

# Fetch the Armadillo OAuth token once and cache it in ARMA_TOKEN. Call this
# BEFORE any timed datashield.login so the handshake is not part of the measured
# login time (build_logins() below does exactly that, at benchmark startup).
arma_token <- function() {
  if (!nzchar(ARMA_TOKEN))
    ARMA_TOKEN <<- MolgenisArmadillo::armadillo.get_token(ARMA_URL)
  ARMA_TOKEN
}

# Build a multi-server logindata object; subset per backend with login_for().
# Both Armadillo backends point at the same server/data and differ only by
# profile (default vs rserve). Auth is token-based unless ARMA_AUTH=basic.
build_logins <- function() {
  basic <- identical(tolower(Sys.getenv("ARMA_AUTH", "token")), "basic")
  tok   <- if (basic) NULL else arma_token()
  b <- DSI::newDSLoginBuilder(.silent = TRUE)
  b$append(server = "opal", url = OPAL_URL, user = OPAL_USER, password = OPAL_PASS,
           table = OPAL_TABLE_A, driver = "OpalDriver")
  append_arma <- function(server, profile) {
    if (basic) {
      b$append(server = server, url = ARMA_URL, user = ARMA_USER, password = ARMA_PASS,
               table = ARMA_TABLE_A, driver = "ArmadilloDriver", profile = profile)
    } else {
      b$append(server = server, url = ARMA_URL, token = tok,
               table = ARMA_TABLE_A, driver = "ArmadilloDriver", profile = profile)
    }
  }
  append_arma("armadillo",        ARMA_PROFILE)
  append_arma("armadillo_rserve", ARMA_RSERVE_PROFILE)
  b$build()
}

# A single-server logindata row for one backend.
login_for <- function(logindata, be) logindata[logindata$server == be, , drop = FALSE]
