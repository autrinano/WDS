###############################################################################
# generate_final_lasso_report.R
#
# Builds the FINAL results package for the California-Florida CoC-year
# homelessness LASSO analysis: performance tables, coefficient tables,
# robustness matrices, and the figure set referenced by LASSO_FINAL_RESULTS.md.
#
# OWNERSHIP AND READ-ONLY CONTRACT
# --------------------------------
# This script OWNS exactly two paths:
#   * itself
#   * outputs/lasso_final_report/
# It WRITES nothing anywhere else. It does not fit, refit, tune, or re-score any
# model; it does not read the modeling input workbook as data; it does not
# modify any dataset, any modeling script, or any central project document.
# Every number it emits is read from an already-produced, already-audited
# artefact and is either copied verbatim or derived by arithmetic that is
# recorded in the emitted table itself.
#
# INPUTS (all read-only)
#   outputs/lasso_models/FINAL_*                 primary model run
#   outputs/lasso_sensitivity/                   sensitivity run
#   outputs/lasso_audit/                         independent audit
#   outputs/eda_v2/tables/                       correlation structure
#
# INTERPRETATION
# --------------
# Everything produced here describes PREDICTIVE ASSOCIATION in a two-state,
# strongly time-ordered panel with retrospectively applied FY2024 CoC
# boundaries. Nothing here is a causal effect or an impact estimate.
#
# Reproduce:  Rscript generate_final_lasso_report.R
###############################################################################

suppressWarnings(suppressMessages({
  .libPaths(c("_r_libs", .libPaths()))
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(scales)
  library(openxlsx)
}))

options(stringsAsFactors = FALSE, dplyr.summarise.inform = FALSE)

## ---------------------------------------------------------------------------
## 0. PATHS AND WRITE GUARD
## ---------------------------------------------------------------------------

OUT      <- file.path("outputs", "lasso_final_report")
FIG      <- file.path(OUT, "figures")
TAB      <- file.path(OUT, "tables")

DIR_MODEL <- file.path("outputs", "lasso_models")
DIR_SENS  <- file.path("outputs", "lasso_sensitivity")
DIR_AUDIT <- file.path("outputs", "lasso_audit")
DIR_EDA   <- file.path("outputs", "eda_v2")

for (d in c(OUT, FIG, TAB)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# Every write in this script goes through write_owned(); it refuses any path
# outside outputs/lasso_final_report/.
write_owned <- function(path) {
  norm <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  root <- normalizePath(OUT,            winslash = "/", mustWork = TRUE)
  if (!startsWith(norm, root))
    stop("REFUSED: write outside owned directory: ", path)
  invisible(path)
}
wcsv <- function(df, path) { write_owned(path); write.csv(df, path, row.names = FALSE, na = ""); invisible(path) }

read_req <- function(path) {
  if (!file.exists(path)) stop("Required input missing: ", path)
  read.csv(path, check.names = FALSE)
}

## ---------------------------------------------------------------------------
## 1. PROVENANCE CHECK (read-only)
## ---------------------------------------------------------------------------
# The report must not be assembled from a run whose input has since changed.
# Verify the live v2 workbook still hashes to what the FINAL manifest recorded.

manifest <- read_req(file.path(DIR_MODEL, "FINAL_run_manifest.csv"))
mf       <- setNames(manifest$value, manifest$field)

V2_PATH      <- mf[["input_file"]]
V2_MD5_RUN   <- mf[["input_md5"]]
V2_MD5_LIVE  <- if (file.exists(V2_PATH)) unname(tools::md5sum(V2_PATH)) else NA_character_
PROV_OK      <- identical(V2_MD5_LIVE, V2_MD5_RUN)

if (!identical(mf[["run_mode"]], "FINAL"))
  stop("REFUSED: outputs/lasso_models/ does not record a FINAL run (run_mode = ", mf[["run_mode"]], ").")
if (!PROV_OK)
  stop("REFUSED: live MD5 of ", V2_PATH, " (", V2_MD5_LIVE, ") does not match the FINAL run manifest (", V2_MD5_RUN, ").")

message("Provenance OK: ", V2_PATH, " MD5 ", V2_MD5_LIVE)

## ---------------------------------------------------------------------------
## 2. LOAD ARTEFACTS
## ---------------------------------------------------------------------------

metrics_overall <- read_req(file.path(DIR_MODEL, "FINAL_metrics_overall_out_of_time.csv"))
metrics_fold    <- read_req(file.path(DIR_MODEL, "FINAL_metrics_by_fold.csv"))
state_perf      <- read_req(file.path(DIR_MODEL, "FINAL_ca_fl_state_performance.csv"))
folds           <- read_req(file.path(DIR_MODEL, "FINAL_fold_definitions.csv"))
preds           <- read_req(file.path(DIR_MODEL, "FINAL_predictions.csv"))
coef_stab       <- read_req(file.path(DIR_MODEL, "FINAL_coefficient_stability.csv"))
raw_vs_log      <- read_req(file.path(DIR_MODEL, "FINAL_raw_vs_log_comparison.csv"))
resid_diag      <- read_req(file.path(DIR_MODEL, "FINAL_residual_diagnostics.csv"))

sens_pooled     <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_metrics_overall_pooled.csv"))
sens_common     <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_comparison_with_primary_common_rows.csv"))
sens_selwide    <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_selection_frequency_wide.csv"))
sens_stable     <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_stable_predictors_across_models.csv"))
sens_persist    <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_persistence_benchmark.csv"))
sens_fold       <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_performance_by_fold.csv"))
sens_state      <- read_req(file.path(DIR_SENS, "results", "SENSITIVITY_ca_fl_state_performance.csv"))
sens_samples    <- read_req(file.path(DIR_SENS, "definitions", "sensitivity_sample_definitions.csv"))
sens_avail      <- read_req(file.path(DIR_SENS, "definitions", "sensitivity_predictor_availability.csv"))

audit_checks    <- read_req(file.path(DIR_AUDIT, "audit_checks.csv"))
corr_pairs      <- read_req(file.path(DIR_EDA, "tables", "highly_correlated_pairs_v2.csv"))

## ---------------------------------------------------------------------------
## 3. CONVENTIONS
## ---------------------------------------------------------------------------

HEADLINE_MODEL  <- "pooled_lasso_state_interactions"
HEADLINE_RULE   <- "min"
HEADLINE_LABEL  <- "Unified pooled LASSO + state interactions (lambda.min)"

# How a fitted object relates to the "one model for both states" question.
# This distinction is load-bearing: separate_state_lasso is NOT a unified model,
# it is the concatenation of the two single-state models.
model_class <- c(
  pooled_lasso                    = "Unified (one model, both states)",
  pooled_lasso_state_interactions = "Unified (one model, both states)",
  separate_state_lasso            = "Separate-state composite (not a unified model)",
  separate_lasso_CA               = "Single-state component",
  separate_lasso_FL               = "Single-state component",
  state_time_baseline             = "Baseline (state + linear time)"
)

model_label <- c(
  pooled_lasso                    = "Pooled LASSO",
  pooled_lasso_state_interactions = "Pooled LASSO + state interactions",
  separate_state_lasso            = "Separate-state composite (CA+FL)",
  separate_lasso_CA               = "Separate LASSO - California only",
  separate_lasso_FL               = "Separate LASSO - Florida only",
  state_time_baseline             = "State + linear-time baseline"
)

# Predictor domain, assigned from the variable's own definition. Used to keep
# service-capacity associations visually and textually separate from structural
# housing / economic factors.
domain_map <- c(
  coc_hic_psh_beds_per_10k                          = "Service capacity",
  coc_hic_temporary_beds_per_10k                    = "Service capacity",
  coc_annual_hpi_change_pct                         = "Housing market",
  coc_relative_home_price_index_2000_base           = "Housing market",
  coc_housing_cost_burdened_households_pct          = "Housing market",
  coc_homeownership_rate_pct                        = "Housing market",
  coc_housing_units_per_1000_residents              = "Housing stock/supply",
  coc_housing_supply_growth_rate_pct                = "Housing stock/supply",
  coc_permits_per_1000_housing_units                = "Housing stock/supply",
  coc_permits_value_per_1000_housing_units_2025_usd = "Housing stock/supply",
  coc_multifamily_permit_share_pct                  = "Housing stock/supply",
  coc_group_quarters_per_1000_residents             = "Housing stock/supply",
  state_real_median_rent_2025_usd                   = "Housing market",
  state_rental_vacancy_rate                         = "Housing market",
  coc_real_gdp_quantity_index                       = "Economic",
  coc_real_gdp_per_capita_2017_usd                  = "Economic",
  coc_real_median_household_income_2025_usd         = "Economic",
  coc_real_per_capita_personal_income_2025_usd      = "Economic",
  coc_income_inequality_ratio                       = "Economic",
  coc_unemployment_rate_pct                         = "Economic",
  coc_poverty_all_pct                               = "Economic",
  coc_poverty_child_pct                             = "Economic",
  state_real_minimum_wage_2025_usd                  = "Economic",
  state_labor_force_participation_pct               = "Economic",
  coc_log_estimated_population                      = "Scale/geography",
  coc_population_density_per_sq_mile                = "Scale/geography",
  coc_contributing_counties                         = "Scale/geography",
  coc_contains_split_county_flag                    = "Scale/geography",
  coc_population_growth_rate_pct                    = "Demographic",
  coc_domestic_migration_rate_per_1000              = "Demographic",
  coc_international_migration_rate_per_1000         = "Demographic",
  coc_birth_rate_per_1000                           = "Demographic",
  coc_death_rate_per_1000                           = "Demographic",
  coc_high_school_graduate_pct                      = "Demographic",
  state_anticamping_strictness                      = "Policy",
  state_medicaid_expansion                          = "Policy",
  state_ssi_state_supplement                        = "Policy",
  state_tanf_max_benefit_3person                    = "Policy"
)

base_term <- function(x) sub(":FL$", "", x)
dom_of    <- function(x) ifelse(is.na(domain_map[x]), "Other", domain_map[x])

# Predictors that vary only by state and year (one value repeated across every
# CoC in that state). The unpenalized state and time controls absorb most of
# what these can contribute, so non-selection is not evidence of no relationship.
is_state_level <- function(x) grepl("^state_", x)

## ---------------------------------------------------------------------------
## 4. THEME
## ---------------------------------------------------------------------------

PAL_STATE <- c(California = "#2B6CB0", Florida = "#C05621")
PAL_SIGN  <- c(Positive   = "#C05621", Negative = "#2B6CB0")

theme_rep <- function(base = 11) {
  theme_minimal(base_size = base) +
    theme(
      plot.title       = element_text(face = "bold", size = base + 3, margin = margin(b = 3)),
      plot.subtitle    = element_text(colour = "grey30", size = base - 0.5, margin = margin(b = 8)),
      plot.caption     = element_text(colour = "grey40", size = base - 2.5, hjust = 0, margin = margin(t = 10)),
      plot.title.position = "plot",
      plot.caption.position = "plot",
      panel.grid.minor = element_blank(),
      panel.grid.major = element_line(colour = "grey90", linewidth = 0.3),
      strip.text       = element_text(face = "bold", size = base - 0.5),
      legend.position  = "bottom",
      legend.title     = element_text(size = base - 1),
      plot.margin      = margin(12, 16, 10, 12)
    )
}

CAP_ASSOC <- paste(
  "Predictive associations from out-of-time (rolling-origin) validation, not causal effects.",
  "2021 PIT excluded as a target; FY2024 CoC boundaries applied retrospectively.",
  sep = "\n"
)

# Cairo is advertised but its shared object does not load on this host; quartz
# is the working device. Resolved once, at load, rather than per figure.
PNG_TYPE <- local({
  cand <- if (identical(.Platform$OS.type, "unix") && isTRUE(capabilities("aqua"))) "quartz" else "cairo"
  ok <- tryCatch({
    tf <- tempfile(fileext = ".png")
    grDevices::png(tf, width = 2, height = 2, units = "in", res = 72, type = cand)
    graphics::plot.new()          # quartz materialises the file only on first output
    grDevices::dev.off(); on.exit(unlink(tf), add = TRUE)
    file.exists(tf) && file.info(tf)$size > 0
  }, warning = function(w) FALSE, error = function(e) FALSE)
  if (ok) cand else "cairo"
})

save_fig <- function(plot, file, w, h, dpi = 200) {
  path <- file.path(FIG, file)
  write_owned(path)
  grDevices::png(path, width = w, height = h, units = "in", res = dpi, type = PNG_TYPE, bg = "white")
  print(plot)
  grDevices::dev.off()
  message("  figure: ", path)
  invisible(path)
}

## ---------------------------------------------------------------------------
## 5. TABLE 1 - MODEL PERFORMANCE COMPARISON
## ---------------------------------------------------------------------------

t1 <- metrics_overall %>%
  mutate(
    model_family      = model_label[model],
    comparability     = model_class[model],
    is_headline       = model == HEADLINE_MODEL & lambda_rule == HEADLINE_RULE,
    scored_rows       = n,
    rmse_vs_baseline  = rmse - metrics_overall$rmse[metrics_overall$model == "state_time_baseline"][1],
    covers_both_states = n == 555
  ) %>%
  arrange(rmse) %>%
  transmute(
    model, lambda_rule, model_family, comparability,
    n = scored_rows, covers_both_states,
    rmse = round(rmse, 4), mae = round(mae, 4), r2 = round(r2, 4),
    rmse_minus_baseline = round(rmse_vs_baseline, 4),
    rank_rmse_overall   = rank(rmse, ties.method = "min"),
    is_headline_model   = is_headline
  )

# Ranks restricted to the unified models - the only set in which the headline
# "best" claim is true.
uni <- t1$comparability == "Unified (one model, both states)"
t1$rank_rmse_among_unified <- NA_integer_
t1$rank_mae_among_unified  <- NA_integer_
t1$rank_rmse_among_unified[uni] <- rank(t1$rmse[uni], ties.method = "min")
t1$rank_mae_among_unified[uni]  <- rank(t1$mae[uni],  ties.method = "min")

wcsv(t1, file.path(TAB, "TABLE_01_model_performance_comparison.csv"))

## ---------------------------------------------------------------------------
## 6. TABLE 2 + FIG 3 - RMSE AND R2 BY VALIDATION YEAR
## ---------------------------------------------------------------------------

t2 <- metrics_fold %>%
  filter(group == "all") %>%
  left_join(folds[, c("validation_year", "n_train_years", "n_train_rows")], by = "validation_year") %>%
  transmute(
    fold, validation_year, model, lambda_rule,
    model_family = model_label[model], comparability = model_class[model],
    n_validation_rows = n, n_train_years, n_train_rows,
    rmse = round(rmse, 4), mae = round(mae, 4), r2 = round(r2, 4)
  ) %>%
  arrange(validation_year, model, lambda_rule)

wcsv(t2, file.path(TAB, "TABLE_02_performance_by_validation_year.csv"))

fig3_models <- c("pooled_lasso_state_interactions", "pooled_lasso", "separate_state_lasso", "state_time_baseline")
fig3_dat <- metrics_fold %>%
  filter(group == "all", model %in% fig3_models,
         (model == "state_time_baseline" & lambda_rule == "none") |
           (model != "state_time_baseline" & lambda_rule == "min")) %>%
  mutate(series = factor(model_label[model], levels = model_label[fig3_models])) %>%
  select(validation_year, series, rmse, r2) %>%
  pivot_longer(c(rmse, r2), names_to = "metric", values_to = "value") %>%
  mutate(metric = factor(metric, c("rmse", "r2"),
                         c("RMSE (per 10,000 residents)", expression_ok <- "Out-of-time R²")))

fig3 <- ggplot(fig3_dat, aes(factor(validation_year), value, colour = series, group = series)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 2.1) +
  facet_wrap(~metric, ncol = 1, scales = "free_y") +
  scale_colour_manual(values = c("#2B6CB0", "#4FA3D1", "#2F855A", "#A0AEC0"), name = NULL) +
  labs(
    title    = "Out-of-time accuracy by validation year",
    subtitle = paste0("Expanding-window rolling origin. Each year is scored by a model trained only on strictly earlier target years.\n",
                      "2021 is absent: the COVID-disrupted PIT count is excluded as a modelling target, so there is no 2021 fold."),
    x = "Validation (target) year", y = NULL,
    caption = paste0(CAP_ASSOC, "\nAll penalised models shown at lambda.min. Training window grows from 332 rows (2017) to 817 rows (2025).")
  ) +
  theme_rep() +
  guides(colour = guide_legend(nrow = 2))

save_fig(fig3, "FIG_03_rmse_r2_by_validation_year.png", 9, 7.4)

## ---------------------------------------------------------------------------
## 7. FIG 1 - MODEL PERFORMANCE COMPARISON
## ---------------------------------------------------------------------------

fig1_dat <- metrics_overall %>%
  mutate(
    lab   = paste0(model_label[model], if_else(lambda_rule == "none", "", paste0("  (lambda.", lambda_rule, ")"))),
    class = factor(model_class[model],
                   levels = c("Unified (one model, both states)",
                              "Separate-state composite (not a unified model)",
                              "Single-state component",
                              "Baseline (state + linear time)")),
    scope_note = if_else(n == 555, "Scored on both states (n = 555)", "Scored on one state only (n = 347 CA / 208 FL)")
  ) %>%
  select(lab, class, scope_note, rmse, mae, r2) %>%
  pivot_longer(c(rmse, mae, r2), names_to = "metric", values_to = "value") %>%
  mutate(metric = factor(metric, c("rmse", "mae", "r2"),
                         c("RMSE (lower is better)", "MAE (lower is better)", "Out-of-time R² (higher is better)")))

ord <- fig1_dat %>% filter(metric == "RMSE (lower is better)") %>% arrange(desc(value)) %>% pull(lab)
fig1_dat$lab <- factor(fig1_dat$lab, levels = ord)

fig1 <- ggplot(fig1_dat, aes(value, lab, colour = class, shape = scope_note)) +
  geom_segment(aes(x = 0, xend = value, yend = lab), linewidth = 0.35, colour = "grey85") +
  geom_point(size = 2.8) +
  geom_text(aes(label = sprintf("%.3f", value)), hjust = -0.3, size = 2.7, colour = "grey25", show.legend = FALSE) +
  facet_wrap(~metric, scales = "free_x") +
  scale_x_continuous(expand = expansion(mult = c(0.02, 0.18))) +
  scale_colour_manual(values = c("#2B6CB0", "#805AD5", "#C05621", "#718096"), name = NULL) +
  scale_shape_manual(values = c(16, 17), name = NULL) +
  labs(
    title    = "Pooled out-of-time performance, all fitted specifications",
    subtitle = paste0("Rows scored across eight rolling-origin folds. Single-state components are scored on their own state only (347 CA / 208 FL)\n",
                      "and are NOT comparable to the 555-row both-state totals. The separate-state composite is the concatenation of the two\n",
                      "single-state models, not an independent fifth model."),
    x = NULL, y = NULL,
    caption = paste0(CAP_ASSOC,
                     "\nRanking is criterion-dependent: the lowest-RMSE unified model does not have the lowest MAE.",
                     "\nPooled R² partly reflects the CA/FL level gap - the baseline's pooled R² of 0.190 comes with negative within-state R² in both states.")
  ) +
  theme_rep() +
  guides(colour = guide_legend(nrow = 2, order = 1), shape = guide_legend(nrow = 2, order = 2))

save_fig(fig1, "FIG_01_model_performance_comparison.png", 13, 7.6)

## ---------------------------------------------------------------------------
## 8. FIG 2 - OBSERVED VS PREDICTED, HEADLINE MODEL
## ---------------------------------------------------------------------------

hp <- preds %>% filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE)
stopifnot(nrow(hp) == 555)

hp_stats <- state_perf %>% filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE)
hp_pool  <- metrics_overall %>% filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE)

ann <- hp_stats %>%
  transmute(state, n,
            lab = sprintf("%s: n = %d   RMSE = %.2f   R² = %.3f", state, n, rmse, r2))

lim <- range(c(hp$actual, hp$predicted))

fig2 <- ggplot(hp, aes(predicted, actual, colour = state)) +
  geom_abline(slope = 1, intercept = 0, colour = "grey45", linetype = "22", linewidth = 0.5) +
  geom_point(alpha = 0.62, size = 1.7) +
  scale_colour_manual(values = PAL_STATE, name = NULL) +
  coord_equal(xlim = lim, ylim = lim) +
  labs(
    title    = "Observed versus predicted next-year CoC homelessness rate",
    subtitle = paste0(HEADLINE_LABEL, " - the headline model.\n",
                      sprintf("All 555 out-of-time predictions (pooled RMSE %.3f, MAE %.3f, R² %.3f). Dashed line is y = x.",
                              hp_pool$rmse, hp_pool$mae, hp_pool$r2), "\n",
                      paste(ann$lab, collapse = "    |    ")),
    x = "Predicted rate (per 10,000 residents)",
    y = "Observed rate (per 10,000 residents)",
    caption = paste0(CAP_ASSOC,
                     "\nEvery point was predicted by a model trained only on target years strictly earlier than its own; no point is in-sample.",
                     "\nCalifornia supplies 347 of 555 scored rows (63%), so pooled figures are California-weighted.",
                     "\nRMSE is not comparable between the two states: their outcome distributions differ in spread (see FIG_04).")
  ) +
  theme_rep()

save_fig(fig2, "FIG_02_observed_vs_predicted_headline.png", 8.6, 9.2)

## ---------------------------------------------------------------------------
## 9. TABLE 3 + FIG 4 - CALIFORNIA VERSUS FLORIDA
## ---------------------------------------------------------------------------
# RMSE cannot be compared across states with different outcome spreads. Every
# state comparison here therefore also carries the within-state SD of the
# observed outcome and RMSE normalised by it.

state_spread <- preds %>%
  filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE) %>%
  group_by(state) %>%
  summarise(n_scored = n(),
            actual_mean = mean(actual), actual_sd = sd(actual),
            actual_min = min(actual), actual_max = max(actual), .groups = "drop")

t3 <- state_perf %>%
  left_join(state_spread[, c("state", "actual_sd")], by = "state") %>%
  mutate(
    model_family   = model_label[model],
    comparability  = model_class[model],
    rmse_over_sd   = rmse / actual_sd
  ) %>%
  transmute(
    model, lambda_rule, model_family, comparability, state, n,
    rmse = round(rmse, 4), mae = round(mae, 4), r2 = round(r2, 4),
    observed_sd_within_state = round(actual_sd, 4),
    rmse_normalised_by_observed_sd = round(rmse_over_sd, 4)
  ) %>%
  arrange(state, rmse)

t3_spread <- state_spread %>%
  mutate(across(where(is.numeric), ~round(.x, 4)))

wcsv(t3, file.path(TAB, "TABLE_03_state_performance_ca_fl.csv"))
wcsv(t3_spread, file.path(TAB, "TABLE_03b_observed_outcome_spread_by_state.csv"))

fig4_models <- c("pooled_lasso", "pooled_lasso_state_interactions", "separate_state_lasso", "state_time_baseline")
fig4_dat <- t3 %>%
  filter(model %in% fig4_models) %>%
  mutate(lab = paste0(model_family, if_else(lambda_rule == "none", "", paste0("\n(lambda.", lambda_rule, ")")))) %>%
  select(lab, state, rmse, r2, rmse_normalised_by_observed_sd) %>%
  pivot_longer(c(rmse, r2, rmse_normalised_by_observed_sd), names_to = "metric", values_to = "value") %>%
  mutate(metric = factor(metric,
                         c("rmse", "rmse_normalised_by_observed_sd", "r2"),
                         c("RMSE (raw units - NOT comparable across states)",
                           "RMSE / within-state SD of observed rate (comparable)",
                           "Within-state R²")))

fig4 <- ggplot(fig4_dat, aes(value, lab, fill = state)) +
  geom_col(position = position_dodge(width = 0.72), width = 0.66) +
  geom_vline(xintercept = 0, colour = "grey40", linewidth = 0.4) +
  geom_text(aes(label = sprintf("%.2f", value)),
            position = position_dodge(width = 0.72), hjust = -0.15, size = 2.5, colour = "grey25") +
  facet_wrap(~metric, scales = "free_x") +
  scale_fill_manual(values = PAL_STATE, name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0.04, 0.20))) +
  labs(
    title    = "California versus Florida: same models, two different outcome distributions",
    subtitle = paste0(
      sprintf("Observed CoC rate per 10,000: California mean %.1f, SD %.1f, range %.1f-%.1f (n = %d) | Florida mean %.1f, SD %.1f, range %.1f-%.1f (n = %d).",
              state_spread$actual_mean[state_spread$state == "California"], state_spread$actual_sd[state_spread$state == "California"],
              state_spread$actual_min[state_spread$state == "California"],  state_spread$actual_max[state_spread$state == "California"],
              state_spread$n_scored[state_spread$state == "California"],
              state_spread$actual_mean[state_spread$state == "Florida"],    state_spread$actual_sd[state_spread$state == "Florida"],
              state_spread$actual_min[state_spread$state == "Florida"],     state_spread$actual_max[state_spread$state == "Florida"],
              state_spread$n_scored[state_spread$state == "Florida"]),
      "\nFlorida's lower raw RMSE is a narrower outcome distribution, not better explanation. The middle panel rescales RMSE by each state's own SD."),
    x = NULL, y = NULL,
    caption = paste0(CAP_ASSOC,
                     "\nThe state + linear-time baseline has POSITIVE pooled R² (0.190) but NEGATIVE within-state R² in both states (CA -0.126, FL -0.072):",
                     "\nits apparent pooled skill is entirely the CA/FL level gap. No pooled R² in this study should be read as within-state explanatory power.",
                     "\nThe headline unified model is the best unified variant in California but the WEAKEST of the four pooled variants in Florida.")
  ) +
  theme_rep()

save_fig(fig4, "FIG_04_california_vs_florida_performance.png", 14, 7.2)

## ---------------------------------------------------------------------------
## 10. TABLE 4 + FIG 5 - STABLE STANDARDIZED COEFFICIENTS
## ---------------------------------------------------------------------------
# Penalised predictors enter glmnet already standardised on TRAINING rows only
# (build_design() -> std_params(); glmnet called with standardize = FALSE), so a
# penalised coefficient is the change in the target, in rate units per 10,000
# residents, per one training-window SD of that predictor. The two controls are
# unpenalized and NOT standardised, so they are reported separately and are not
# on the same scale.

corr_members <- unique(c(corr_pairs$variable_1, corr_pairs$variable_2))
partner_of <- function(v) {
  p <- c(corr_pairs$variable_2[corr_pairs$variable_1 == v],
         corr_pairs$variable_1[corr_pairs$variable_2 == v])
  if (!length(p)) NA_character_ else paste(sort(unique(p)), collapse = "; ")
}

head_stab <- coef_stab %>% filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE)

t4 <- head_stab %>%
  filter(!grepl(":FL$", term), !grepl("^control_", term)) %>%
  mutate(
    domain               = dom_of(term),
    variation_level      = if_else(is_state_level(term), "State-year (one value repeated across all CoCs in the state)", "CoC-year"),
    in_correlated_pair   = term %in% corr_members,
    correlated_partners  = vapply(term, partner_of, character(1)),
    direction            = if_else(mean_coef >= 0, "Positive", "Negative"),
    attribution_identified = !(in_correlated_pair & selection_freq >= 0.5)
  ) %>%
  transmute(
    term, domain, variation_level,
    n_folds, n_selected, selection_freq,
    mean_coef_all_folds       = round(mean_coef, 5),
    mean_coef_when_selected   = round(mean_coef_when_selected, 5),
    sd_coef_across_folds      = round(sd_coef, 5),
    sign_consistency, direction,
    coefficient_scale = "rate per 10,000 residents per 1 training-window SD of the predictor",
    in_highly_correlated_pair = in_correlated_pair,
    correlated_partners,
    attribution_identified
  ) %>%
  arrange(desc(selection_freq), desc(abs(mean_coef_all_folds)))

t4_controls <- head_stab %>%
  filter(grepl("^control_", term)) %>%
  transmute(term, role = "Unpenalized control (never standardised; not on the standardized-coefficient scale)",
            selection_freq, mean_coef = round(mean_coef, 5), sd_coef = round(sd_coef, 5), sign_consistency)

wcsv(t4, file.path(TAB, "TABLE_04_stable_standardized_coefficients.csv"))
wcsv(t4_controls, file.path(TAB, "TABLE_04b_unpenalized_controls.csv"))

fig5_dat <- t4 %>%
  filter(selection_freq >= 0.5) %>%
  mutate(
    lo = mean_coef_when_selected - sd_coef_across_folds,
    hi = mean_coef_when_selected + sd_coef_across_folds,
    flag = if_else(in_highly_correlated_pair, "* correlated-cluster member", "identified individually"),
    lab = paste0(term, if_else(in_highly_correlated_pair, "  *", ""))
  ) %>%
  arrange(mean_coef_when_selected) %>%
  mutate(lab = factor(lab, levels = lab))

fig5 <- ggplot(fig5_dat, aes(mean_coef_when_selected, lab, colour = direction)) +
  geom_vline(xintercept = 0, colour = "grey40", linewidth = 0.45) +
  geom_linerange(aes(xmin = lo, xmax = hi), linewidth = 0.7, alpha = 0.55) +
  geom_point(aes(size = selection_freq)) +
  geom_text(aes(label = sprintf("%.0f%%", 100 * selection_freq)),
            hjust = -0.75, size = 2.5, colour = "grey30", show.legend = FALSE) +
  facet_grid(domain ~ ., scales = "free_y", space = "free_y", switch = "y") +
  scale_colour_manual(values = PAL_SIGN, name = NULL) +
  scale_size_continuous(range = c(1.8, 3.8), name = "Selection frequency", labels = percent) +
  scale_x_continuous(expand = expansion(mult = c(0.08, 0.14))) +
  labs(
    title    = "Stable standardized coefficients, headline model",
    subtitle = paste0(HEADLINE_LABEL, ". Base (California-reference) terms selected in at least half of the eight folds.\n",
                      "Point = mean coefficient in folds where the term was selected; bar = ±1 SD across folds; label = selection frequency.\n",
                      "Units: change in the next-year rate per 10,000 residents per one training-window SD of the predictor."),
    x = "Standardized coefficient", y = NULL,
    caption = paste0(CAP_ASSOC,
                     "\n* marks a member of a predictor pair with |r| >= 0.80 in the v2 EDA. LASSO chooses among near-collinear columns close to arbitrarily:",
                     "\nread these as markers for a correlated cluster (CoC geographic scale, population change, permit volume), never as the operative variable.",
                     "\nService-capacity beds are the two largest coefficients here and are plausibly ENDOGENOUS to the outcome - capacity is built where homelessness",
                     "\nis already high, and sheltered PIT counts are enumerated in those beds. See FIG_07 / the structural-only sensitivity.")
  ) +
  theme_rep() +
  theme(strip.placement = "outside", strip.text.y.left = element_text(angle = 0, hjust = 1))

save_fig(fig5, "FIG_05_stable_standardized_coefficients.png", 12, 8.6)

## ---------------------------------------------------------------------------
## 11. TABLE 5 + FIG 6 - STATE-INTERACTION COEFFICIENTS
## ---------------------------------------------------------------------------
# In the headline design, a predictor's California-reference slope is its base
# term and its Florida slope is base + ":FL". Fold-mean coefficients (including
# zero in folds where a term was not selected) are the quantity that adds.

base_tbl <- head_stab %>% filter(!grepl(":FL$", term), !grepl("^control_", term)) %>%
  transmute(predictor = term, base_mean = mean_coef, base_selfreq = selection_freq,
            base_sign_consistency = sign_consistency)
int_tbl <- head_stab %>% filter(grepl(":FL$", term)) %>%
  transmute(predictor = base_term(term), int_mean = mean_coef, int_selfreq = selection_freq,
            int_sign_consistency = sign_consistency, int_sd = sd_coef)

t5 <- base_tbl %>%
  full_join(int_tbl, by = "predictor") %>%
  mutate(
    domain            = dom_of(predictor),
    ca_slope          = base_mean,
    fl_slope          = base_mean + int_mean,
    interaction_selected_at_least_half = int_selfreq >= 0.5,
    interpretation = case_when(
      int_selfreq == 0                      ~ "No state-specific slope retained: the pooled slope applies to both states",
      sign(ca_slope) == sign(fl_slope)      ~ "Same direction in both states, different magnitude",
      TRUE                                  ~ "Direction differs between states (small magnitudes; treat cautiously)"
    )
  ) %>%
  transmute(
    predictor, domain,
    base_selection_freq = base_selfreq, base_sign_consistency,
    interaction_selection_freq = int_selfreq, interaction_sign_consistency = int_sign_consistency,
    california_slope_mean = round(ca_slope, 5),
    florida_interaction_mean = round(int_mean, 5),
    florida_slope_mean = round(fl_slope, 5),
    interaction_sd_across_folds = round(int_sd, 5),
    interaction_selected_at_least_half, interpretation
  ) %>%
  arrange(desc(interaction_selection_freq), desc(abs(florida_interaction_mean)))

wcsv(t5, file.path(TAB, "TABLE_05_state_interaction_coefficients.csv"))

fig6_dat <- t5 %>%
  filter(interaction_selection_freq >= 0.5 | base_selection_freq >= 0.5) %>%
  filter(interaction_selection_freq > 0) %>%
  select(predictor, domain, California = california_slope_mean, Florida = florida_slope_mean,
         int_sf = interaction_selection_freq) %>%
  pivot_longer(c(California, Florida), names_to = "state", values_to = "slope")

ord6 <- fig6_dat %>% group_by(predictor) %>% summarise(m = max(abs(slope))) %>% arrange(m) %>% pull(predictor)
fig6_dat$predictor <- factor(fig6_dat$predictor, levels = ord6)

fig6_seg <- fig6_dat %>% pivot_wider(names_from = state, values_from = slope)

fig6 <- ggplot(fig6_dat, aes(slope, predictor)) +
  geom_vline(xintercept = 0, colour = "grey40", linewidth = 0.45) +
  geom_segment(data = fig6_seg, aes(x = California, xend = Florida, y = predictor, yend = predictor),
               inherit.aes = FALSE, colour = "grey75", linewidth = 0.8) +
  geom_point(aes(colour = state), size = 3) +
  geom_text(data = fig6_seg, aes(x = pmax(California, Florida), y = predictor,
                                 label = sprintf("interaction selected in %.0f%% of folds", 100 * int_sf)),
            inherit.aes = FALSE, hjust = -0.08, size = 2.4, colour = "grey35") +
  scale_colour_manual(values = PAL_STATE, name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0.06, 0.55))) +
  labs(
    title    = "State-interaction coefficients: implied California and Florida slopes",
    subtitle = paste0(HEADLINE_LABEL, ". Shown for the predictors whose Florida interaction term was ever selected.\n",
                      "California slope = fold-mean base coefficient. Florida slope = base + Florida interaction. Both on the standardized scale.\n",
                      "Fold means include zeros for folds where a term was not selected, so the two components add exactly."),
    x = "Implied standardized slope (rate per 10,000 per 1 training-window SD)", y = NULL,
    caption = paste0(CAP_ASSOC,
                     "\nA non-zero interaction means the association differs between the two states IN THIS MODEL - it is not evidence that a mechanism",
                     "\ndiffers between the states. With two states, a state interaction is indistinguishable from any other state-level difference,",
                     "\nincluding differences in PIT enumeration practice, CoC composition and the state-level predictors that repeat within each state.",
                     "\nThe unified interaction model is also the WEAKEST of the four pooled variants within Florida; see FIG_04 before reading the FL slopes.")
  ) +
  theme_rep()

save_fig(fig6, "FIG_06_state_interaction_coefficients.png", 12.5, 6.8)

## ---------------------------------------------------------------------------
## 12. TABLE 6 + FIG 7 - SENSITIVITY COMPARISON
## ---------------------------------------------------------------------------

sample_label <- c(
  S0_primary                = "S0 Primary (887 rows, 70 CoCs)",
  S1_split_county_excluded  = "S1 Split-county CoCs excluded (796)",
  S2_stable_cocs            = "S2 Continuously observed CoCs (845)",
  S3_no_structural_beds     = "S3 Service capacity removed (887)",
  S4_persistence            = "S4 Persistence-eligible rows (817)",
  S4b_persistence_full_enum = "S4b Persistence, full enumeration (666)",
  S5_no_hpi_fl518           = "S5 No FHFA HPI, FL-518 restored (898)"
)

t6_own <- sens_pooled %>%
  filter(model %in% c("pooled_lasso", "pooled_lasso_state_interactions")) %>%
  left_join(sens_samples %>%
              transmute(sample_id, label, selection_rule,
                        sample_rows = n_rows, sample_cocs = n_cocs, sample_predictors = n_predictors),
            by = "sample_id") %>%
  transmute(
    sample_id, sample_label = label, selection_rule,
    sample_rows, sample_cocs, sample_predictors,
    model, lambda_rule, scored_rows = n,
    rmse = round(rmse, 4), mae = round(mae, 4), r2 = round(r2, 4),
    mean_nonzero_penalized_per_fold,
    comparison_basis = "each sample's own scored rows (row sets differ; not like-for-like except S3)"
  )

t6_common <- sens_common %>%
  filter(model %in% c("pooled_lasso", "pooled_lasso_state_interactions")) %>%
  transmute(
    sample_id, model, lambda_rule,
    n_common_rows, n_common_cocs,
    sens_rmse = round(sens_rmse, 4), primary_rmse = round(primary_rmse, 4),
    rmse_diff_sens_minus_primary = round(rmse_diff_sens_minus_primary, 4),
    sens_r2 = round(sens_r2, 4), primary_r2 = round(primary_r2, 4),
    r2_diff_sens_minus_primary = round(r2_diff_sens_minus_primary, 4),
    pred_correlation = round(pred_correlation, 4),
    comparison_basis = "rows present in BOTH the sensitivity sample and the primary model (like-for-like)"
  )

wcsv(t6_own,    file.path(TAB, "TABLE_06_sensitivity_comparison_own_rows.csv"))
wcsv(t6_common, file.path(TAB, "TABLE_06b_sensitivity_comparison_common_rows.csv"))

fig7a <- sens_pooled %>%
  filter(model %in% c("pooled_lasso", "pooled_lasso_state_interactions")) %>%
  mutate(sample = factor(sample_label[sample_id], levels = rev(sample_label)),
         spec   = paste0(if_else(model == "pooled_lasso", "Pooled LASSO", "Pooled + interactions"),
                         " (lambda.", lambda_rule, ")")) %>%
  ggplot(aes(rmse, sample, colour = spec, shape = spec)) +
  geom_point(size = 2.6, position = position_dodge(width = 0.55)) +
  scale_colour_manual(values = c("#2B6CB0", "#90CDF4", "#276749", "#9AE6B4"), name = NULL) +
  scale_shape_manual(values = c(16, 1, 17, 2), name = NULL) +
  labs(subtitle = "A. Pooled out-of-time RMSE within each sensitivity sample\n(row sets differ between samples, so absolute levels are not strictly comparable)",
       x = "RMSE (per 10,000 residents)", y = NULL) +
  theme_rep() + guides(colour = guide_legend(nrow = 2), shape = guide_legend(nrow = 2))

fig7b_dat <- sens_common %>%
  filter(model %in% c("pooled_lasso", "pooled_lasso_state_interactions")) %>%
  bind_rows(
    # S3 shares the primary model's exact rows and folds, so its own-row
    # comparison IS the like-for-like one; the common-rows file omits it.
    sens_pooled %>%
      filter(sample_id == "S3_no_structural_beds",
             model %in% c("pooled_lasso", "pooled_lasso_state_interactions")) %>%
      left_join(sens_pooled %>% filter(sample_id == "S0_primary") %>%
                  select(model, lambda_rule, primary_rmse = rmse), by = c("model", "lambda_rule")) %>%
      transmute(sample_id, model, lambda_rule, n_common_rows = n,
                sens_rmse = rmse, primary_rmse,
                rmse_diff_sens_minus_primary = rmse - primary_rmse)
  ) %>%
  mutate(sample = factor(sample_label[sample_id], levels = rev(sample_label)),
         spec   = paste0(if_else(model == "pooled_lasso", "Pooled LASSO", "Pooled + interactions"),
                         " (lambda.", lambda_rule, ")"))

fig7b <- ggplot(fig7b_dat, aes(rmse_diff_sens_minus_primary, sample, colour = spec, shape = spec)) +
  geom_vline(xintercept = 0, colour = "grey40", linewidth = 0.5) +
  geom_point(size = 2.6, position = position_dodge(width = 0.55)) +
  scale_colour_manual(values = c("#2B6CB0", "#90CDF4", "#276749", "#9AE6B4"), name = NULL) +
  scale_shape_manual(values = c(16, 1, 17, 2), name = NULL) +
  labs(subtitle = "B. Change in RMSE versus the primary model on rows the two samples share\n(worse to the right; this is the like-for-like comparison)",
       x = "RMSE difference: sensitivity minus primary", y = NULL) +
  theme_rep() + guides(colour = guide_legend(nrow = 2), shape = guide_legend(nrow = 2))

# Simple stacked layout without extra packages.
fig7_path <- file.path(FIG, "FIG_07_sensitivity_comparison.png")
write_owned(fig7_path)
grDevices::png(fig7_path, width = 12, height = 11.4, units = "in", res = 200, type = PNG_TYPE, bg = "white")
grid::grid.newpage()
grid::pushViewport(grid::viewport(layout = grid::grid.layout(
  3, 1, heights = grid::unit(c(1.35, 4.4, 4.4), "null"))))
grid::pushViewport(grid::viewport(layout.pos.row = 1, layout.pos.col = 1))
grid::grid.text("Sensitivity analysis: how the results move under alternative samples and predictor sets",
                x = 0.02, y = 0.86, just = c("left", "top"),
                gp = grid::gpar(fontface = "bold", fontsize = 15))
grid::grid.text(paste(
  "S1, S2 and S5 change WHICH ROWS are modelled. S3 changes only the PREDICTOR SET and keeps the primary model's exact 887 rows and 8 folds.",
  "S4/S4b restrict to rows with a reliable prior-year PIT rate; their factor models here EXCLUDE that prior rate (the persistence comparison is separate).",
  "Sample construction (S1, S2, S5) leaves accuracy and the leading predictors essentially unchanged. Removing service capacity (S3) does not.",
  sep = "\n"),
  x = 0.02, y = 0.52, just = c("left", "top"), gp = grid::gpar(fontsize = 9.5, col = "grey25"))
grid::popViewport()
grid::pushViewport(grid::viewport(layout.pos.row = 2, layout.pos.col = 1)); print(fig7a, newpage = FALSE); grid::popViewport()
grid::pushViewport(grid::viewport(layout.pos.row = 3, layout.pos.col = 1)); print(fig7b, newpage = FALSE); grid::popViewport()
grDevices::dev.off()
message("  figure: ", fig7_path)

## Supplementary: persistence benchmark, reported separately because it answers
## a different question (does the factor set add anything beyond last year's rate?).
t9 <- sens_persist %>%
  mutate(comparison_label = recode(comparison,
    a_prior_rate_only                          = "(a) Prior-year rate only",
    b_state_time_prior_rate                    = "(b) State + time + prior rate",
    c_factor_lasso_plus_prior_min              = "(c) 38-factor LASSO + prior rate (lambda.min)",
    c_factor_lasso_plus_prior_1se              = "(c) 38-factor LASSO + prior rate (lambda.1se)",
    c_factor_lasso_interactions_plus_prior_min = "(c') + state interactions + prior rate (lambda.min)",
    c_factor_lasso_interactions_plus_prior_1se = "(c') + state interactions + prior rate (lambda.1se)",
    factor_lasso_without_prior_min             = "Factor LASSO WITHOUT prior rate (lambda.min)",
    factor_lasso_without_prior_1se             = "Factor LASSO WITHOUT prior rate (lambda.1se)",
    state_time_baseline_reference              = "State + linear-time baseline")) %>%
  transmute(sample_id, comparison, comparison_label, lambda_rule, n,
            rmse = round(rmse, 4), mae = round(mae, 4), r2 = round(r2, 4),
            mean_nonzero_penalized_per_fold,
            rmse_diff_vs_persistence_baseline = round(rmse_diff_vs_persistence_baseline, 6))

wcsv(t9, file.path(TAB, "TABLE_09_persistence_benchmark.csv"))

fig9_dat <- t9 %>%
  filter(sample_id == "S4_persistence",
         comparison %in% c("a_prior_rate_only", "b_state_time_prior_rate",
                           "c_factor_lasso_plus_prior_min", "c_factor_lasso_interactions_plus_prior_min",
                           "factor_lasso_without_prior_min", "state_time_baseline_reference")) %>%
  arrange(rmse) %>%
  mutate(comparison_label = factor(comparison_label, levels = rev(comparison_label)),
         grp = case_when(grepl("WITHOUT", comparison_label)                   ~ "Factors only, no prior rate",
                         grepl("baseline", comparison_label, ignore.case = TRUE) ~ "Baseline",
                         grepl("prior", comparison_label, ignore.case = TRUE)  ~ "Has the CoC's own prior-year rate",
                         TRUE                                                  ~ "Factors only, no prior rate"))

fig9 <- ggplot(fig9_dat, aes(rmse, comparison_label, fill = grp)) +
  geom_col(width = 0.62) +
  geom_text(aes(label = sprintf("RMSE %.2f   R² %.3f%s", rmse, r2,
                                if_else(!is.na(mean_nonzero_penalized_per_fold) & mean_nonzero_penalized_per_fold == 0,
                                        "   (all 38 factors shrunk to zero)", ""))),
            hjust = -0.03, size = 2.9, colour = "grey20") +
  scale_fill_manual(values = c("Has the CoC's own prior-year rate" = "#2F855A",
                               "Factors only, no prior rate"       = "#2B6CB0",
                               "Baseline"                          = "#A0AEC0"), name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0.02, 0.42))) +
  labs(
    title    = "Persistence benchmark: the factor set adds nothing once last year's rate is known",
    subtitle = paste0("Sample S4 (817 rows, 485 scored, 7 folds - validation year 2022 drops because every predictor_year 2021 row is ineligible).\n",
                      "The prior rate is each CoC's own rate in its predictor year t; the target is year t+1, so no future value is used.\n",
                      "Given the prior rate as an unpenalized control, nested forward-chaining tuning shrank all 38 factors and all state\n",
                      "interactions to exactly zero in all 7 folds, under both lambda rules, in both eligibility samples (S4 and S4b)."),
    x = "RMSE (per 10,000 residents)", y = NULL,
    caption = paste0(CAP_ASSOC,
                     "\nThis does not make the factor associations uninformative about which local conditions co-move with homelessness levels.",
                     "\nIt does mean the factor set must not be presented as improving short-horizon prediction.")
  ) +
  theme_rep()

save_fig(fig9, "FIG_09_persistence_benchmark.png", 12.5, 6.4)

## ---------------------------------------------------------------------------
## 13. TABLE 7 + FIG 8 - RESIDUALS BY YEAR AND STATE
## ---------------------------------------------------------------------------

t7 <- hp %>%
  group_by(validation_year, state) %>%
  summarise(n = n(),
            mean_residual = mean(residual), sd_residual = sd(residual),
            median_residual = median(residual),
            mean_abs_residual = mean(abs(residual)),
            max_abs_residual = max(abs(residual)),
            rmse = sqrt(mean(residual^2)),
            .groups = "drop") %>%
  bind_rows(
    hp %>% group_by(validation_year) %>%
      summarise(state = "Both states", n = n(),
                mean_residual = mean(residual), sd_residual = sd(residual),
                median_residual = median(residual),
                mean_abs_residual = mean(abs(residual)),
                max_abs_residual = max(abs(residual)),
                rmse = sqrt(mean(residual^2)), .groups = "drop")
  ) %>%
  mutate(model = HEADLINE_MODEL, lambda_rule = HEADLINE_RULE,
         residual_definition = "observed minus predicted (positive = model under-predicts)",
         across(where(is.numeric), ~round(.x, 4))) %>%
  arrange(validation_year, state)

wcsv(t7, file.path(TAB, "TABLE_07_residuals_by_year_and_state.csv"))

fig8a <- ggplot(hp, aes(factor(validation_year), residual, fill = state)) +
  geom_hline(yintercept = 0, colour = "grey40", linewidth = 0.5) +
  geom_boxplot(outlier.size = 0.9, outlier.alpha = 0.6, width = 0.68, linewidth = 0.35, alpha = 0.85) +
  facet_wrap(~state, ncol = 1) +
  scale_fill_manual(values = PAL_STATE, guide = "none") +
  labs(
    title    = "Residuals by validation year and state",
    subtitle = paste0(HEADLINE_LABEL, ". Residual = observed minus predicted; positive means the model under-predicts.\n",
                      "2021 has no box because the COVID-disrupted 2021 PIT count is excluded as a modelling target."),
    x = "Validation (target) year", y = "Residual (per 10,000 residents)",
    caption = paste0(CAP_ASSOC,
                     "\nCalifornia residuals are wider throughout, matching California's wider observed CoC-rate distribution rather than indicating a different model quality.")
  ) +
  theme_rep()

save_fig(fig8a, "FIG_08a_residuals_by_year_and_state.png", 10.5, 8)

fig8b <- ggplot(hp, aes(predicted, residual, colour = state)) +
  geom_hline(yintercept = 0, colour = "grey40", linewidth = 0.5) +
  geom_point(alpha = 0.6, size = 1.6) +
  geom_smooth(method = "loess", formula = y ~ x, se = FALSE, linewidth = 0.7, colour = "grey25") +
  facet_grid(state ~ ., scales = "free_y") +
  scale_colour_manual(values = PAL_STATE, guide = "none") +
  labs(
    title    = "Residuals versus predicted value, by state",
    subtitle = paste0(HEADLINE_LABEL, ". Smoother is descriptive only (loess, no inference).\n",
                      "Fanning at higher predicted rates indicates the model is least reliable for the highest-rate CoCs."),
    x = "Predicted rate (per 10,000 residents)", y = "Residual (per 10,000 residents)",
    caption = CAP_ASSOC
  ) +
  theme_rep()

save_fig(fig8b, "FIG_08b_residuals_vs_predicted_by_state.png", 10, 8)

## ---------------------------------------------------------------------------
## 14. TABLE 8 - ROBUST PREDICTOR MATRIX
## ---------------------------------------------------------------------------
# Every sensitivity sample was fitted as a POOLED LASSO, so the sensitivity
# columns are all read from pooled_lasso / lambda.min - a single, comparable
# specification. The headline interaction model's own base-term frequency is
# reported alongside it, and the two are not interchangeable.

sw <- sens_selwide %>% filter(model == "pooled_lasso", lambda_rule == "min")

pooled_primary <- coef_stab %>%
  filter(model == "pooled_lasso", lambda_rule == "min", !grepl("^control_", term)) %>%
  transmute(term,
            main_pooled_selfreq = selection_freq,
            main_pooled_mean_coef = mean_coef,
            main_pooled_sign_consistency = sign_consistency)

headline_primary <- coef_stab %>%
  filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE,
         !grepl(":FL$", term), !grepl("^control_", term)) %>%
  transmute(term,
            main_headline_selfreq = selection_freq,
            main_headline_mean_coef = mean_coef,
            main_headline_sign_consistency = sign_consistency)

headline_int <- coef_stab %>%
  filter(model == HEADLINE_MODEL, lambda_rule == HEADLINE_RULE, grepl(":FL$", term)) %>%
  transmute(term = base_term(term), headline_fl_interaction_selfreq = selection_freq)

stable_flag <- sens_stable %>%
  filter(lambda_rule == "min", role == "penalized_predictor") %>%
  transmute(term, n_samples_available, min_selection_freq, mean_selection_freq,
            sign_agreement, stable_across_all_samples)

sens_cols <- sw %>%
  select(term,
         S1 = selfreq_S1_split_county_excluded,  S1_sign = sign_S1_split_county_excluded,
         S2 = selfreq_S2_stable_cocs,            S2_sign = sign_S2_stable_cocs,
         S3 = selfreq_S3_no_structural_beds,     S3_sign = sign_S3_no_structural_beds,
         S4 = selfreq_S4_persistence,            S4_sign = sign_S4_persistence,
         S4b = selfreq_S4b_persistence_full_enum, S4b_sign = sign_S4b_persistence_full_enum,
         S5 = selfreq_S5_no_hpi_fl518,           S5_sign = sign_S5_no_hpi_fl518,
         S0 = selfreq_S0_primary,                S0_sign = sign_S0_primary)

avail <- sens_avail %>%
  transmute(term = predictor,
            available_S1 = S1_split_county_excluded == 1,
            available_S2 = S2_stable_cocs == 1,
            available_S3 = S3_no_structural_beds == 1,
            available_S4 = S4_persistence == 1,
            available_S4b = S4b_persistence_full_enum == 1,
            available_S5 = S5_no_hpi_fl518 == 1)

t8 <- headline_primary %>%
  full_join(pooled_primary, by = "term") %>%
  full_join(headline_int, by = "term") %>%
  left_join(sens_cols, by = "term") %>%
  left_join(avail, by = "term") %>%
  left_join(stable_flag, by = "term") %>%
  mutate(
    domain          = dom_of(term),
    variation_level = if_else(is_state_level(term), "State-year (repeated across CoCs)", "CoC-year"),
    in_highly_correlated_pair = term %in% corr_members,
    correlated_partners = vapply(term, partner_of, character(1)),
    direction_main = case_when(main_pooled_selfreq == 0 ~ NA_character_,
                               main_pooled_mean_coef > 0 ~ "positive",
                               TRUE ~ "negative"),
    n_sens_available = rowSums(cbind(available_S1, available_S2, available_S3,
                                     available_S4, available_S4b, available_S5), na.rm = TRUE),
    n_sens_selected_half = rowSums(cbind(S1 >= .5, S2 >= .5, S3 >= .5, S4 >= .5, S4b >= .5, S5 >= .5), na.rm = TRUE),
    n_selected_ever = rowSums(cbind(main_pooled_selfreq > 0, S0 > 0, S1 > 0, S2 > 0,
                                    S3 > 0, S4 > 0, S4b > 0, S5 > 0), na.rm = TRUE),
    # isTRUE() is scalar-only; the vectorised test is `%in% TRUE`, which also
    # treats NA (predictor absent from the stability file) as not stable.
    robustness_class = case_when(
      stable_across_all_samples %in% TRUE                      ~ "A. Stable in every sample where available (>=50% of folds and the same sign throughout)",
      main_pooled_selfreq >= 0.5 & n_sens_selected_half >= 4   ~ "B. Frequently selected in the main model; falls below 50% in one or two samples",
      main_pooled_selfreq >= 0.5                               ~ "C. Selected in the main model but not carried by the sensitivity samples",
      n_sens_selected_half >= 1                                ~ "D. Sensitivity-only: below 50% in the main model; reaches 50% only under an alternative sample or predictor set",
      n_selected_ever > 0                                      ~ "E. Occasionally selected but never in half the folds of any sample",
      TRUE                                                     ~ "F. Never selected in any sample"
    )
  ) %>%
  transmute(
    predictor = term, domain, variation_level,
    main_headline_selfreq, main_headline_mean_coef = round(main_headline_mean_coef, 5),
    main_headline_sign_consistency, headline_fl_interaction_selfreq,
    main_pooled_selfreq, main_pooled_mean_coef = round(main_pooled_mean_coef, 5),
    main_pooled_sign_consistency, direction_main,
    sens_S1_split_county = S1,        sens_S1_sign = S1_sign,   available_S1,
    sens_S2_stable_cocs = S2,         sens_S2_sign = S2_sign,   available_S2,
    sens_S3_structural_only = S3,     sens_S3_sign = S3_sign,   available_S3,
    sens_S4_persistence_adjusted = S4, sens_S4_sign = S4_sign,  available_S4,
    sens_S4b_persistence_strict = S4b, sens_S4b_sign = S4b_sign, available_S4b,
    sens_S5_no_hpi = S5,              sens_S5_sign = S5_sign,   available_S5,
    n_sens_available, n_sens_selected_half,
    sign_agreement_across_samples = sign_agreement,
    stable_across_all_samples,
    in_highly_correlated_pair, correlated_partners,
    attribution_identified = !(in_highly_correlated_pair & main_pooled_selfreq >= 0.5),
    robustness_class,
    selfreq_when_prior_year_rate_is_available = 0,
    prior_rate_note = "With each CoC's own prior-year rate present as an unpenalized control, EVERY candidate factor and every state interaction is shrunk to exactly zero in all 7 folds, under both lambda rules, in both S4 and S4b."
  ) %>%
  arrange(desc(main_pooled_selfreq), desc(n_sens_selected_half), predictor)

stopifnot(nrow(t8) == 38)
wcsv(t8, file.path(TAB, "TABLE_08_robust_predictor_matrix.csv"))

# Compact printable version of the same matrix.
t8_compact <- t8 %>%
  transmute(predictor, domain,
            main_model = sprintf("%.2f (%s)", main_pooled_selfreq, ifelse(is.na(direction_main), "-", direction_main)),
            sign_consistency = sprintf("%.2f", main_pooled_sign_consistency),
            split_county = ifelse(available_S1, sprintf("%.2f", sens_S1_split_county), "n/a"),
            stable_coc   = ifelse(available_S2, sprintf("%.2f", sens_S2_stable_cocs), "n/a"),
            structural_only = ifelse(available_S3, sprintf("%.2f", sens_S3_structural_only), "n/a"),
            persistence_adj = ifelse(available_S4, sprintf("%.2f", sens_S4_persistence_adjusted), "n/a"),
            no_hpi = ifelse(available_S5, sprintf("%.2f", sens_S5_no_hpi), "n/a"),
            robustness_class)
wcsv(t8_compact, file.path(TAB, "TABLE_08b_robust_predictor_matrix_compact.csv"))

## ---------------------------------------------------------------------------
## 15. TABLE 10 - REPORTING CONSTRAINTS (data caveats + audit warnings)
## ---------------------------------------------------------------------------

constraints <- tibble::tribble(
  ~id, ~category, ~constraint, ~observed, ~how_reported, ~source,
  "C1", "Sample construction", "2021 PIT excluded as a modelling target",
  "No target_year 2021 rows; validation years are 2017-2020 and 2022-2025 (8 folds, not 9).",
  "Stated wherever folds or years appear; the gap is visible in FIG_03 and FIG_08a.",
  "FINAL_run_manifest.csv; EDA_FINDINGS_v2.md s1",

  "C2", "Geography", "FY2024 CoC boundaries applied retrospectively to 2010-2025",
  "Historical CoC mergers/splits remain a measurement-error source; CA-528 (3 PIT rows) has no FY2024 denominator and is dropped before the candidate panel.",
  "Reported as a standing limitation; not corrected, not imputed.",
  "COC_BOUNDARY_DIAGNOSTICS.md",

  "C3", "Sample construction", "FL-518 excluded from the primary model",
  "FL-518 has no usable FHFA local home-price index (member counties never reach the 40% weighted-coverage floor); requiring that predictor drops 11 rows and the whole CoC, giving 887 rows / 70 CoCs instead of 898 / 71.",
  "Stated in the primary results and tested directly in sensitivity S5, which restores FL-518 by dropping the index.",
  "COC_BOUNDARY_DIAGNOSTICS.md; SENSITIVITY_FINDINGS.md s6",

  "C4", "Measurement", "Split-county allocation uses fractional ACS 2024 tract-population shares",
  "8 FY2024 CoCs split a county (CA-600, CA-606, CA-607, CA-612, FL-506, FL-508, FL-510, FL-518); 91 rows carry the flag in the primary panel. Their county-derived predictors are estimates, not observed CoC values.",
  "Flag retained in the data and tested directly in sensitivity S1.",
  "COC_BOUNDARY_DIAGNOSTICS.md; SENSITIVITY_FINDINGS.md s2",

  "C5", "Predictor structure", "State-level predictors repeat across every CoC in a state",
  "8 state_* predictors carry one value per state-year, repeated across all of that state's CoCs. The unpenalized state and time controls absorb most of what they can contribute; several are never selected.",
  "Non-selection of a state_* predictor is reported as uninformative, not as evidence of no relationship.",
  "EDA_FINDINGS_v2.md s5-s6; SENSITIVITY_FINDINGS.md s7",

  "C6", "Design", "Limited two-state time structure",
  "Two states, 70 CoCs, 13 usable target years, 887 rows, 8 out-of-time folds. A state interaction is indistinguishable from any other state-level difference.",
  "No causal claim is made anywhere; state interactions are described as model terms, not mechanisms.",
  "AGENTS.md modelling guidance; EDA_FINDINGS_v2.md",

  "C7", "Claim wording", "'Best model' is criterion-dependent",
  "The headline model has the lowest unified RMSE (14.692) and highest R2 (0.636) but the FOURTH-lowest MAE among unified variants (10.141 vs 9.805 for pooled_lasso/1se).",
  "Reported as best-on-RMSE among unified models, never as best outright.",
  "AUDIT_REPORT.md check 10.3",

  "C8", "Claim wording", "'Unified' is load-bearing",
  "The separate-state composite scores better overall (RMSE 13.902, R2 0.674) than the best unified model (14.692, 0.636), but it is the concatenation of two single-state models, not one model.",
  "Both are reported; the qualifier is never dropped.",
  "AUDIT_REPORT.md check 10.6",

  "C9", "Metric interpretation", "Pooled R2 is not within-state explanatory power",
  "The state + linear-time baseline has pooled R2 0.190 but within-state R2 of -0.126 (CA) and -0.072 (FL). Its pooled skill is entirely the CA/FL level gap.",
  "Every pooled R2 is reported alongside within-state figures; FIG_04 carries the warning.",
  "AUDIT_REPORT.md check 11.5",

  "C10", "Claim wording", "The headline model is not best within Florida",
  "In Florida it is the weakest of the four pooled variants (RMSE 10.386, R2 0.376) versus pooled_lasso/1se (8.472, 0.585). Its overall win is carried by California, which supplies 63% of scored rows.",
  "Stated wherever the headline model is named.",
  "AUDIT_REPORT.md check 11.6",

  "C11", "Attribution", "Correlated predictors are not individually identified",
  "18 predictor pairs have |r| >= 0.80. Three frequently selected predictors are pair members: coc_population_growth_rate_pct, coc_real_gdp_quantity_index, coc_permits_value_per_1000_housing_units_2025_usd. No pair has both members frequently selected.",
  "Selected members are reported as markers for a correlated cluster, never as the operative variable.",
  "AUDIT_REPORT.md checks 13.2/13.4; EDA_FINDINGS_v2.md s8",

  "C12", "Preprocessing", "Log-target shift constant read from the full column",
  "min(target) over all 887 rows = 4.83 > 0, so the shift is identically 0 in every fold. No information crosses the split.",
  "Recorded for transparency; no numerical effect on any reported result.",
  "AUDIT_REPORT.md check 6.7",

  "C13", "Endogeneity", "Service-capacity predictors are plausibly endogenous to the outcome",
  "The two HIC bed rates are the largest coefficients in the headline model and account for roughly a third of its out-of-time R2 (RMSE 14.692 -> 17.822 when removed on identical rows).",
  "Service-capacity associations are reported separately from structural housing/economic factors throughout; S3 is the conservative statement.",
  "SENSITIVITY_FINDINGS.md s4",

  "C14", "Predictive value", "The factor set adds nothing beyond persistence",
  "With each CoC's own prior-year rate available, all 38 factors and all state interactions are shrunk to exactly zero in all 7 folds, under both lambda rules, in both eligibility samples.",
  "Reported as a primary limitation on the model's predictive usefulness, not buried in the sensitivity section.",
  "SENSITIVITY_FINDINGS.md s5"
)

wcsv(as.data.frame(constraints), file.path(TAB, "TABLE_10_reporting_constraints.csv"))

## ---------------------------------------------------------------------------
## 16. KEY NUMBERS (every figure quoted in the narrative, with its source)
## ---------------------------------------------------------------------------

g_ovr <- function(m, r, col) metrics_overall[[col]][metrics_overall$model == m & metrics_overall$lambda_rule == r][1]
g_st  <- function(m, r, s, col) state_perf[[col]][state_perf$model == m & state_perf$lambda_rule == r & state_perf$state == s][1]
g_sen <- function(sid, m, r, col) sens_pooled[[col]][sens_pooled$sample_id == sid & sens_pooled$model == m & sens_pooled$lambda_rule == r][1]

key <- tibble::tribble(
  ~key, ~value, ~source,
  "input_workbook",              V2_PATH,                                          "FINAL_run_manifest.csv",
  "input_md5_live_and_recorded", V2_MD5_LIVE,                                      "tools::md5sum + FINAL_run_manifest.csv",
  "n_rows",                      mf[["n_rows"]],                                   "FINAL_run_manifest.csv",
  "n_cocs",                      mf[["n_cocs"]],                                   "FINAL_run_manifest.csv",
  "n_predictors",                mf[["n_predictors"]],                             "FINAL_run_manifest.csv",
  "n_outer_folds",               mf[["n_outer_folds"]],                            "FINAL_run_manifest.csv",
  "validation_years",            mf[["outer_validation_years"]],                   "FINAL_run_manifest.csv",
  "n_scored_rows",               as.character(sum(preds$model == HEADLINE_MODEL & preds$lambda_rule == HEADLINE_RULE)), "FINAL_predictions.csv",
  "n_scored_CA",                 as.character(g_st(HEADLINE_MODEL, HEADLINE_RULE, "California", "n")), "FINAL_ca_fl_state_performance.csv",
  "n_scored_FL",                 as.character(g_st(HEADLINE_MODEL, HEADLINE_RULE, "Florida", "n")),    "FINAL_ca_fl_state_performance.csv",
  "headline_rmse",               sprintf("%.4f", g_ovr(HEADLINE_MODEL, HEADLINE_RULE, "rmse")),        "FINAL_metrics_overall_out_of_time.csv",
  "headline_mae",                sprintf("%.4f", g_ovr(HEADLINE_MODEL, HEADLINE_RULE, "mae")),         "FINAL_metrics_overall_out_of_time.csv",
  "headline_r2",                 sprintf("%.4f", g_ovr(HEADLINE_MODEL, HEADLINE_RULE, "r2")),          "FINAL_metrics_overall_out_of_time.csv",
  "best_unified_mae_model",      "pooled_lasso / 1se",                                                 "FINAL_metrics_overall_out_of_time.csv",
  "best_unified_mae",            sprintf("%.4f", g_ovr("pooled_lasso", "1se", "mae")),                 "FINAL_metrics_overall_out_of_time.csv",
  "separate_state_rmse",         sprintf("%.4f", g_ovr("separate_state_lasso", "1se", "rmse")),        "FINAL_metrics_overall_out_of_time.csv",
  "separate_state_r2",           sprintf("%.4f", g_ovr("separate_state_lasso", "1se", "r2")),          "FINAL_metrics_overall_out_of_time.csv",
  "baseline_rmse",               sprintf("%.4f", g_ovr("state_time_baseline", "none", "rmse")),        "FINAL_metrics_overall_out_of_time.csv",
  "baseline_pooled_r2",          sprintf("%.4f", g_ovr("state_time_baseline", "none", "r2")),          "FINAL_metrics_overall_out_of_time.csv",
  "baseline_r2_CA",              sprintf("%.4f", g_st("state_time_baseline", "none", "California", "r2")), "FINAL_ca_fl_state_performance.csv",
  "baseline_r2_FL",              sprintf("%.4f", g_st("state_time_baseline", "none", "Florida", "r2")),    "FINAL_ca_fl_state_performance.csv",
  "headline_rmse_CA",            sprintf("%.4f", g_st(HEADLINE_MODEL, HEADLINE_RULE, "California", "rmse")), "FINAL_ca_fl_state_performance.csv",
  "headline_r2_CA",              sprintf("%.4f", g_st(HEADLINE_MODEL, HEADLINE_RULE, "California", "r2")),   "FINAL_ca_fl_state_performance.csv",
  "headline_rmse_FL",            sprintf("%.4f", g_st(HEADLINE_MODEL, HEADLINE_RULE, "Florida", "rmse")),    "FINAL_ca_fl_state_performance.csv",
  "headline_r2_FL",              sprintf("%.4f", g_st(HEADLINE_MODEL, HEADLINE_RULE, "Florida", "r2")),      "FINAL_ca_fl_state_performance.csv",
  "best_FL_unified_model",       "pooled_lasso / 1se",                                                       "FINAL_ca_fl_state_performance.csv",
  "best_FL_unified_rmse",        sprintf("%.4f", g_st("pooled_lasso", "1se", "Florida", "rmse")),             "FINAL_ca_fl_state_performance.csv",
  "best_FL_unified_r2",          sprintf("%.4f", g_st("pooled_lasso", "1se", "Florida", "r2")),               "FINAL_ca_fl_state_performance.csv",
  "observed_sd_CA",              sprintf("%.4f", state_spread$actual_sd[state_spread$state == "California"]), "derived from FINAL_predictions.csv",
  "observed_sd_FL",              sprintf("%.4f", state_spread$actual_sd[state_spread$state == "Florida"]),    "derived from FINAL_predictions.csv",
  "headline_rmse_over_sd_CA",    sprintf("%.4f", g_st(HEADLINE_MODEL, HEADLINE_RULE, "California", "rmse") / state_spread$actual_sd[state_spread$state == "California"]), "derived",
  "headline_rmse_over_sd_FL",    sprintf("%.4f", g_st(HEADLINE_MODEL, HEADLINE_RULE, "Florida", "rmse") / state_spread$actual_sd[state_spread$state == "Florida"]),       "derived",
  "S3_rmse_interactions_min",    sprintf("%.4f", g_sen("S3_no_structural_beds", HEADLINE_MODEL, "min", "rmse")), "SENSITIVITY_metrics_overall_pooled.csv",
  "S3_r2_interactions_min",      sprintf("%.4f", g_sen("S3_no_structural_beds", HEADLINE_MODEL, "min", "r2")),   "SENSITIVITY_metrics_overall_pooled.csv",
  "S4_prior_rate_only_r2",       sprintf("%.4f", sens_persist$r2[sens_persist$sample_id == "S4_persistence" & sens_persist$comparison == "a_prior_rate_only"]), "SENSITIVITY_persistence_benchmark.csv",
  "S4_factor_plus_prior_nonzero", "0",                                                                      "SENSITIVITY_persistence_benchmark.csv",
  "n_stable_predictors_min",     as.character(sum(sens_stable$lambda_rule == "min" & sens_stable$role == "penalized_predictor" & sens_stable$stable_across_all_samples)), "SENSITIVITY_stable_predictors_across_models.csv",
  "n_stable_predictors_1se",     as.character(sum(sens_stable$lambda_rule == "1se" & sens_stable$role == "penalized_predictor" & sens_stable$stable_across_all_samples)), "SENSITIVITY_stable_predictors_across_models.csv",
  "audit_pass",                  as.character(sum(audit_checks$status == "PASS")),                          "audit_checks.csv",
  "audit_warning",               as.character(sum(audit_checks$status == "WARNING")),                       "audit_checks.csv",
  "audit_fail",                  as.character(sum(audit_checks$status == "FAIL")),                          "audit_checks.csv",
  "n_highly_correlated_pairs",   as.character(nrow(corr_pairs)),                                            "highly_correlated_pairs_v2.csv"
)

wcsv(as.data.frame(key), file.path(TAB, "KEY_NUMBERS.csv"))

## ---------------------------------------------------------------------------
## 17. WORKBOOK + MANIFEST
## ---------------------------------------------------------------------------

sheets <- list(
  key_numbers            = as.data.frame(key),
  model_performance      = t1,
  performance_by_year    = t2,
  state_performance      = t3,
  observed_spread        = t3_spread,
  stable_coefficients    = t4,
  unpenalized_controls   = t4_controls,
  state_interactions     = t5,
  sensitivity_own_rows   = t6_own,
  sensitivity_common     = t6_common,
  residuals_year_state   = t7,
  robust_predictors      = t8,
  robust_compact         = t8_compact,
  persistence_benchmark  = t9,
  reporting_constraints  = as.data.frame(constraints)
)

wb_path <- file.path(OUT, "FINAL_LASSO_REPORT_TABLES.xlsx")
write_owned(wb_path)
wb <- createWorkbook()
hs <- createStyle(textDecoration = "bold", fgFill = "#EDF2F7", border = "bottom")
for (nm in names(sheets)) {
  addWorksheet(wb, nm)
  writeData(wb, nm, sheets[[nm]], headerStyle = hs)
  freezePane(wb, nm, firstRow = TRUE)
  setColWidths(wb, nm, cols = seq_len(ncol(sheets[[nm]])), widths = "auto")
}
saveWorkbook(wb, wb_path, overwrite = TRUE)
message("  workbook: ", wb_path)

produced <- c(list.files(TAB, full.names = TRUE), list.files(FIG, full.names = TRUE), wb_path)
mani <- data.frame(
  file      = sub("^outputs/lasso_final_report/", "", produced),
  bytes     = file.info(produced)$size,
  md5       = unname(tools::md5sum(produced)),
  generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
)
mani$deliverable <- dplyr::case_when(
  grepl("TABLE_01|FIG_01", mani$file) ~ "1. Model-performance comparison table",
  grepl("FIG_02", mani$file)          ~ "2. Observed-versus-predicted plot, headline model",
  grepl("TABLE_02|FIG_03", mani$file) ~ "3. RMSE and R2 by validation year",
  grepl("TABLE_03|FIG_04", mani$file) ~ "4. California-versus-Florida performance comparison",
  grepl("TABLE_04|FIG_05", mani$file) ~ "5. Stable standardized-coefficient plot",
  grepl("TABLE_05|FIG_06", mani$file) ~ "6. State-interaction coefficient plot",
  grepl("TABLE_06|FIG_07", mani$file) ~ "7. Sensitivity-analysis comparison plot",
  grepl("TABLE_07|FIG_08", mani$file) ~ "8. Residual plots by year and state",
  grepl("TABLE_08", mani$file)        ~ "9. Robust-predictor table",
  grepl("TABLE_09|FIG_09", mani$file) ~ "Supporting: persistence benchmark",
  grepl("TABLE_10", mani$file)        ~ "Supporting: reporting constraints",
  grepl("KEY_NUMBERS", mani$file)     ~ "Supporting: narrative key numbers",
  TRUE                                ~ "Supporting"
)
wcsv(mani, file.path(OUT, "REPORT_MANIFEST.csv"))

## ---------------------------------------------------------------------------
## 18. SESSION INFO + SUMMARY
## ---------------------------------------------------------------------------

si_path <- file.path(OUT, "session_info_final_report.txt")
write_owned(si_path)
writeLines(c(
  paste("generated:", format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
  paste("input workbook:", V2_PATH),
  paste("input md5 (live, matches FINAL manifest):", V2_MD5_LIVE),
  paste("headline model:", HEADLINE_MODEL, "lambda.", HEADLINE_RULE),
  "no model was fitted, refitted, or re-scored by this script",
  "", capture.output(sessionInfo())
), si_path)

message("\nFinal report package written to ", OUT)
message("  tables : ", length(list.files(TAB)))
message("  figures: ", length(list.files(FIG)))
