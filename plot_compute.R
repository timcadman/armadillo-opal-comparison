# ==============================================================================
# Summarise the true-compute timings from COMPUTE mode (results/compute.csv).
# For each backend x single-command primitive it reports, and charts, three
# times side by side:
#   compute_ms   true server execution (endDate - startDate)
#   roundtrip_ms low-level submit -> poll(2 ms) -> fetch (~compute + network)
#   client_ms    high-level datashield.* call (default 50 ms poll) -- penalised
# The gap between compute_ms and client_ms is the client-side polling penalty.
#
#   COMPUTE=1 Rscript bench.R   # produce results/compute.csv first
#   Rscript plot_compute.R
#
# Requires ggplot2. Output: results/compute.png  (+ a console summary table)
# ==============================================================================

source("config.R")
suppressMessages(library(ggplot2))

CSV <- Sys.getenv("COMPUTE_CSV", file.path(dirname(OUT_CSV), "compute.csv"))
stopifnot(file.exists(CSV))
d <- read.csv(CSV, stringsAsFactors = FALSE)
stopifnot(nrow(d) > 0)

MEAS <- c("compute_ms", "roundtrip_ms", "client_ms")

# Median per (backend, op, measure) -- median is robust to the occasional GC/
# network spike and to the millisecond quantisation of the server timestamps.
med <- aggregate(cbind(compute_ms, roundtrip_ms, client_ms) ~ backend + op,
                 data = d, FUN = median, na.rm = TRUE, na.action = na.pass)

# --- Console summary --------------------------------------------------------
# penalty = how many times longer the client-observed time is than true compute;
# pct_waiting = share of the client-observed time that is NOT server compute.
s <- med
s$penalty     <- s$client_ms / s$compute_ms
s$pct_waiting <- 100 * (s$client_ms - s$compute_ms) / s$client_ms
s <- s[order(s$op, s$backend), ]
cat(sprintf("True compute vs client-observed (median over %d rep(s))\n\n", length(unique(d$rep))))
print(within(s, {
  compute_ms   <- round(compute_ms, 1); roundtrip_ms <- round(roundtrip_ms, 1)
  client_ms    <- round(client_ms, 1);  penalty      <- round(penalty, 1)
  pct_waiting  <- round(pct_waiting, 1)
}), row.names = FALSE)

# --- Plot -------------------------------------------------------------------
# Long format, measures ordered fastest -> slowest so the legend reads in order.
long <- reshape(med, varying = MEAS, v.names = "ms", timevar = "measure",
                times = MEAS, direction = "long")
long$measure <- factor(long$measure, levels = MEAS,
                       labels = c("server compute", "round trip (tight poll)", "client (50 ms poll)"))

PLOT <- file.path(dirname(OUT_CSV), "compute.png")
p <- ggplot(long, aes(x = backend, y = ms, fill = measure)) +
  geom_col(width = 0.7, position = position_dodge(width = 0.8)) +
  facet_wrap(~ op, scales = "free_y") +
  scale_y_continuous(labels = function(x) sprintf("%g", x)) +
  scale_fill_manual(values = c("server compute"          = "#1A9850",
                               "round trip (tight poll)"  = "#4285F4",
                               "client (50 ms poll)"      = "#D73027")) +
  labs(title = "True server compute vs client-observed time",
       subtitle = "Single-command primitives; the green-to-red gap is the DSI poll-sleep penalty",
       x = NULL, y = "milliseconds (median)", fill = NULL) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top")

ggsave(PLOT, p, width = 9, height = 5, dpi = 150)
cat(sprintf("\nWrote %s\n", PLOT))
