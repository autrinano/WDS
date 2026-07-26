###############################################################################
# fit_lasso_sensitivities.R
#
# Sensitivity LASSO runs for the California-Florida CoC-year homelessness panel.
#
# This script is owned by the sensitivity effort. It does NOT read, write, or
# modify the primary workbook, fit_lasso_models.R, any FINAL_ output, or any
# central project document. It reads only the sensitivity samples written by
# build_lasso_sensitivity_inputs.R (plus the FINAL_ metric tables, read-only,
# for the comparison table) and writes everything under outputs/lasso_sensitivity/.
#
# MODELING CONTRACT (identical to the final analysis, fit_lasso_models.R)
# ----------------------------------------------------------------------
#   Target        raw next-year CoC PIT rate per 10k (target_homeless_rate_per_10k).
#                 The raw target is primary; the final analysis showed the log
#                 target performed worse, so it is not repeated here.
#   Outer folds   expanding-window rolling origin by target year, using the EXACT
#                 final validation years 2017, 2018, 2019, 2020, 2022, 2023, 2024,
#                 2025. Train = all target years strictly before the held-out
#                 year; score that year only.
#   Inner tuning  nested FORWARD-CHAINING time validation inside each outer
#                 training window (train y[1..c], validate y[c+1]); lambda is
#                 never chosen using future years.
#   Lambda        both lambda.min and lambda.1se are carried through.
#   Controls      control_state_florida and control_time_index are UNPENALIZED;
#                 all candidate predictors are PENALIZED.
#   Scaling       predictor standardization is fit on training rows ONLY (outer
#                 training for scoring, inner-train only inside the lambda search).
#   Data gate     STRICT: any NA/NaN/Inf in the target, controls, or predictors
#                 stops the run. Nothing is imputed.
#
# INTERPRETATION
# --------------
# Everything reported here is a PREDICTIVE ASSOCIATION. Coefficients, selection
# frequencies, and sign stability describe how predictors track the outcome in a
# small, strongly time-ordered two-state panel. They do not identify causal
# effects and are not impact estimates.
###############################################################################

suppressWarnings(suppressMessages({
  .libPaths(c("_r_libs", .libPaths()))
  library(glmnet)
  library(Matrix)
  library(openxlsx)
}))

OUT_DIR  <- "outputs/lasso_sensitivity"
DATA_DIR <- file.path(OUT_DIR, "data")
DEF_DIR  <- file.path(OUT_DIR, "definitions")
RES_DIR  <- file.path(OUT_DIR, "results")
FINAL_DIR <- "outputs/lasso_models"          # read-only, for the primary comparison
dir.create(RES_DIR, recursive = TRUE, showWarnings = FALSE)

## Contract constants copied from the final run (must not drift).
FINAL_VAL_YEARS       <- c(2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025)
MIN_INNER_TRAIN_YEARS <- 2
PRIMARY_LAMBDA_RULE   <- "min"
SEED                  <- 20260724

id_cols      <- c("state", "state_abbr", "coc_number", "coc_name",
                  "predictor_year", "target_year")
target_col   <- "target_homeless_rate_per_10k"
control_cols <- c("control_state_florida", "control_time_index")
PRIOR_COL    <- "prior_homeless_rate_per_10k"

banner <- function(txt) {
  line <- paste(rep("=", 78), collapse = "")
  cat(line, "\n", txt, "\n", line, "\n", sep = "")
}
banner("fit_lasso_sensitivities.R  |  raw-rate target  |  final folds and lambda rules")
set.seed(SEED)

## ---------------------------------------------------------------------------
## SAMPLE REGISTRY
## ---------------------------------------------------------------------------
sample_ids <- c("S0_primary", "S1_split_county_excluded", "S2_stable_cocs",
                "S3_no_structural_beds", "S4_persistence",
                "S4b_persistence_full_enum", "S5_no_hpi_fl518")
persistence_samples <- c("S4_persistence", "S4b_persistence_full_enum")

sample_defs <- read.csv(file.path(DEF_DIR, "sensitivity_sample_definitions.csv"))
if (!all(sample_ids %in% sample_defs$sample_id))
  stop("Sample definitions missing. Run build_lasso_sensitivity_inputs.R first.")

load_sample <- function(sid) {
  path <- file.path(DATA_DIR, sprintf("%s_data.csv", sid))
  if (!file.exists(path)) stop("Sample data not found: ", path,
                               " (run build_lasso_sensitivity_inputs.R first)")
  d <- read.csv(path, check.names = FALSE)
  missing_cols <- setdiff(c(id_cols, target_col, control_cols), names(d))
  if (length(missing_cols)) stop(sid, " is missing required columns: ",
                                 paste(missing_cols, collapse = ", "))
  preds <- setdiff(names(d), c(id_cols, target_col, control_cols, PRIOR_COL))
  non_numeric <- preds[!vapply(d[preds], is.numeric, logical(1))]
  if (length(non_numeric))
    stop(sid, ": non-numeric predictor columns cannot enter the model matrix: ",
         paste(non_numeric, collapse = ", "))

  ## STRICT FINITE GATE -- no silent imputation, exactly as in the final run.
  gate_cols <- c(target_col, control_cols, preds,
                 if (PRIOR_COL %in% names(d)) PRIOR_COL else NULL)
  nonfinite <- vapply(d[gate_cols], function(v) sum(!is.finite(v)), integer(1))
  if (any(nonfinite > 0)) {
    bad <- nonfinite[nonfinite > 0]
    stop(sid, ": non-finite (NA/NaN/Inf) values in model columns; the pipeline ",
         "fails instead of imputing:\n",
         paste(sprintf("  %s: %d", names(bad), bad), collapse = "\n"))
  }

  ## Degenerate-predictor guard: a constant column inside a sample carries no
  ## information and is reported, not silently standardized into noise.
  const <- preds[vapply(d[preds], function(v) length(unique(v)) <= 1, logical(1))]
  if (length(const))
    stop(sid, ": constant predictor(s) present, which the sample builder should ",
         "have dropped: ", paste(const, collapse = ", "))

  list(id = sid, dat = d, predictors = preds,
       has_prior = PRIOR_COL %in% names(d))
}

samples <- lapply(sample_ids, load_sample)
names(samples) <- sample_ids
for (s in samples)
  cat(sprintf("%-26s %4d rows | %2d CoCs | %2d predictors | prior-rate column: %s\n",
              s$id, nrow(s$dat), length(unique(s$dat$coc_number)),
              length(s$predictors), s$has_prior))
cat("\nStrict finite gate passed for every sensitivity sample.\n\n")

## ---------------------------------------------------------------------------
## FOLDS -- the exact final rolling-origin definition, applied per sample
## ---------------------------------------------------------------------------
make_folds <- function(dat, sid) {
  years <- sort(unique(dat$target_year))
  vys   <- FINAL_VAL_YEARS[FINAL_VAL_YEARS %in% years]
  out <- list()
  for (i in seq_along(FINAL_VAL_YEARS)) {
    vy <- FINAL_VAL_YEARS[i]
    va <- which(dat$target_year == vy)
    tr <- which(dat$target_year <  vy)
    if (!length(va) || !length(tr)) next
    out[[length(out) + 1]] <- list(
      fold = i, val_year = vy, train_idx = tr, val_idx = va,
      train_years = sort(unique(dat$target_year[tr])))
  }
  if (!length(out)) stop(sid, ": no usable outer folds.")
  out
}

## ---------------------------------------------------------------------------
## DESIGN MATRIX (scaling fit on fit_rows only; NO imputation)
## ---------------------------------------------------------------------------
std_params <- function(mat) {
  ctr <- colMeans(mat)
  scl <- apply(mat, 2, sd)
  scl[!is.finite(scl) | scl == 0] <- 1     # degenerate-scale guard (not imputation)
  list(center = ctr, scale = scl)
}

build_design <- function(spec, fit_rows, apply_rows) {
  D    <- spec$dat
  Xfit <- as.matrix(D[fit_rows, spec$predictors, drop = FALSE])
  pp   <- std_params(Xfit)
  Xap  <- as.matrix(D[apply_rows, spec$predictors, drop = FALSE])
  Xs   <- scale(Xap, center = pp$center, scale = pp$scale)
  C    <- as.matrix(D[apply_rows, spec$controls, drop = FALSE])
  if (isTRUE(spec$interactions)) {
    fl <- D[apply_rows, "control_state_florida"]
    I  <- Xs * fl
    colnames(I) <- paste0(colnames(Xs), ":FL")
    x   <- cbind(C, Xs, I)
    pen <- c(rep(0, ncol(C)), rep(1, ncol(Xs) + ncol(I)))
  } else {
    x   <- cbind(C, Xs)
    pen <- c(rep(0, ncol(C)), rep(1, ncol(Xs)))
  }
  list(x = x, penalty = pen)
}

## ---------------------------------------------------------------------------
## NESTED FORWARD-CHAINING LAMBDA TUNER (identical rule to the final run)
## ---------------------------------------------------------------------------
tune_fc <- function(spec, yof) {
  rows  <- spec$rows
  years <- spec$dat$target_year[rows]
  uy    <- sort(unique(years))
  K     <- length(uy)

  full  <- build_design(spec, rows, rows)
  yfull <- yof(rows)
  gfit  <- suppressWarnings(glmnet(full$x, yfull, alpha = 1,
                                   penalty.factor = full$penalty, standardize = FALSE))
  grid  <- gfit$lambda

  c0   <- max(1, min(MIN_INNER_TRAIN_YEARS, K - 1))
  cuts <- if (K >= 2) c0:(K - 1) else integer(0)

  if (!length(cuts))
    return(list(gfit = gfit, grid = grid, lambda.min = grid[length(grid)],
                lambda.1se = grid[1], n_inner_splits = 0L))

  err <- matrix(NA_real_, length(cuts), length(grid))
  for (i in seq_along(cuts)) {
    cc  <- cuts[i]
    itr <- rows[years %in% uy[1:cc]]
    iva <- rows[years == uy[cc + 1]]
    dtr <- build_design(spec, itr, itr)
    fit <- suppressWarnings(glmnet(dtr$x, yof(itr), alpha = 1,
                                   penalty.factor = dtr$penalty,
                                   standardize = FALSE, lambda = grid))
    dva <- build_design(spec, itr, iva)          # scale from inner-train only
    pr  <- predict(fit, newx = dva$x, s = grid)
    err[i, ] <- colMeans((yof(iva) - pr)^2)
  }
  cvm  <- colMeans(err, na.rm = TRUE)
  cvsd <- apply(err, 2, function(z) { z <- z[!is.na(z)]
                if (length(z) < 2) NA_real_ else sd(z) / sqrt(length(z)) })
  imin <- which.min(cvm)
  lmin <- grid[imin]
  se   <- cvsd[imin]
  l1se <- if (is.na(se)) lmin else grid[min(which(cvm <= cvm[imin] + se))]
  list(gfit = gfit, grid = grid, cvm = cvm, cvsd = cvsd,
       lambda.min = lmin, lambda.1se = l1se, n_inner_splits = length(cuts))
}

## ---------------------------------------------------------------------------
## METRICS
## ---------------------------------------------------------------------------
rmse <- function(a, p) sqrt(mean((a - p)^2))
mae  <- function(a, p) mean(abs(a - p))
r2   <- function(a, p) { sst <- sum((a - mean(a))^2)
                         if (sst == 0) NA_real_ else 1 - sum((a - p)^2) / sst }

## ---------------------------------------------------------------------------
## RUN ONE SAMPLE
## ---------------------------------------------------------------------------
run_sample <- function(s) {
  dat   <- s$dat
  preds <- s$predictors
  folds <- make_folds(dat, s$id)

  fold_defs <- do.call(rbind, lapply(folds, function(f) data.frame(
    sample_id = s$id, fold = f$fold, validation_year = f$val_year,
    n_train_years = length(f$train_years),
    train_year_min = min(f$train_years), train_year_max = max(f$train_years),
    n_train_rows = length(f$train_idx), n_val_rows = length(f$val_idx),
    n_train_cocs = length(unique(dat$coc_number[f$train_idx])),
    n_val_cocs = length(unique(dat$coc_number[f$val_idx])),
    stringsAsFactors = FALSE)))

  preds_out <- list(); metrics <- list(); coefs <- list(); lambdas <- list()
  push <- function(lst, x) { lst[[length(lst) + 1]] <- x; lst }
  yof  <- function(rows) dat[[target_col]][rows]

  ## One penalized spec at both lambda rules.
  process_spec <- function(model_name, spec, val_rows, fold, vy) {
    tuned <- tune_fc(spec, yof)
    dva   <- build_design(spec, spec$rows, val_rows)
    ids   <- dat[val_rows, id_cols, drop = FALSE]
    a     <- dat[[target_col]][val_rows]
    lambdas[[length(lambdas) + 1]] <<- data.frame(
      sample_id = s$id, model = model_name, fold = fold, validation_year = vy,
      lambda_min = tuned$lambda.min, lambda_1se = tuned$lambda.1se,
      n_inner_splits = tuned$n_inner_splits, n_grid = length(tuned$grid),
      stringsAsFactors = FALSE)
    for (rule in c("min", "1se")) {
      lam <- if (rule == "min") tuned$lambda.min else tuned$lambda.1se
      p   <- as.numeric(predict(tuned$gfit, newx = dva$x, s = lam))
      preds_out[[length(preds_out) + 1]] <<- data.frame(
        sample_id = s$id, model = model_name, lambda_rule = rule, fold = fold,
        validation_year = vy, ids, actual = a, predicted = p, residual = a - p,
        row.names = NULL, stringsAsFactors = FALSE)
      metrics[[length(metrics) + 1]] <<- data.frame(
        sample_id = s$id, model = model_name, lambda_rule = rule, fold = fold,
        validation_year = vy, group = "all", n = length(a),
        rmse = rmse(a, p), mae = mae(a, p), r2 = r2(a, p), stringsAsFactors = FALSE)
      cf <- as.matrix(coef(tuned$gfit, s = lam))
      coefs[[length(coefs) + 1]] <<- data.frame(
        sample_id = s$id, model = model_name, lambda_rule = rule, fold = fold,
        validation_year = vy, term = rownames(cf), coefficient = as.numeric(cf),
        lambda = lam, stringsAsFactors = FALSE)
    }
    invisible(tuned)
  }

  ## An unpenalized OLS reference model on the same rows and folds.
  process_ols <- function(model_name, terms, tr, va, fold, vy) {
    bdf  <- data.frame(y = yof(tr), dat[tr, terms, drop = FALSE])
    bfit <- lm(y ~ ., data = bdf)
    a    <- dat[[target_col]][va]
    p    <- as.numeric(predict(bfit, newdata = dat[va, terms, drop = FALSE]))
    preds_out[[length(preds_out) + 1]] <<- data.frame(
      sample_id = s$id, model = model_name, lambda_rule = "none", fold = fold,
      validation_year = vy, dat[va, id_cols, drop = FALSE], actual = a,
      predicted = p, residual = a - p, row.names = NULL, stringsAsFactors = FALSE)
    metrics[[length(metrics) + 1]] <<- data.frame(
      sample_id = s$id, model = model_name, lambda_rule = "none", fold = fold,
      validation_year = vy, group = "all", n = length(a),
      rmse = rmse(a, p), mae = mae(a, p), r2 = r2(a, p), stringsAsFactors = FALSE)
    cf <- coef(bfit)
    coefs[[length(coefs) + 1]] <<- data.frame(
      sample_id = s$id, model = model_name, lambda_rule = "none", fold = fold,
      validation_year = vy, term = names(cf), coefficient = as.numeric(cf),
      lambda = NA_real_, stringsAsFactors = FALSE)
    invisible(NULL)
  }

  for (f in folds) {
    tr <- f$train_idx; va <- f$val_idx; fold <- f$fold; vy <- f$val_year

    ## Reference baseline present in every sample (state + linear time, OLS).
    process_ols("state_time_baseline", control_cols, tr, va, fold, vy)

    ## Required for every sensitivity: pooled LASSO and pooled state-interaction LASSO.
    process_spec("pooled_lasso",
                 list(dat = dat, predictors = preds, rows = tr,
                      controls = control_cols, interactions = FALSE),
                 va, fold, vy)
    process_spec("pooled_lasso_state_interactions",
                 list(dat = dat, predictors = preds, rows = tr,
                      controls = control_cols, interactions = TRUE),
                 va, fold, vy)

    ## Persistence benchmark: identical rows and folds, three required comparisons.
    if (s$has_prior) {
      process_ols("prior_rate_only",        PRIOR_COL,                     tr, va, fold, vy)
      process_ols("state_time_prior_rate",  c(control_cols, PRIOR_COL),    tr, va, fold, vy)
      process_spec("pooled_lasso_plus_prior",
                   list(dat = dat, predictors = preds, rows = tr,
                        controls = c(control_cols, PRIOR_COL), interactions = FALSE),
                   va, fold, vy)
      process_spec("pooled_lasso_state_interactions_plus_prior",
                   list(dat = dat, predictors = preds, rows = tr,
                        controls = c(control_cols, PRIOR_COL), interactions = TRUE),
                   va, fold, vy)
    }
  }

  list(fold_defs = fold_defs,
       predictions = do.call(rbind, preds_out),
       metrics_by_fold = do.call(rbind, metrics),
       coefficients = do.call(rbind, coefs),
       lambdas = do.call(rbind, lambdas))
}

results <- list()
for (sid in sample_ids) {
  cat(sprintf("Fitting %s ...\n", sid))
  results[[sid]] <- run_sample(samples[[sid]])
}
cat("\n")

fold_definitions <- do.call(rbind, lapply(results, `[[`, "fold_defs"))
predictions      <- do.call(rbind, lapply(results, `[[`, "predictions"))
metrics_by_fold  <- do.call(rbind, lapply(results, `[[`, "metrics_by_fold"))
coefficients     <- do.call(rbind, lapply(results, `[[`, "coefficients"))
lambda_choices   <- do.call(rbind, lapply(results, `[[`, "lambdas"))
rownames(fold_definitions) <- rownames(predictions) <- NULL
rownames(metrics_by_fold)  <- rownames(coefficients) <- rownames(lambda_choices) <- NULL

## ---------------------------------------------------------------------------
## POOLED OUT-OF-TIME METRICS
## ---------------------------------------------------------------------------
pooled_metrics <- function(df, extra = list()) {
  k <- interaction(df$sample_id, df$model, df$lambda_rule, drop = TRUE)
  out <- do.call(rbind, lapply(split(df, k), function(g) {
    g <- g[is.finite(g$predicted), ]
    if (!nrow(g)) return(NULL)
    data.frame(sample_id = g$sample_id[1], model = g$model[1],
               lambda_rule = g$lambda_rule[1], scope = "pooled_all_folds",
               n = nrow(g), n_cocs = length(unique(g$coc_number)),
               rmse = rmse(g$actual, g$predicted), mae = mae(g$actual, g$predicted),
               r2 = r2(g$actual, g$predicted), stringsAsFactors = FALSE)
  }))
  rownames(out) <- NULL
  out[order(out$sample_id, out$model, out$lambda_rule), ]
}
metrics_overall <- pooled_metrics(predictions)

## Per-state pooled performance.
skey <- interaction(predictions$sample_id, predictions$model,
                    predictions$lambda_rule, predictions$state, drop = TRUE)
state_performance <- do.call(rbind, lapply(split(predictions, skey), function(g) {
  g <- g[is.finite(g$predicted), ]
  if (!nrow(g)) return(NULL)
  data.frame(sample_id = g$sample_id[1], model = g$model[1],
             lambda_rule = g$lambda_rule[1], state = g$state[1],
             scope = "pooled_all_folds", n = nrow(g),
             rmse = rmse(g$actual, g$predicted), mae = mae(g$actual, g$predicted),
             r2 = r2(g$actual, g$predicted), stringsAsFactors = FALSE)
}))
rownames(state_performance) <- NULL
state_performance <- state_performance[order(state_performance$sample_id,
                       state_performance$model, state_performance$lambda_rule,
                       state_performance$state), ]

## ---------------------------------------------------------------------------
## SELECTED COEFFICIENTS, SELECTION FREQUENCY, SIGN STABILITY
## ---------------------------------------------------------------------------
## Term role: controls (and the prior rate, where it is a control) are
## UNPENALIZED, so their "selection frequency" is trivially 1 and must not be
## read as a LASSO selection result.
term_role <- function(term) ifelse(
  term %in% control_cols, "unpenalized_control",
  ifelse(term == PRIOR_COL, "unpenalized_prior_rate",
         ifelse(grepl(":FL$", term), "penalized_state_interaction", "penalized_predictor")))

penalized <- coefficients[coefficients$lambda_rule != "none" &
                          coefficients$term != "(Intercept)", ]
ckey <- interaction(penalized$sample_id, penalized$model,
                    penalized$lambda_rule, drop = TRUE)
coefficient_stability <- do.call(rbind, lapply(split(penalized, ckey), function(df) {
  do.call(rbind, lapply(split(df, df$term), function(t) {
    nz <- t$coefficient[abs(t$coefficient) > 0]
    data.frame(sample_id = t$sample_id[1], model = t$model[1],
               lambda_rule = t$lambda_rule[1], term = t$term[1],
               role = term_role(t$term[1]),
               n_folds = nrow(t), n_selected = length(nz),
               selection_freq = length(nz) / nrow(t),
               mean_coef = mean(t$coefficient), sd_coef = sd(t$coefficient),
               mean_coef_when_selected = if (length(nz)) mean(nz) else NA_real_,
               n_positive = sum(nz > 0), n_negative = sum(nz < 0),
               sign_consistency = if (length(nz)) max(mean(nz > 0), mean(nz < 0)) else NA_real_,
               dominant_sign = if (!length(nz)) NA_character_
                               else if (mean(nz > 0) >= mean(nz < 0)) "positive" else "negative",
               stringsAsFactors = FALSE)
  }))
}))
rownames(coefficient_stability) <- NULL
coefficient_stability <- coefficient_stability[
  order(coefficient_stability$sample_id, coefficient_stability$model,
        coefficient_stability$lambda_rule, -coefficient_stability$selection_freq,
        -abs(coefficient_stability$mean_coef)), ]

## Nonzero coefficients only, fold by fold (the "selected coefficients" export).
selected_coefficients <- coefficients[abs(coefficients$coefficient) > 0, ]
selected_coefficients <- selected_coefficients[
  order(selected_coefficients$sample_id, selected_coefficients$model,
        selected_coefficients$lambda_rule, selected_coefficients$validation_year,
        -abs(selected_coefficients$coefficient)), ]
rownames(selected_coefficients) <- NULL

## Selection frequency in wide form (predictor x sample) for the headline model.
sel_wide_for <- function(model_name, rule) {
  sub <- coefficient_stability[coefficient_stability$model == model_name &
                               coefficient_stability$lambda_rule == rule, ]
  if (!nrow(sub)) return(NULL)
  terms <- sort(unique(sub$term))
  out <- data.frame(model = model_name, lambda_rule = rule, term = terms,
                    stringsAsFactors = FALSE)
  for (sid in sample_ids) {
    m <- sub[sub$sample_id == sid, ]
    out[[paste0("selfreq_", sid)]] <- m$selection_freq[match(terms, m$term)]
    out[[paste0("sign_", sid)]]    <- m$dominant_sign[match(terms, m$term)]
  }
  out
}
selection_frequency_wide <- do.call(rbind, c(
  lapply(c("min", "1se"), function(r) sel_wide_for("pooled_lasso", r)),
  lapply(c("min", "1se"), function(r) sel_wide_for("pooled_lasso_state_interactions", r))))
rownames(selection_frequency_wide) <- NULL

## Mean number of penalized terms surviving per fold, by sample/model/rule. A
## value of 0 means every candidate factor was shrunk to zero, so the penalized
## model collapses to its unpenalized controls.
pen_only <- penalized[term_role(penalized$term) %in%
                      c("penalized_predictor", "penalized_state_interaction"), ]
nonzero_counts <- do.call(rbind, lapply(
  split(pen_only, interaction(pen_only$sample_id, pen_only$model,
                              pen_only$lambda_rule, pen_only$fold, drop = TRUE)),
  function(g) data.frame(sample_id = g$sample_id[1], model = g$model[1],
                         lambda_rule = g$lambda_rule[1], fold = g$fold[1],
                         n_nonzero_penalized = sum(abs(g$coefficient) > 0),
                         stringsAsFactors = FALSE)))
mean_nonzero <- do.call(rbind, lapply(
  split(nonzero_counts, interaction(nonzero_counts$sample_id, nonzero_counts$model,
                                    nonzero_counts$lambda_rule, drop = TRUE)),
  function(g) data.frame(sample_id = g$sample_id[1], model = g$model[1],
                         lambda_rule = g$lambda_rule[1],
                         mean_nonzero_penalized_per_fold = mean(g$n_nonzero_penalized),
                         min_nonzero_penalized_per_fold = min(g$n_nonzero_penalized),
                         max_nonzero_penalized_per_fold = max(g$n_nonzero_penalized),
                         stringsAsFactors = FALSE)))
rownames(mean_nonzero) <- NULL
metrics_overall <- merge(metrics_overall, mean_nonzero,
                         by = c("sample_id", "model", "lambda_rule"), all.x = TRUE)
metrics_overall <- metrics_overall[order(metrics_overall$sample_id,
                                         metrics_overall$model,
                                         metrics_overall$lambda_rule), ]
rownames(metrics_overall) <- NULL

## ---------------------------------------------------------------------------
## STABLE PREDICTORS ACROSS PRIMARY AND SENSITIVITY MODELS
## Stability rule (stated, not tuned): a predictor is STABLE if, in the pooled
## LASSO at a given lambda rule, it is selected in at least 50% of outer folds in
## EVERY sample where it is available, and its dominant sign is the same in all
## of them. Availability is respected: a predictor removed by construction from a
## sample (e.g. the HIC beds in S3) is not counted against it.
## ---------------------------------------------------------------------------
STABLE_MIN_SELFREQ <- 0.5
stability_across_models <- do.call(rbind, lapply(c("min", "1se"), function(rule) {
  sub <- coefficient_stability[coefficient_stability$model == "pooled_lasso" &
                               coefficient_stability$lambda_rule == rule, ]
  do.call(rbind, lapply(split(sub, sub$term), function(t) {
    signs <- t$dominant_sign[!is.na(t$dominant_sign)]
    data.frame(
      lambda_rule = rule, term = t$term[1], role = term_role(t$term[1]),
      n_samples_available = nrow(t),
      samples_available = paste(sort(t$sample_id), collapse = ";"),
      min_selection_freq = min(t$selection_freq),
      mean_selection_freq = mean(t$selection_freq),
      max_selection_freq = max(t$selection_freq),
      n_samples_selected_at_least_half = sum(t$selection_freq >= STABLE_MIN_SELFREQ),
      selfreq_primary = t$selection_freq[match("S0_primary", t$sample_id)],
      sign_primary = t$dominant_sign[match("S0_primary", t$sample_id)],
      sign_agreement = if (!length(signs)) NA_real_
                       else max(mean(signs == "positive"), mean(signs == "negative")),
      stable_across_all_samples =
        min(t$selection_freq) >= STABLE_MIN_SELFREQ &&
        length(unique(signs)) == 1,
      stringsAsFactors = FALSE)
  }))
}))
rownames(stability_across_models) <- NULL
stability_across_models <- stability_across_models[
  order(stability_across_models$lambda_rule, -stability_across_models$min_selection_freq,
        -stability_across_models$mean_selection_freq), ]

## ---------------------------------------------------------------------------
## COMPARISON WITH THE PRIMARY LASSO
## (a) headline: each sample's own pooled metrics next to the FINAL run's.
## (b) like-for-like: primary and sensitivity scored on the IDENTICAL rows that
##     both samples contain, so a metric difference is not a sample-size artifact.
## ---------------------------------------------------------------------------
final_overall_path <- file.path(FINAL_DIR, "FINAL_metrics_overall_out_of_time.csv")
final_overall <- if (file.exists(final_overall_path))
  read.csv(final_overall_path) else NULL

comparison_headline <- metrics_overall[
  metrics_overall$model %in% c("pooled_lasso", "pooled_lasso_state_interactions",
                               "state_time_baseline", "prior_rate_only",
                               "state_time_prior_rate", "pooled_lasso_plus_prior",
                               "pooled_lasso_state_interactions_plus_prior"), ]
if (!is.null(final_overall)) {
  fin <- final_overall[, c("model", "lambda_rule", "n", "rmse", "mae", "r2")]
  names(fin) <- c("model", "lambda_rule", "final_n", "final_rmse", "final_mae", "final_r2")
  comparison_headline <- merge(comparison_headline, fin,
                               by = c("model", "lambda_rule"), all.x = TRUE)
  comparison_headline$rmse_diff_vs_final <- comparison_headline$rmse - comparison_headline$final_rmse
  comparison_headline$r2_diff_vs_final   <- comparison_headline$r2   - comparison_headline$final_r2
}
comparison_headline <- comparison_headline[
  order(comparison_headline$model, comparison_headline$lambda_rule,
        comparison_headline$sample_id), ]
rownames(comparison_headline) <- NULL

## Like-for-like on common rows.
pred_key <- function(df) paste(df$coc_number, df$predictor_year, sep = "|")
primary_pred <- predictions[predictions$sample_id == "S0_primary", ]
primary_pred$row_key <- pred_key(primary_pred)

common_row_comparison <- do.call(rbind, lapply(setdiff(sample_ids, "S0_primary"), function(sid) {
  sp <- predictions[predictions$sample_id == sid, ]
  sp$row_key <- pred_key(sp)
  do.call(rbind, lapply(c("pooled_lasso", "pooled_lasso_state_interactions"), function(mn) {
    do.call(rbind, lapply(c("min", "1se"), function(rule) {
      a <- sp[sp$model == mn & sp$lambda_rule == rule, ]
      b <- primary_pred[primary_pred$model == mn & primary_pred$lambda_rule == rule, ]
      common <- intersect(a$row_key, b$row_key)
      if (!length(common)) return(NULL)
      a <- a[match(common, a$row_key), ]; b <- b[match(common, b$row_key), ]
      data.frame(sample_id = sid, model = mn, lambda_rule = rule,
                 n_common_rows = length(common),
                 n_common_cocs = length(unique(a$coc_number)),
                 sens_rmse = rmse(a$actual, a$predicted),
                 primary_rmse = rmse(b$actual, b$predicted),
                 rmse_diff_sens_minus_primary = rmse(a$actual, a$predicted) - rmse(b$actual, b$predicted),
                 sens_mae = mae(a$actual, a$predicted),
                 primary_mae = mae(b$actual, b$predicted),
                 sens_r2 = r2(a$actual, a$predicted),
                 primary_r2 = r2(b$actual, b$predicted),
                 r2_diff_sens_minus_primary = r2(a$actual, a$predicted) - r2(b$actual, b$predicted),
                 pred_correlation = suppressWarnings(cor(a$predicted, b$predicted)),
                 stringsAsFactors = FALSE)
    }))
  }))
}))
rownames(common_row_comparison) <- NULL

## ---------------------------------------------------------------------------
## PERSISTENCE VERDICT TABLE
## ---------------------------------------------------------------------------
persistence_comparison <- do.call(rbind, lapply(persistence_samples, function(sid) {
  m <- metrics_overall[metrics_overall$sample_id == sid, ]
  pick <- function(model, rule) {
    r <- m[m$model == model & m$lambda_rule == rule, ]
    if (!nrow(r)) return(rep(NA_real_, 5))
    c(r$n[1], r$rmse[1], r$mae[1], r$r2[1],
      if (is.null(r$mean_nonzero_penalized_per_fold)) NA_real_
      else r$mean_nonzero_penalized_per_fold[1])
  }
  rows <- list(
    c("a_prior_rate_only",                      "none", pick("prior_rate_only", "none")),
    c("b_state_time_prior_rate",                "none", pick("state_time_prior_rate", "none")),
    c("state_time_baseline_reference",          "none", pick("state_time_baseline", "none")),
    c("factor_lasso_without_prior_min",         "min",  pick("pooled_lasso", "min")),
    c("factor_lasso_without_prior_1se",         "1se",  pick("pooled_lasso", "1se")),
    c("c_factor_lasso_plus_prior_min",          "min",  pick("pooled_lasso_plus_prior", "min")),
    c("c_factor_lasso_plus_prior_1se",          "1se",  pick("pooled_lasso_plus_prior", "1se")),
    c("c_factor_lasso_interactions_plus_prior_min", "min", pick("pooled_lasso_state_interactions_plus_prior", "min")),
    c("c_factor_lasso_interactions_plus_prior_1se", "1se", pick("pooled_lasso_state_interactions_plus_prior", "1se")))
  out <- do.call(rbind, lapply(rows, function(r) data.frame(
    sample_id = sid, comparison = r[1], lambda_rule = r[2],
    n = as.numeric(r[3]), rmse = as.numeric(r[4]),
    mae = as.numeric(r[5]), r2 = as.numeric(r[6]),
    mean_nonzero_penalized_per_fold = as.numeric(r[7]), stringsAsFactors = FALSE)))
  base_rmse <- out$rmse[out$comparison == "b_state_time_prior_rate"]
  out$rmse_diff_vs_persistence_baseline <- out$rmse - base_rmse
  out$pct_rmse_change_vs_persistence_baseline <- 100 * (out$rmse - base_rmse) / base_rmse
  out
}))
rownames(persistence_comparison) <- NULL

## ---------------------------------------------------------------------------
## WRITE OUTPUTS
## ---------------------------------------------------------------------------
w <- function(df, name) write.csv(df, file.path(RES_DIR, name), row.names = FALSE)
w(fold_definitions,         "SENSITIVITY_fold_definitions.csv")
w(metrics_by_fold,          "SENSITIVITY_performance_by_fold.csv")
w(metrics_overall,          "SENSITIVITY_metrics_overall_pooled.csv")
w(state_performance,        "SENSITIVITY_ca_fl_state_performance.csv")
w(predictions,              "SENSITIVITY_predictions.csv")
w(coefficients,             "SENSITIVITY_coefficients_by_fold.csv")
w(selected_coefficients,    "SENSITIVITY_selected_coefficients.csv")
w(coefficient_stability,    "SENSITIVITY_selection_frequency_and_sign_stability.csv")
w(selection_frequency_wide, "SENSITIVITY_selection_frequency_wide.csv")
w(stability_across_models,  "SENSITIVITY_stable_predictors_across_models.csv")
w(lambda_choices,           "SENSITIVITY_lambda_choices.csv")
w(comparison_headline,      "SENSITIVITY_comparison_with_primary.csv")
w(common_row_comparison,    "SENSITIVITY_comparison_with_primary_common_rows.csv")
w(persistence_comparison,   "SENSITIVITY_persistence_benchmark.csv")

manifest <- data.frame(
  field = c("run_scope", "target", "log_target_repeated", "outer_validation_years",
            "fold_rule", "lambda_selection", "lambda_rules", "scaling",
            "data_gate", "seed", "n_samples", "sample_ids",
            "primary_comparison_source", "interpretation",
            "R_version", "glmnet_version", "timestamp_utc"),
  value = c("sensitivity analyses only; primary FINAL run untouched",
            "target_homeless_rate_per_10k (raw rate)",
            "FALSE (final analysis showed the log target performed worse)",
            paste(FINAL_VAL_YEARS, collapse = ";"),
            "expanding-window rolling origin by target year, identical to the final run",
            "nested forward-chaining time CV inside each outer training window",
            "lambda.min and lambda.1se",
            "predictor standardization fit on training rows only",
            "strict: any NA/NaN/Inf in target/controls/predictors stops the run",
            SEED, length(sample_ids), paste(sample_ids, collapse = ";"),
            final_overall_path, "predictive associations only, not causal effects",
            R.version.string, as.character(packageVersion("glmnet")),
            format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")),
  stringsAsFactors = FALSE)
w(manifest, "SENSITIVITY_run_manifest.csv")

wb <- createWorkbook()
addSheet <- function(nm, df) { addWorksheet(wb, nm); writeData(wb, nm, df) }
addSheet("run_manifest",        manifest)
addSheet("sample_definitions",  sample_defs)
addSheet("row_coc_exclusions",  read.csv(file.path(DEF_DIR, "sensitivity_row_coc_exclusions.csv")))
addSheet("fold_definitions",    fold_definitions)
addSheet("metrics_overall",     metrics_overall)
addSheet("performance_by_fold", metrics_by_fold)
addSheet("selection_stability", coefficient_stability)
addSheet("selfreq_wide",        selection_frequency_wide)
addSheet("stable_predictors",   stability_across_models)
addSheet("vs_primary",          comparison_headline)
addSheet("vs_primary_common",   common_row_comparison)
addSheet("persistence",         persistence_comparison)
addSheet("ca_fl_performance",   state_performance)
saveWorkbook(wb, file.path(RES_DIR, "SENSITIVITY_model_summary.xlsx"), overwrite = TRUE)

## ---------------------------------------------------------------------------
## CONSOLE SUMMARY
## ---------------------------------------------------------------------------
banner("Pooled out-of-time performance by sensitivity sample (raw-rate target)")
hl <- metrics_overall[metrics_overall$model %in%
        c("state_time_baseline", "pooled_lasso", "pooled_lasso_state_interactions"), ]
print(hl[, c("sample_id", "model", "lambda_rule", "n", "rmse", "mae", "r2")], row.names = FALSE)

banner("Persistence benchmark")
print(persistence_comparison[, c("sample_id", "comparison", "n", "rmse", "mae", "r2",
                                 "mean_nonzero_penalized_per_fold",
                                 "pct_rmse_change_vs_persistence_baseline")], row.names = FALSE)

banner(sprintf("Predictors stable across every sample (pooled_lasso, lambda.%s)", PRIMARY_LAMBDA_RULE))
st <- stability_across_models[stability_across_models$lambda_rule == PRIMARY_LAMBDA_RULE &
                              stability_across_models$stable_across_all_samples &
                              stability_across_models$role == "penalized_predictor", ]
print(st[, c("term", "n_samples_available", "min_selection_freq",
             "mean_selection_freq", "sign_primary")], row.names = FALSE)

cat("\nOutputs written to ", RES_DIR, "/\n", sep = "")
cat("All results are PREDICTIVE ASSOCIATIONS, not causal effects.\n")
