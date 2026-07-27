#!/usr/bin/env Rscript
# =============================================================================
# eda_lasso_input.R
# -----------------------------------------------------------------------------
# Reproducible exploratory data analysis (EDA) for the California-Florida
# homelessness LASSO model input workbook.
#
# This script performs DESCRIPTIVE exploratory analysis only. It does NOT fit
# LASSO models, does NOT impute missing values, and does NOT delete or winsorize
# outliers. All relationships are reported as associations; no causal claim is
# made anywhere in the outputs.
#
# Usage:
#   Rscript eda_lasso_input.R [--input <path.xlsx>] [--version <label>]
#                             [--sheet <sheet name>] [--outdir <dir>]
#
# Defaults:
#   --input    outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx  (the v1 workbook)
#   --version  inferred from the input filename ("v2" if it contains "v2",
#              otherwise "v1")
#   --sheet    "LASSO Model Data"  (falls back to the first sheet if absent)
#   --outdir   outputs/eda_<version>/
#
# The output directory is versioned so development runs against the v1 workbook
# write to outputs/eda_v1/ and never touch outputs/eda_v2/. Running the script
# against CA_FL_LASSO_MODEL_INPUT_v2.xlsx (built by another session) produces the
# final outputs/eda_v2/ deliverable. Every plot title and the findings report
# are stamped with the version label so v1 development outputs are never
# mistaken for final results.
# =============================================================================

.libPaths(c("_r_libs", .libPaths()))

suppressWarnings(suppressMessages({
  library(openxlsx)
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(scales)
}))

set.seed(20260724)  # reproducibility for any jitter

# ------------------------------------------------------------------ arguments
parse_args <- function(args) {
  out <- list(input = NULL, version = NULL, sheet = NULL, outdir = NULL)
  i <- 1
  while (i <= length(args)) {
    key <- args[[i]]
    val <- if (i + 1 <= length(args)) args[[i + 1]] else NA
    if (key == "--input")   { out$input   <- val; i <- i + 2; next }
    if (key == "--version") { out$version <- val; i <- i + 2; next }
    if (key == "--sheet")   { out$sheet   <- val; i <- i + 2; next }
    if (key == "--outdir")  { out$outdir  <- val; i <- i + 2; next }
    i <- i + 1
  }
  out
}

args <- parse_args(commandArgs(trailingOnly = TRUE))

INPUT_PATH <- if (!is.null(args$input)) args$input else
  "outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx"

if (!file.exists(INPUT_PATH)) {
  stop(sprintf(paste0(
    "Input workbook not found: %s\n",
    "If you intended to run against v2, that workbook is being built by ",
    "another session and may not exist yet."), INPUT_PATH))
}

VERSION <- if (!is.null(args$version)) args$version else
  if (grepl("v2", basename(INPUT_PATH), ignore.case = TRUE)) "v2" else "v1"

OUTDIR <- if (!is.null(args$outdir)) args$outdir else
  file.path("outputs", paste0("eda_", VERSION))

SHEET <- if (!is.null(args$sheet)) args$sheet else "LASSO Model Data"

dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)
plot_dir  <- file.path(OUTDIR, "plots")
table_dir <- file.path(OUTDIR, "tables")
dir.create(plot_dir,  showWarnings = FALSE, recursive = TRUE)
dir.create(table_dir, showWarnings = FALSE, recursive = TRUE)

vlab  <- toupper(VERSION)
stamp <- function(title) sprintf("%s  [%s]", title, vlab)
is_dev <- VERSION != "v2"

message(sprintf("EDA on %s (version=%s) -> %s", INPUT_PATH, VERSION, OUTDIR))

# ------------------------------------------------------------------ read data
sheets <- getSheetNames(INPUT_PATH)
if (!(SHEET %in% sheets)) {
  message(sprintf("Sheet '%s' not found; using first sheet '%s'.",
                  SHEET, sheets[1]))
  SHEET <- sheets[1]
}
dat <- read.xlsx(INPUT_PATH, sheet = SHEET)

# ------------------------------------------------------------------ roles
# Identifier columns are non-modeling keys; target and controls are known;
# everything else numeric is a candidate predictor. Detection is by name so the
# script adapts to schema changes between v1 and v2.
id_cols_known <- c("state", "state_abbr", "coc_number", "coc_name",
                   "predictor_year", "target_year")
id_cols      <- intersect(id_cols_known, colnames(dat))
target_col   <- "target_homeless_rate_per_10k"
control_cols <- grep("^control_", colnames(dat), value = TRUE)

non_pred <- unique(c(id_cols, target_col, control_cols))
predictor_cols <- setdiff(colnames(dat), non_pred)

# Coerce candidate predictors / target / controls to numeric where possible.
num_candidates <- unique(c(predictor_cols, control_cols, target_col))
for (cc in num_candidates) {
  if (!is.numeric(dat[[cc]])) {
    suppressWarnings(dat[[cc]] <- as.numeric(dat[[cc]]))
  }
}
# Keep only truly numeric predictors for numeric analyses.
predictor_cols <- predictor_cols[vapply(predictor_cols,
                                        function(c) is.numeric(dat[[c]]), logical(1))]

state_col <- if ("state" %in% colnames(dat)) "state" else
  if ("state_abbr" %in% colnames(dat)) "state_abbr" else NA
tyear_col <- if ("target_year" %in% colnames(dat)) "target_year" else NA
pyear_col <- if ("predictor_year" %in% colnames(dat)) "predictor_year" else NA
coc_col   <- if ("coc_number" %in% colnames(dat)) "coc_number" else
  if ("coc_name" %in% colnames(dat)) "coc_name" else NA

# Group state-level vs CoC-level predictors by name prefix (for interpretation).
state_level_pred <- grep("^state_", predictor_cols, value = TRUE)
coc_level_pred   <- setdiff(predictor_cols, state_level_pred)

# ------------------------------------------------------------------ theme
theme_set(theme_bw(base_size = 11))
state_pal <- c("California" = "#1b7837", "Florida" = "#762a83",
               "CA" = "#1b7837", "FL" = "#762a83")
save_plot <- function(p, file, w = 9, h = 6) {
  ggsave(file.path(plot_dir, file), p, width = w, height = h, dpi = 130)
}

# Collector for the findings report.
report <- character(0)
add <- function(...) report <<- c(report, sprintf(...))

add("# EDA findings — CA/FL homelessness LASSO input (%s)", vlab)
add("")
add("_Generated %s from `%s` (sheet `%s`)._",
    format(Sys.time(), "%Y-%m-%d %H:%M"), INPUT_PATH, SHEET)
if (is_dev) {
  add("")
  add("> **DEVELOPMENT OUTPUT (%s) — NOT FINAL.** These results were produced ",
      vlab)
  add("> against the interim v1 workbook while the v2 model input is being ")
  add("> built by another session. Re-run against ")
  add("> `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` to produce the final `outputs/eda_v2/`.")
}
add("")
add("All statements below describe **associations only**. Nothing here ")
add("identifies a causal effect: two states over a short, strongly ")
add("time-ordered panel cannot support causal claims.")
add("")

# =============================================================================
# 1. DATA-QUALITY SUMMARY
# =============================================================================
n_rows <- nrow(dat); n_cols <- ncol(dat)
states <- if (!is.na(state_col)) sort(unique(dat[[state_col]])) else NA
p_years <- if (!is.na(pyear_col)) sort(unique(dat[[pyear_col]])) else NA
t_years <- if (!is.na(tyear_col)) sort(unique(dat[[tyear_col]])) else NA
n_cocs  <- if (!is.na(coc_col)) length(unique(dat[[coc_col]])) else NA

# Duplicate CoC-years (a CoC-year should be unique).
dup_key <- NA_integer_; dup_rows <- data.frame()
if (!is.na(coc_col) && !is.na(tyear_col)) {
  key <- paste(dat[[coc_col]], dat[[tyear_col]], sep = "__")
  dup_key <- sum(duplicated(key))
  if (dup_key > 0) dup_rows <- dat[key %in% key[duplicated(key)], ]
}

# Missingness and infinities per column.
miss_n   <- vapply(dat, function(x) sum(is.na(x)), numeric(1))
inf_n    <- vapply(dat, function(x) if (is.numeric(x)) sum(is.infinite(x)) else 0, numeric(1))
col_qual <- data.frame(
  variable      = names(dat),
  role          = ifelse(names(dat) %in% id_cols, "identifier",
                  ifelse(names(dat) == target_col, "target",
                  ifelse(names(dat) %in% control_cols, "control",
                  ifelse(names(dat) %in% predictor_cols, "predictor", "other")))),
  class         = vapply(dat, function(x) class(x)[1], character(1)),
  n_missing     = miss_n,
  pct_missing   = round(100 * miss_n / n_rows, 2),
  n_infinite    = inf_n,
  n_unique      = vapply(dat, function(x) length(unique(x)), numeric(1)),
  row.names = NULL
)
write.csv(col_qual, file.path(table_dir, sprintf("data_quality_by_variable_%s.csv", VERSION)),
          row.names = FALSE)

tgt <- dat[[target_col]]
tgt_range <- range(tgt, na.rm = TRUE)
overall_summary <- data.frame(
  metric = c("n_rows", "n_cols", "n_identifier_cols", "n_control_cols",
             "n_predictor_cols", "states", "predictor_years", "target_years",
             "n_cocs", "duplicate_coc_years", "target_min", "target_max",
             "target_median", "target_mean", "target_n_missing",
             "cols_with_any_missing", "cols_with_infinities"),
  value = c(n_rows, n_cols, length(id_cols), length(control_cols),
            length(predictor_cols),
            paste(states, collapse = "; "),
            if (all(is.na(p_years))) NA else paste0(min(p_years), "-", max(p_years)),
            if (all(is.na(t_years))) NA else paste0(min(t_years), "-", max(t_years)),
            n_cocs, dup_key, round(tgt_range[1], 3), round(tgt_range[2], 3),
            round(median(tgt, na.rm = TRUE), 3), round(mean(tgt, na.rm = TRUE), 3),
            sum(is.na(tgt)), sum(miss_n > 0), sum(inf_n > 0))
)
write.csv(overall_summary, file.path(table_dir, sprintf("data_quality_overview_%s.csv", VERSION)),
          row.names = FALSE)

# 2021 PIT visibility check.
tgt2021 <- if (!is.na(tyear_col)) sum(dat[[tyear_col]] == 2021, na.rm = TRUE) else NA
pit2021_note <- if (!is.na(tgt2021) && tgt2021 == 0)
  "No target rows for target_year 2021 (COVID-disrupted PIT excluded as target, as designed)." else
  sprintf("WARNING: %s target rows have target_year 2021; the COVID-disrupted PIT count should normally be excluded as a target.", tgt2021)

add("## 1. Data quality")
add("")
add("- Dimensions: **%d rows x %d columns** (%d identifiers, %d controls, %d numeric predictors).",
    n_rows, n_cols, length(id_cols), length(control_cols), length(predictor_cols))
add("- States: %s.", paste(states, collapse = ", "))
if (!all(is.na(p_years))) add("- Predictor years: %d-%d. Target years: %d-%d.",
    min(p_years), max(p_years), min(t_years), max(t_years))
add("- CoCs: %s. Duplicate CoC-years: **%d**.", n_cocs, dup_key)
add("- Columns with any missing values: %d of %d. Columns with infinities: %d.",
    sum(miss_n > 0), n_cols, sum(inf_n > 0))
add("- Target range: **%.2f to %.2f** per 10k (median %.2f).",
    tgt_range[1], tgt_range[2], median(tgt, na.rm = TRUE))
add("- %s", pit2021_note)
if (!is.na(coc_col) && "coc_contains_split_county_flag" %in% colnames(dat)) {
  nsplit <- sum(dat[["coc_contains_split_county_flag"]] == 1, na.rm = TRUE)
  add("- CoC geography: %d rows flagged as containing a split county ",
      nsplit)
  add("  (`coc_contains_split_county_flag`). FY2024 CoC boundaries are applied ")
  add("  retrospectively, so historical CoC mergers/splits remain a source of ")
  add("  measurement error and are kept visible, not corrected.")
}
add("")

# =============================================================================
# 2. TARGET DISTRIBUTION + LOG-TARGET SENSITIVITY ASSESSMENT
# =============================================================================
tgt_ok <- tgt[is.finite(tgt)]
skew <- function(x) {
  x <- x[is.finite(x)]; n <- length(x)
  if (n < 3) return(NA)
  m <- mean(x); s <- sd(x)
  (sum((x - m)^3) / n) / (s^3)
}
raw_skew <- skew(tgt_ok)
can_log  <- all(tgt_ok > 0)
log_skew <- if (can_log) skew(log(tgt_ok)) else NA

log_warranted <- can_log && !is.na(raw_skew) && raw_skew > 1 &&
  (is.na(log_skew) || abs(log_skew) < abs(raw_skew))

tdf <- data.frame(target = tgt_ok)
p_raw <- ggplot(tdf, aes(target)) +
  geom_histogram(aes(y = after_stat(density)), bins = 40,
                 fill = "#4575b4", colour = "white", alpha = 0.85) +
  geom_density(colour = "#d73027", linewidth = 0.8) +
  labs(title = stamp("Target distribution: next-year homeless rate per 10k"),
       subtitle = sprintf("n=%d, skewness=%.2f", length(tgt_ok), raw_skew),
       x = "target_homeless_rate_per_10k", y = "density")
if (can_log) {
  ldf <- data.frame(logt = log(tgt_ok))
  p_log <- ggplot(ldf, aes(logt)) +
    geom_histogram(aes(y = after_stat(density)), bins = 40,
                   fill = "#4575b4", colour = "white", alpha = 0.85) +
    geom_density(colour = "#d73027", linewidth = 0.8) +
    labs(title = stamp("Log target distribution"),
         subtitle = sprintf("skewness=%.2f", log_skew),
         x = "log(target_homeless_rate_per_10k)", y = "density")
}
# Save two separate PNGs (avoid patchwork dependency).
save_plot(p_raw, sprintf("02a_target_distribution_%s.png", VERSION), w = 8, h = 5)
if (can_log) save_plot(p_log, sprintf("02b_log_target_distribution_%s.png", VERSION), w = 8, h = 5)

add("## 2. Target distribution and log-target sensitivity")
add("")
add("- Raw target skewness: **%.2f**%s.", raw_skew,
    if (can_log) sprintf("; log-target skewness: %.2f", log_skew) else "")
add("- A log-target sensitivity model is **%s**.",
    if (log_warranted) "WARRANTED" else "not clearly warranted on skewness grounds")
if (log_warranted) {
  add("  The raw target is right-skewed (skew > 1) and the log transform ")
  add("  materially reduces skewness, so a log-target LASSO run is a reasonable ")
  add("  sensitivity check alongside the primary rate model.")
} else if (!can_log) {
  add("  The target contains non-positive values, so a plain log transform is ")
  add("  not directly applicable; consider log1p only as a documented sensitivity.")
} else {
  add("  The raw target is not strongly skewed; a log-target model is optional. ")
  add("  Report it only if residual diagnostics from the primary model suggest it.")
}
add("")

# =============================================================================
# 3. CALIFORNIA vs FLORIDA HOMELESSNESS-RATE TRENDS OVER TIME
# =============================================================================
if (!is.na(state_col) && !is.na(tyear_col)) {
  # NOTE: unweighted_mean_rate is a simple average across the CoCs in a state-
  # year; it does NOT weight CoCs by population, so a small CoC counts as much
  # as a large one. It is a descriptive summary of the CoC-rate distribution,
  # not a population-weighted statewide homelessness rate.
  trend <- dat %>%
    filter(is.finite(.data[[target_col]])) %>%
    group_by(.data[[state_col]], .data[[tyear_col]]) %>%
    summarise(unweighted_mean_rate = mean(.data[[target_col]], na.rm = TRUE),
              median_rate = median(.data[[target_col]], na.rm = TRUE),
              n_cocs = dplyr::n(), .groups = "drop")
  names(trend)[1:2] <- c("state", "target_year")
  write.csv(trend, file.path(table_dir, sprintf("state_target_trends_%s.csv", VERSION)),
            row.names = FALSE)

  raw_pts <- dat %>%
    filter(is.finite(.data[[target_col]])) %>%
    transmute(state = .data[[state_col]], target_year = .data[[tyear_col]],
              rate = .data[[target_col]])

  p_trend <- ggplot() +
    geom_jitter(data = raw_pts, aes(target_year, rate, colour = state),
                width = 0.12, alpha = 0.18, size = 0.9) +
    geom_line(data = trend, aes(target_year, unweighted_mean_rate, colour = state),
              linewidth = 1.1) +
    geom_point(data = trend, aes(target_year, unweighted_mean_rate, colour = state),
               size = 2) +
    scale_colour_manual(values = state_pal) +
    labs(title = stamp("CA vs FL: next-year homeless rate over time"),
         subtitle = "Lines = UNWEIGHTED mean across CoCs (CoCs not population-weighted); points = individual CoC-years",
         x = "target_year", y = "homeless rate per 10k", colour = "state")
  save_plot(p_trend, sprintf("03_ca_fl_target_trends_%s.png", VERSION), w = 9, h = 5.5)

  # Divergence description (association only).
  gap <- trend %>% select(state, target_year, unweighted_mean_rate) %>%
    tidyr::pivot_wider(names_from = state, values_from = unweighted_mean_rate)
  add("## 3. California vs Florida target trends")
  add("")
  if (ncol(gap) == 3) {
    s1 <- names(gap)[2]; s2 <- names(gap)[3]
    add("- The **unweighted** mean next-year homeless rate by state and year ")
    add("  (a simple average across CoCs, **not** population-weighted) is tabulated ")
    add("  in `tables/state_target_trends_%s.csv` alongside the CoC median and CoC count.", VERSION)
    add("- The two states' unweighted CoC-mean trajectories are plotted in ")
    add("  `plots/03_ca_fl_target_trends_%s.png`; the persistent level gap between ", VERSION)
    add("  %s and %s is descriptive of the divergence the study examines. Because ", s1, s2)
    add("  the mean is unweighted, it reflects the CoC-rate distribution rather ")
    add("  than a statewide population rate.")
  }
  add("")
}

# =============================================================================
# 4. CoC-LEVEL TARGET DISTRIBUTIONS OVER TIME BY STATE
# =============================================================================
if (!is.na(state_col) && !is.na(tyear_col)) {
  bdf <- dat %>%
    filter(is.finite(.data[[target_col]])) %>%
    transmute(state = .data[[state_col]],
              target_year = factor(.data[[tyear_col]]),
              rate = .data[[target_col]])
  p_box <- ggplot(bdf, aes(target_year, rate)) +
    geom_boxplot(aes(fill = state), outlier.size = 0.7, alpha = 0.7) +
    facet_wrap(~ state, ncol = 1, scales = "free_y") +
    scale_fill_manual(values = state_pal) +
    labs(title = stamp("CoC-level target distribution over time, by state"),
         x = "target_year", y = "homeless rate per 10k") +
    theme(axis.text.x = element_text(angle = 45, hjust = 1),
          legend.position = "none")
  save_plot(p_box, sprintf("04_coc_target_boxplots_by_state_%s.png", VERSION),
            w = 10, h = 7)
  add("## 4. CoC-level target spread over time")
  add("")
  add("- `plots/04_coc_target_boxplots_by_state_%s.png` shows the within-state ", VERSION)
  add("  spread of CoC rates each year. Widening or narrowing boxes indicate ")
  add("  changing dispersion across CoCs, described here without causal claim.")
  add("")
}

# =============================================================================
# 5. PREDICTOR DISTRIBUTIONS + POTENTIAL EXTREME OBSERVATIONS
# =============================================================================
long_pred <- dat %>%
  select(all_of(predictor_cols)) %>%
  pivot_longer(everything(), names_to = "variable", values_to = "value") %>%
  filter(is.finite(value))

# Small-multiple histograms (free scales). Split into pages if many predictors.
np <- length(predictor_cols)
per_page <- 20
pages <- ceiling(np / per_page)
for (pg in seq_len(pages)) {
  vars_pg <- predictor_cols[((pg - 1) * per_page + 1):min(pg * per_page, np)]
  p_hist <- ggplot(filter(long_pred, variable %in% vars_pg), aes(value)) +
    geom_histogram(bins = 30, fill = "#3690c0", colour = "white") +
    facet_wrap(~ variable, scales = "free", ncol = 4) +
    labs(title = stamp(sprintf("Predictor distributions (page %d/%d)", pg, pages)),
         x = NULL, y = "count") +
    theme(strip.text = element_text(size = 7))
  save_plot(p_hist, sprintf("05_predictor_distributions_p%d_%s.png", pg, VERSION),
            w = 12, h = 9)
}

# Extreme observations: robust z-score based on median/MAD, flag |z| > 5.
extreme_rows <- list()
for (v in predictor_cols) {
  x <- dat[[v]]
  med <- median(x, na.rm = TRUE)
  madv <- mad(x, na.rm = TRUE)
  if (is.na(madv) || madv == 0) next
  z <- (x - med) / madv
  idx <- which(is.finite(z) & abs(z) > 5)
  if (length(idx) > 0) {
    ex <- data.frame(
      variable = v,
      row = idx,
      value = x[idx],
      robust_z = round(z[idx], 2)
    )
    if (!is.na(coc_col)) ex$coc <- dat[[coc_col]][idx]
    if (!is.na(state_col)) ex$state <- dat[[state_col]][idx]
    if (!is.na(pyear_col)) ex$predictor_year <- dat[[pyear_col]][idx]
    extreme_rows[[v]] <- ex
  }
}
extreme_df <- if (length(extreme_rows)) dplyr::bind_rows(extreme_rows) else
  data.frame(variable = character(0))
extreme_df <- extreme_df[order(-abs(extreme_df$robust_z)), , drop = FALSE]
write.csv(extreme_df, file.path(table_dir, sprintf("extreme_observations_%s.csv", VERSION)),
          row.names = FALSE)

# A single row can be flagged on several variables, so the number of flags is
# not the number of distinct extreme observations. Report both.
n_ex_flags <- nrow(extreme_df)
n_ex_rows  <- if (n_ex_flags > 0 && "row" %in% names(extreme_df))
  length(unique(extreme_df$row)) else 0
n_ex_vars  <- if (n_ex_flags > 0) length(unique(extreme_df$variable)) else 0

add("## 5. Predictor distributions and extreme observations")
add("")
add("- Distribution small-multiples: `plots/05_predictor_distributions_p*_%s.png`.", VERSION)
add("- `tables/extreme_observations_%s.csv` contains **%d row-variable flags** ", VERSION, n_ex_flags)
add("  (robust |z| > 5 via median/MAD). Each flag is one (row, predictor) cell, ")
add("  **not** a distinct observation: the same row can be flagged on several ")
add("  predictors. Those flags cover **%d distinct CoC-year rows** across **%d ",
    n_ex_rows, n_ex_vars)
add("  predictors**. State-level predictors in particular flag many rows at once ")
add("  because one state-year value is repeated across all of that state's CoCs.")
add("- These cells are **flagged, not removed or winsorized** — per project policy ")
add("  they must be checked against source files, since real recessions and policy ")
add("  shocks can look statistically extreme in a small panel.")
add("")

# =============================================================================
# 6. PREDICTOR TRENDS OVER TIME BY STATE
# =============================================================================
if (!is.na(state_col) && !is.na(pyear_col)) {
  ptrend <- dat %>%
    select(all_of(c(state_col, pyear_col, predictor_cols))) %>%
    rename(state = all_of(state_col), year = all_of(pyear_col)) %>%
    pivot_longer(all_of(predictor_cols), names_to = "variable", values_to = "value") %>%
    filter(is.finite(value)) %>%
    group_by(state, year, variable) %>%
    summarise(mean_value = mean(value, na.rm = TRUE), .groups = "drop")

  for (pg in seq_len(pages)) {
    vars_pg <- predictor_cols[((pg - 1) * per_page + 1):min(pg * per_page, np)]
    p_pt <- ggplot(filter(ptrend, variable %in% vars_pg),
                   aes(year, mean_value, colour = state)) +
      geom_line(linewidth = 0.8) + geom_point(size = 0.8) +
      facet_wrap(~ variable, scales = "free_y", ncol = 4) +
      scale_colour_manual(values = state_pal) +
      labs(title = stamp(sprintf("Predictor trends over time by state (page %d/%d)", pg, pages)),
           x = "predictor_year", y = "state mean") +
      theme(strip.text = element_text(size = 7), legend.position = "top")
    save_plot(p_pt, sprintf("06_predictor_trends_p%d_%s.png", pg, VERSION),
              w = 12, h = 9)
  }
  add("## 6. Predictor trends over time by state")
  add("")
  add("- `plots/06_predictor_trends_p*_%s.png` show each predictor's state-mean ", VERSION)
  add("  trajectory. State-level predictors (`state_*`) move identically for all ")
  add("  CoCs within a state; CoC-level predictors (`coc_*`) are state means of ")
  add("  varying CoC values.")
  add("")
}

# =============================================================================
# 7. CLUSTERED PREDICTOR CORRELATION HEATMAP
# =============================================================================
pred_mat <- as.matrix(dat[, predictor_cols, drop = FALSE])
pred_mat[!is.finite(pred_mat)] <- NA
# Drop zero-variance columns from the correlation view (kept in the NZV table).
sds <- apply(pred_mat, 2, sd, na.rm = TRUE)
cor_cols <- names(sds)[is.finite(sds) & sds > 0]
cor_mat <- cor(pred_mat[, cor_cols, drop = FALSE], use = "pairwise.complete.obs")

# Hierarchical clustering order on 1 - |r|.
ord <- cor_cols
if (length(cor_cols) > 2) {
  dmat <- as.dist(1 - abs(replace(cor_mat, is.na(cor_mat), 0)))
  hc <- hclust(dmat, method = "average")
  ord <- cor_cols[hc$order]
}
cm_long <- as.data.frame(as.table(cor_mat[ord, ord]))
names(cm_long) <- c("v1", "v2", "r")
cm_long$v1 <- factor(cm_long$v1, levels = ord)
cm_long$v2 <- factor(cm_long$v2, levels = rev(ord))
p_heat <- ggplot(cm_long, aes(v1, v2, fill = r)) +
  geom_tile() +
  scale_fill_gradient2(low = "#b2182b", mid = "white", high = "#2166ac",
                       midpoint = 0, limits = c(-1, 1), na.value = "grey85") +
  labs(title = stamp("Clustered predictor correlation heatmap"),
       subtitle = "Pairwise-complete Pearson r; average-linkage clustered order",
       x = NULL, y = NULL, fill = "r") +
  theme(axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 6),
        axis.text.y = element_text(size = 6))
save_plot(p_heat, sprintf("07_predictor_correlation_heatmap_%s.png", VERSION),
          w = 12, h = 11)
write.csv(round(cor_mat[ord, ord], 3),
          file.path(table_dir, sprintf("predictor_correlation_matrix_%s.csv", VERSION)))

add("## 7. Predictor correlation structure")
add("")
add("- Clustered heatmap: `plots/07_predictor_correlation_heatmap_%s.png`; full ", VERSION)
add("  matrix in `tables/predictor_correlation_matrix_%s.csv`.", VERSION)
add("")

# =============================================================================
# 8. HIGHLY CORRELATED PREDICTOR PAIRS
# =============================================================================
HI_R <- 0.80
pair_list <- list()
if (length(cor_cols) > 1) {
  cm <- cor_mat
  for (i in seq_len(nrow(cm) - 1)) {
    for (j in (i + 1):ncol(cm)) {
      r <- cm[i, j]
      if (is.finite(r) && abs(r) >= HI_R) {
        pair_list[[length(pair_list) + 1]] <- data.frame(
          variable_1 = rownames(cm)[i], variable_2 = colnames(cm)[j],
          r = round(r, 3), abs_r = round(abs(r), 3))
      }
    }
  }
}
hi_pairs <- if (length(pair_list)) dplyr::bind_rows(pair_list) else
  data.frame(variable_1 = character(0), variable_2 = character(0),
             r = numeric(0), abs_r = numeric(0))
hi_pairs <- hi_pairs[order(-hi_pairs$abs_r), , drop = FALSE]
write.csv(hi_pairs, file.path(table_dir, sprintf("highly_correlated_pairs_%s.csv", VERSION)),
          row.names = FALSE)

add("## 8. Highly correlated predictor pairs")
add("")
add("- **%d** predictor pairs have |r| >= %.2f (`tables/highly_correlated_pairs_%s.csv`).",
    nrow(hi_pairs), HI_R, VERSION)
if (nrow(hi_pairs) > 0) {
  top_n <- head(hi_pairs, 8)
  for (k in seq_len(nrow(top_n))) {
    add("  - %s ~ %s: r = %.2f", top_n$variable_1[k], top_n$variable_2[k], top_n$r[k])
  }
  add("  LASSO tolerates collinearity but selection among correlated predictors ")
  add("  is unstable; interpret any single selected member cautiously.")
}
add("")

# =============================================================================
# 9. CONSTANT AND NEAR-ZERO-VARIANCE PREDICTORS
# =============================================================================
nzv_rows <- list()
for (v in predictor_cols) {
  x <- dat[[v]]
  xv <- x[is.finite(x)]
  n_unique <- length(unique(xv))
  n_nonNA  <- length(xv)
  pct_unique <- if (n_nonNA > 0) 100 * n_unique / n_nonNA else NA
  freq_ratio <- NA
  if (n_unique >= 2) {
    tb <- sort(table(xv), decreasing = TRUE)
    freq_ratio <- as.numeric(tb[1]) / as.numeric(tb[2])
  } else if (n_unique == 1) {
    freq_ratio <- Inf
  }
  is_constant <- n_unique <= 1
  # caret-style NZV heuristic.
  is_nzv <- is_constant ||
    (is.finite(freq_ratio) && freq_ratio > 19 && is.finite(pct_unique) && pct_unique < 10)
  nzv_rows[[v]] <- data.frame(
    variable = v,
    n_nonNA = n_nonNA,
    n_unique = n_unique,
    pct_unique = round(pct_unique, 2),
    freq_ratio = round(freq_ratio, 2),
    is_constant = is_constant,
    is_near_zero_var = is_nzv)
}
nzv_df <- dplyr::bind_rows(nzv_rows)
nzv_flagged <- nzv_df[nzv_df$is_constant | nzv_df$is_near_zero_var, , drop = FALSE]
write.csv(nzv_df, file.path(table_dir, sprintf("variance_screen_all_%s.csv", VERSION)),
          row.names = FALSE)
write.csv(nzv_flagged, file.path(table_dir, sprintf("constant_and_nzv_predictors_%s.csv", VERSION)),
          row.names = FALSE)

add("## 9. Constant / near-zero-variance predictors")
add("")
add("- Constant predictors: **%d**; near-zero-variance predictors: **%d** ",
    sum(nzv_df$is_constant), sum(nzv_df$is_near_zero_var))
add("  (`tables/constant_and_nzv_predictors_%s.csv`).", VERSION)
if (nrow(nzv_flagged) > 0) {
  for (k in seq_len(min(nrow(nzv_flagged), 12))) {
    add("  - %s (unique=%d, freq_ratio=%s)", nzv_flagged$variable[k],
        nzv_flagged$n_unique[k], nzv_flagged$freq_ratio[k])
  }
}
add("  These are reported for review; they are **not dropped** by this EDA.")
add("")

# =============================================================================
# 10. TARGET vs PREDICTOR PLOTS (curated, faceted by state, colored by year)
# =============================================================================
curated <- c(
  # housing
  "coc_housing_units_per_1000_residents", "coc_permits_per_1000_housing_units",
  "state_real_median_rent_2025_usd", "state_rental_vacancy_rate",
  "coc_housing_cost_burdened_households_pct",
  # economic
  "coc_unemployment_rate_pct", "coc_poverty_all_pct",
  "coc_real_median_household_income_2025_usd",
  # demographic
  "coc_population_density_per_sq_mile", "coc_domestic_migration_rate_per_1000",
  # service capacity
  "coc_hic_temporary_beds_per_10k", "coc_hic_psh_beds_per_10k",
  "state_homeless_funding_per_capita")
curated <- intersect(curated, predictor_cols)

if (length(curated) > 0 && !is.na(state_col)) {
  tp <- dat %>%
    select(all_of(c(state_col, pyear_col, target_col, curated))) %>%
    rename(state = all_of(state_col), year = all_of(pyear_col),
           target = all_of(target_col)) %>%
    pivot_longer(all_of(curated), names_to = "variable", values_to = "value") %>%
    filter(is.finite(value), is.finite(target))
  p_tp <- ggplot(tp, aes(value, target, colour = year)) +
    geom_point(alpha = 0.5, size = 0.9) +
    facet_grid(state ~ variable, scales = "free_x", switch = "x") +
    scale_colour_viridis_c() +
    labs(title = stamp("Target vs key predictors (no fitted line; descriptive)"),
         subtitle = "Faceted by state (rows) x predictor (cols); colour = predictor_year",
         x = NULL, y = "homeless rate per 10k") +
    theme(strip.text.x = element_text(size = 6),
          axis.text = element_text(size = 6))
  save_plot(p_tp, sprintf("10_target_vs_key_predictors_%s.png", VERSION),
            w = 16, h = 6)

  # Simple association table: Spearman rho of target vs each curated predictor.
  assoc <- lapply(curated, function(v) {
    x <- dat[[v]]; y <- dat[[target_col]]
    ok <- is.finite(x) & is.finite(y)
    data.frame(variable = v, n = sum(ok),
               spearman_rho = if (sum(ok) > 3)
                 round(suppressWarnings(cor(x[ok], y[ok], method = "spearman")), 3) else NA)
  })
  assoc_df <- dplyr::bind_rows(assoc)
  assoc_df <- assoc_df[order(-abs(assoc_df$spearman_rho)), ]
  write.csv(assoc_df, file.path(table_dir, sprintf("curated_target_associations_%s.csv", VERSION)),
            row.names = FALSE)

  add("## 10. Target vs key predictors")
  add("")
  add("- `plots/10_target_vs_key_predictors_%s.png` (no fitted lines, per project ", VERSION)
  add("  policy) and Spearman associations in ")
  add("  `tables/curated_target_associations_%s.csv`.", VERSION)
  add("- Strongest curated monotone associations with the target (Spearman rho):")
  for (k in seq_len(min(nrow(assoc_df), 6))) {
    if (!is.na(assoc_df$spearman_rho[k]))
      add("  - %s: rho = %.2f (n=%d)", assoc_df$variable[k],
          assoc_df$spearman_rho[k], assoc_df$n[k])
  }
  add("  These are marginal associations only, unadjusted for state, time, or ")
  add("  other predictors.")
  add("")
}

# =============================================================================
# 11. TARGET-LEAKAGE / FUTURE-INFORMATION CHECK
# =============================================================================
leak_rows <- list()
add_leak <- function(variable, check, status, note) {
  leak_rows[[length(leak_rows) + 1]] <<- data.frame(
    variable = variable, check = check, status = status, note = note)
}

# 11a. Lag integrity: predictor_year must be strictly before target_year.
if (!is.na(pyear_col) && !is.na(tyear_col)) {
  lag_gap <- dat[[tyear_col]] - dat[[pyear_col]]
  bad_lag <- sum(is.finite(lag_gap) & lag_gap <= 0, na.rm = TRUE)
  gap_tab <- paste(sprintf("%s:%d", names(table(lag_gap)), as.integer(table(lag_gap))),
                   collapse = ", ")
  add_leak("(all)", "predictor_year < target_year",
           if (bad_lag == 0) "PASS" else "FAIL",
           sprintf("target-predictor year gaps -> %s; %d rows with gap<=0", gap_tab, bad_lag))
}

# 11b. 2021 target exclusion.
if (!is.na(tyear_col)) {
  n21 <- sum(dat[[tyear_col]] == 2021, na.rm = TRUE)
  add_leak("target_year", "2021 excluded as target",
           if (n21 == 0) "PASS" else "REVIEW",
           sprintf("%d rows target_year==2021 (COVID-disrupted PIT)", n21))
}

# 11c. Near-perfect correlation with target => possible mechanical leakage.
tcor <- sapply(predictor_cols, function(v) {
  x <- dat[[v]]; y <- dat[[target_col]]
  ok <- is.finite(x) & is.finite(y)
  if (sum(ok) > 3) suppressWarnings(cor(x[ok], y[ok])) else NA
})
susp <- names(tcor)[is.finite(tcor) & abs(tcor) > 0.95]
if (length(susp) > 0) {
  for (v in susp) add_leak(v, "|corr with target| > 0.95", "REVIEW",
                           sprintf("r=%.3f; check for mechanical relation to the target", tcor[v]))
} else {
  add_leak("(predictors)", "|corr with target| > 0.95", "PASS",
           "no predictor is near-perfectly correlated with the target")
}

# 11d. Shared-denominator / population predictors that touch the target denominator.
pop_like <- grep("population|estimated_population|per_10k|per_1000|density|group_quarters",
                 predictor_cols, value = TRUE, ignore.case = TRUE)
for (v in pop_like) {
  add_leak(v, "shares construction with target denominator", "NOTE",
           "uses predictor-year CoC population; target uses next-year population. Low but non-zero mechanical overlap; keep as predictor, monitor stability.")
}

# 11e. Name-based scan for anything that could carry future/outcome information.
future_like <- grep("target|outcome|pit_count|homeless.*count|next_year|future",
                    predictor_cols, value = TRUE, ignore.case = TRUE)
future_like <- setdiff(future_like, pop_like)
for (v in future_like) {
  add_leak(v, "name suggests outcome/future content", "REVIEW",
           "verify this predictor is not derived from the target or a future-dated source")
}
if (length(future_like) == 0) {
  add_leak("(predictors)", "name scan for outcome/future content", "PASS",
           "no predictor name suggests it carries the target or future-dated information")
}

leak_df <- dplyr::bind_rows(leak_rows)
write.csv(leak_df, file.path(table_dir, sprintf("leakage_check_%s.csv", VERSION)),
          row.names = FALSE)

add("## 11. Target-leakage / future-information check")
add("")
n_fail <- sum(leak_df$status %in% c("FAIL"))
n_review <- sum(leak_df$status %in% c("REVIEW"))
add("- Full results: `tables/leakage_check_%s.csv` (%d checks; %d FAIL, %d REVIEW).",
    VERSION, nrow(leak_df), n_fail, n_review)
add("- Lag structure: predictor_year is matched to the following target year, so ")
add("  same-year simultaneity between predictors and the outcome is structurally ")
add("  reduced; the check confirms no row violates predictor_year < target_year ")
add("  (unless flagged FAIL above).")
add("- Population / rate-denominator predictors are flagged NOTE, not removed: ")
add("  they use the predictor-year CoC population while the target uses the ")
add("  next-year population, so mechanical overlap is limited but worth monitoring.")
add("")

# =============================================================================
# 12. WRITE FINDINGS REPORT + READINESS + SESSION INFO
# =============================================================================
add("## What is ready now, and what waits for v2")
add("")
if (is_dev) {
  add("- This run used the interim **v1** workbook. All plots and tables above ")
  add("  are reproducible and structurally complete, but the **numbers are ")
  add("  provisional**. Treat them as a pipeline check, not final EDA.")
  add("- The identical script produces `outputs/eda_v2/` once ")
  add("  `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` exists:")
  add("  `Rscript eda_lasso_input.R --input outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`.")
  add("- Waiting on v2: final target range, final predictor pool (v2 may add, ")
  add("  drop, or rename predictors), and therefore the final correlation, NZV, ")
  add("  extreme-observation, and leakage tables.")
} else {
  add("- This is the **final v2 EDA**. All twelve deliverables are populated ")
  add("  from `CA_FL_LASSO_MODEL_INPUT_v2.xlsx`.")
}
add("")
add("### Standing data-quality reminders kept visible")
add("")
add("- **2021 PIT**: the COVID-disrupted 2021 count is excluded as a modeling ")
add("  target; changes touching 2021 remain unreliable. Do not read 2021-adjacent ")
add("  movements as real market change.")
add("- **CoC geography**: FY2024 CoC boundaries are applied retrospectively. ")
add("  Historical CoC mergers/splits are a measurement-error source; the ")
add("  split-county flag is retained so this stays visible.")
add("- **No causal claims**: every association above is unadjusted and descriptive.")
add("")

writeLines(report, file.path(OUTDIR, sprintf("EDA_FINDINGS_%s.md", VERSION)))

# Reproducibility record.
si <- capture.output(sessionInfo())
writeLines(c(sprintf("Input: %s", INPUT_PATH),
             sprintf("Sheet: %s", SHEET),
             sprintf("Version: %s", VERSION),
             sprintf("Run at: %s", format(Sys.time())),
             sprintf("Seed: 20260724"),
             "", si),
           file.path(OUTDIR, sprintf("session_info_%s.txt", VERSION)))

message(sprintf("Done. Wrote %d plots and tables to %s",
                length(list.files(plot_dir)) + length(list.files(table_dir)),
                OUTDIR))
