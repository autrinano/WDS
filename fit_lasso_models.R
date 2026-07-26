###############################################################################
# fit_lasso_models.R
#
# Reproducible LASSO modeling pipeline for the California-Florida CoC-year
# homelessness panel. This script OWNS the modeling only. It does not read,
# write, or modify any dataset, dataset-building script, or central project
# documentation. It reads one prepared model-input workbook and writes every
# output under outputs/lasso_models/.
#
# Target:        target_homeless_rate_per_10k (next-year CoC PIT rate).
# Predictors:    prior-year candidate predictors already baked into the input.
# Design:        state + linear-time controls are UNPENALIZED baseline controls;
#                all candidate predictors are PENALIZED.
#
# Validation (two nested time levels, never a random row split):
#   * OUTER  - expanding-window rolling origin by target year. Train on all
#              target years strictly before the held-out year; score that year.
#   * INNER  - lambda is tuned by nested FORWARD-CHAINING (rolling-origin) time
#              validation WITHIN each outer training window: each inner split
#              trains on earlier years and validates on the next later year, so
#              lambda is never chosen using future years. This replaces ordinary
#              leave-one-year-out grouped CV, which lets any year (including
#              later ones) predict any other and thus leaks time order.
#   Both lambda.min and lambda.1se are carried through as parallel sensitivity
#   variants so coefficient/prediction stability under stronger regularization
#   is visible.
#
# Scaling is fit on training rows only (outer training for scoring; inner-train
# only inside the lambda search) and applied to held-out rows.
#
# STRICT DATA GATE
# ----------------
# The target, both controls, and every predictor must be fully finite. If ANY
# NA / NaN / Inf appears in those columns the run STOPS with an error. The
# pipeline does not silently impute; missing/degenerate values must be resolved
# upstream in the (independently owned) data build, not here.
#
# INTERPRETATION NOTE
# -------------------
# All results are ASSOCIATIONAL and PREDICTIVE, not causal. Coefficients and
# selection frequencies describe how predictors track the outcome in this small,
# time-ordered, two-state panel; they do not identify causal effects. Feature
# rankings are treated cautiously and are not impact estimates.
#
# STATUS GUARD
# ------------
# The definitive model is only reported once the coordinator confirms that
# CA_FL_LASSO_MODEL_INPUT_v2.xlsx has passed independent QA and EDA. Until then
# this pipeline runs in DEVELOPMENT mode (defaulting to v1 input) and stamps
# every output PRELIMINARY. Set input to v2 AND coordinator_confirmed_v2 <- TRUE
# only after that confirmation.
###############################################################################

suppressWarnings(suppressMessages({
  .libPaths(c("_r_libs", .libPaths()))
  library(glmnet)
  library(Matrix)
  library(openxlsx)
}))

## ---------------------------------------------------------------------------
## CONFIG
## ---------------------------------------------------------------------------

INPUT_DIR  <- "outputs/lasso_model"    # where the prepared model input lives
OUTPUT_DIR <- "outputs/lasso_models"   # where ALL model outputs are written

INPUT_V1 <- file.path(INPUT_DIR, "CA_FL_LASSO_MODEL_INPUT.xlsx")
INPUT_V2 <- file.path(INPUT_DIR, "CA_FL_LASSO_MODEL_INPUT_v2.xlsx")

# Coordinator sign-off gate. Set TRUE only after v2 has passed independent QA
# (outputs/qa_v2/QA_AUDIT_v2.md) and EDA (outputs/eda_v2/EDA_FINDINGS_v2.md) and
# the coordinator confirms. TRUE selects v2 as the definitive input and stamps
# every output FINAL.
coordinator_confirmed_v2 <- TRUE

# Log-target sensitivity analysis. Enabled: the v2 EDA reports raw-target
# skewness 1.77 and judges a log-target run WARRANTED (EDA_FINDINGS_v2.md sec 2).
run_log_target <- TRUE

# Expected definitive input and its content fingerprint. Recorded in the
# manifest and checked at load so a FINAL run can only be produced from the
# audited v2 workbook (887 rows x 47 cols, MD5 below).
EXPECTED_V2_MD5 <- "5d3fd16b32c687e5207ea59c902e7bef"

# Outer rolling-origin: earliest validation year needs this many training years.
min_train_years <- 5
# Inner forward-chaining: first inner-train window uses this many earliest years
# (reduced automatically when a training window is short).
min_inner_train_years <- 2
# Which lambda rule drives the console headline (both are always exported).
primary_lambda_rule <- "min"

SEED <- 20260724
sheet_name <- "LASSO Model Data"

# Column roles. Target and controls are fixed by the data contract; predictors
# are inferred so a v2 predictor-set change is handled automatically.
id_cols      <- c("state", "state_abbr", "coc_number", "coc_name",
                  "predictor_year", "target_year")
target_col   <- "target_homeless_rate_per_10k"
control_cols <- c("control_state_florida", "control_time_index")

## ---------------------------------------------------------------------------
## INPUT SELECTION + STATUS
## ---------------------------------------------------------------------------

if (file.exists(INPUT_V2) && coordinator_confirmed_v2) {
  input_file <- INPUT_V2; run_mode <- "FINAL"
} else if (file.exists(INPUT_V2) && !coordinator_confirmed_v2) {
  input_file <- INPUT_V2; run_mode <- "DEVELOPMENT_V2_UNCONFIRMED"
} else {
  input_file <- INPUT_V1; run_mode <- "DEVELOPMENT_V1"
}
if (!file.exists(input_file)) stop("Model input workbook not found: ", input_file)
is_preliminary <- run_mode != "FINAL"

# Content fingerprint of the input actually loaded (recorded in the manifest).
input_md5 <- unname(tools::md5sum(input_file))

# FINAL-mode integrity guard: a definitive run must read the audited v2 workbook
# and its MD5 must match the expected fingerprint. This prevents a FINAL label
# from ever being attached to v1 or to a silently changed v2.
if (!is_preliminary) {
  if (!identical(normalizePath(input_file), normalizePath(INPUT_V2)))
    stop("FINAL run must use v2 input (", INPUT_V2, "); got ", input_file)
  if (!identical(input_md5, EXPECTED_V2_MD5))
    stop("FINAL run aborted: v2 workbook MD5 ", input_md5,
         " does not match expected ", EXPECTED_V2_MD5,
         ". The audited input has changed; re-confirm QA/EDA before a FINAL run.")
}

banner <- function(txt) {
  line <- paste(rep("=", 78), collapse = "")
  cat(line, "\n", txt, "\n", line, "\n", sep = "")
}

banner(sprintf("fit_lasso_models.R  |  mode = %s", run_mode))
if (is_preliminary) {
  cat("*** PRELIMINARY RUN: pipeline structure test only. ***\n")
  cat("*** Do NOT report these as definitive results. Awaiting v2 QA/EDA sign-off. ***\n")
}
cat("Input workbook: ", input_file, "\n", sep = "")
cat("Output folder : ", OUTPUT_DIR, "\n\n", sep = "")

set.seed(SEED)
if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)

tag  <- if (is_preliminary) "PRELIMINARY" else "FINAL"
outp <- function(name) file.path(OUTPUT_DIR, sprintf("%s_%s", tag, name))

## ---------------------------------------------------------------------------
## LOAD + VALIDATE INPUT (read-only)
## ---------------------------------------------------------------------------

dat <- read.xlsx(input_file, sheet = sheet_name)

need <- c(id_cols, target_col, control_cols)
missing_cols <- setdiff(need, names(dat))
if (length(missing_cols)) stop("Input is missing required columns: ",
                               paste(missing_cols, collapse = ", "))

predictor_cols <- setdiff(names(dat), c(id_cols, target_col, control_cols))
if (!length(predictor_cols)) stop("No candidate predictor columns found.")

non_numeric <- predictor_cols[!vapply(dat[predictor_cols], is.numeric, logical(1))]
if (length(non_numeric)) stop("Non-numeric predictor columns cannot enter the model matrix: ",
                              paste(non_numeric, collapse = ", "))

## STRICT FINITE GATE ---------------------------------------------------------
## Fail the run if the target, either control, or any predictor holds a value
## that is not finite (NA, NaN, +/-Inf). No silent imputation.
model_cols <- c(target_col, control_cols, predictor_cols)
nonfinite  <- vapply(dat[model_cols], function(v) sum(!is.finite(v)), integer(1))
if (any(nonfinite > 0)) {
  bad <- nonfinite[nonfinite > 0]
  role <- ifelse(names(bad) == target_col, "target",
          ifelse(names(bad) %in% control_cols, "control", "predictor"))
  msg <- paste(sprintf("  [%s] %s: %d non-finite", role, names(bad), bad), collapse = "\n")
  stop("Non-finite (NA/NaN/Inf) values found in model columns; ",
       "the pipeline fails instead of imputing. Fix these upstream:\n", msg)
}
cat("Strict finite gate passed: target, controls, and all predictors are fully finite.\n")

cat(sprintf("Loaded %d rows x %d cols | %d predictors | %d CoCs | target years %s\n\n",
            nrow(dat), ncol(dat), length(predictor_cols),
            length(unique(dat$coc_number)),
            paste(range(dat$target_year), collapse = "-")))

## ---------------------------------------------------------------------------
## OUTER ROLLING-ORIGIN FOLDS (expanding window by target year)
## ---------------------------------------------------------------------------
all_years <- sort(unique(dat$target_year))
val_years <- all_years[sapply(all_years, function(y) sum(all_years < y) >= min_train_years)]
if (!length(val_years)) stop("Not enough distinct target years for min_train_years = ", min_train_years)

folds <- lapply(seq_along(val_years), function(i) {
  vy <- val_years[i]
  list(fold = i, val_year = vy,
       train_idx = which(dat$target_year <  vy),
       val_idx   = which(dat$target_year == vy),
       train_years = all_years[all_years < vy])
})
fold_defs <- do.call(rbind, lapply(folds, function(f) data.frame(
  fold = f$fold, validation_year = f$val_year,
  n_train_years = length(f$train_years),
  train_year_min = min(f$train_years), train_year_max = max(f$train_years),
  n_train_rows = length(f$train_idx), n_val_rows = length(f$val_idx),
  stringsAsFactors = FALSE)))
cat("Outer rolling-origin folds:\n"); print(fold_defs, row.names = FALSE); cat("\n")

## ---------------------------------------------------------------------------
## DESIGN-MATRIX BUILDER  (scaling fit on fit_rows only; NO imputation)
## ---------------------------------------------------------------------------
# A "spec" describes one model's design:
#   rows         - candidate training rows (already state-filtered if needed)
#   controls     - unpenalized control columns to include
#   interactions - add state-by-predictor interaction columns (penalized)
# build_design() standardizes predictors using fit_rows statistics and applies
# them to apply_rows, so inner CV can re-fit scaling on each inner-train window.

std_params <- function(mat) {
  ctr <- colMeans(mat)
  scl <- apply(mat, 2, sd)
  scl[!is.finite(scl) | scl == 0] <- 1     # degenerate-scale guard (not imputation)
  list(center = ctr, scale = scl)
}

build_design <- function(spec, fit_rows, apply_rows) {
  Xfit <- as.matrix(dat[fit_rows, predictor_cols, drop = FALSE])
  pp   <- std_params(Xfit)
  Xap  <- as.matrix(dat[apply_rows, predictor_cols, drop = FALSE])
  Xs   <- scale(Xap, center = pp$center, scale = pp$scale)
  C    <- as.matrix(dat[apply_rows, spec$controls, drop = FALSE])
  if (isTRUE(spec$interactions)) {
    fl <- dat[apply_rows, "control_state_florida"]
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
## NESTED FORWARD-CHAINING LAMBDA TUNER
## ---------------------------------------------------------------------------
# Selects lambda over a shared grid using rolling-origin inner splits: for
# ordered training years y[1..K], inner split c trains on y[1..c] and validates
# on y[c+1]. CV error per lambda is averaged across inner splits; lambda.min
# minimizes it and lambda.1se is the most-regularized lambda within one standard
# error of the minimum. The final model is refit on the full training window.

tune_fc <- function(spec, yof) {
  rows  <- spec$rows
  years <- dat$target_year[rows]
  uy    <- sort(unique(years))
  K     <- length(uy)

  full  <- build_design(spec, rows, rows)
  yfull <- yof(rows)
  gfit  <- suppressWarnings(glmnet(full$x, yfull, alpha = 1,
                                   penalty.factor = full$penalty, standardize = FALSE))
  grid  <- gfit$lambda

  c0    <- max(1, min(min_inner_train_years, K - 1))
  cuts  <- if (K >= 2) c0:(K - 1) else integer(0)

  if (!length(cuts)) {              # cannot tune temporally; fall back safely
    return(list(gfit = gfit, grid = grid,
                lambda.min = grid[length(grid)], lambda.1se = grid[1],
                n_inner_splits = 0L))
  }

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
    pr  <- predict(fit, newx = dva$x, s = grid)  # rows x length(grid)
    yv  <- yof(iva)
    err[i, ] <- colMeans((yv - pr)^2)
  }
  cvm  <- colMeans(err, na.rm = TRUE)
  cvsd <- apply(err, 2, function(z) { z <- z[!is.na(z)]
                if (length(z) < 2) NA_real_ else sd(z) / sqrt(length(z)) })
  imin <- which.min(cvm)
  lmin <- grid[imin]
  se   <- cvsd[imin]
  if (is.na(se)) {
    l1se <- lmin
  } else {
    cand <- which(cvm <= cvm[imin] + se)   # grid is decreasing: min index = largest lambda
    l1se <- grid[min(cand)]
  }
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
metric_row <- function(model, rule, fold, vy, group, a, p) data.frame(
  model = model, lambda_rule = rule, fold = fold, validation_year = vy,
  group = group, n = length(a), rmse = rmse(a, p), mae = mae(a, p),
  r2 = r2(a, p), stringsAsFactors = FALSE)

## ---------------------------------------------------------------------------
## PIPELINE (identity target; reused for log-target sensitivity)
## ---------------------------------------------------------------------------
run_pipeline <- function(target_transform = c("identity", "log")) {
  target_transform <- match.arg(target_transform)
  is_log <- target_transform == "log"
  shift  <- if (is_log && min(dat[[target_col]]) <= 0) 1 else 0
  fwd    <- if (is_log) function(v) log(v + shift) else identity
  yof    <- function(rows) fwd(dat[[target_col]][rows])

  # Retransformation from the log scale uses Duan's (1983) nonparametric
  # smearing estimator. The factor S = mean(exp(training residuals)) corrects
  # the bias of naive exp() back-transformation. It is estimated PER model, PER
  # outer fold, PER lambda rule from TRAINING rows only (never validation), then
  # applied to that fold's validation predictions. For the identity target it
  # is fixed at 1 and back_with() is a no-op.
  duan      <- function(y_tr, yhat_tr) if (is_log) mean(exp(y_tr - yhat_tr)) else 1
  back_with <- function(v, S) if (is_log) exp(v) * S - shift else v

  preds <- list(); metrics <- list(); coefs <- list(); lambdas <- list()
  smears <- list()
  push  <- function(lst, x) { lst[[length(lst) + 1]] <- x; lst }
  record_smear <- function(model, group, fold, vy, rule, S)
    smears[[length(smears) + 1]] <<- data.frame(
      model = model, target_transform = target_transform, group = group,
      fold = fold, validation_year = vy, lambda_rule = rule,
      smearing_factor = S, stringsAsFactors = FALSE)

  # Emit predictions/metrics/coefs for one penalized spec at both lambda rules.
  process_spec <- function(model_name, spec, val_rows, group_label, fold, vy,
                           pooled_metric = TRUE) {
    tuned <- tune_fc(spec, yof)
    dva   <- build_design(spec, spec$rows, val_rows)
    dtr   <- build_design(spec, spec$rows, spec$rows)   # training design (scale from training)
    y_tr  <- yof(spec$rows)                              # training actuals, transformed scale
    ids   <- dat[val_rows, id_cols, drop = FALSE]
    a     <- dat[[target_col]][val_rows]
    lambdas[[length(lambdas) + 1]] <<- data.frame(
      model = model_name, fold = fold, validation_year = vy,
      lambda_min = tuned$lambda.min, lambda_1se = tuned$lambda.1se,
      n_inner_splits = tuned$n_inner_splits, n_grid = length(tuned$grid),
      stringsAsFactors = FALSE)
    Svec <- c(min = 1, `1se` = 1)
    for (rule in c("min", "1se")) {
      lam <- if (rule == "min") tuned$lambda.min else tuned$lambda.1se
      # Smearing factor from TRAINING residuals only at this lambda.
      yhat_tr  <- as.numeric(predict(tuned$gfit, newx = dtr$x, s = lam))
      S        <- duan(y_tr, yhat_tr)
      Svec[[rule]] <- S
      record_smear(model_name, group_label, fold, vy, rule, S)
      p   <- back_with(as.numeric(predict(tuned$gfit, newx = dva$x, s = lam)), S)
      preds[[length(preds) + 1]] <<- data.frame(
        model = model_name, lambda_rule = rule, fold = fold,
        validation_year = vy, ids, actual = a, predicted = p,
        residual = a - p, row.names = NULL, stringsAsFactors = FALSE)
      if (pooled_metric)
        metrics[[length(metrics) + 1]] <<- metric_row(model_name, rule, fold, vy, group_label, a, p)
      cf <- as.matrix(coef(tuned$gfit, s = lam))
      coefs[[length(coefs) + 1]] <<- data.frame(
        model = model_name, lambda_rule = rule, fold = fold, validation_year = vy,
        term = rownames(cf), coefficient = as.numeric(cf), lambda = lam,
        stringsAsFactors = FALSE)
    }
    invisible(list(tuned = tuned, S = Svec))
  }

  for (f in folds) {
    tr <- f$train_idx; va <- f$val_idx; fold <- f$fold; vy <- f$val_year
    a_va <- dat[[target_col]][va]

    ## (a) State-and-time baseline (OLS; no penalized predictors) -------------
    bdf  <- data.frame(y = yof(tr), dat[tr, control_cols, drop = FALSE])
    bfit <- lm(y ~ ., data = bdf)
    Sb   <- duan(yof(tr), as.numeric(fitted(bfit)))   # training-only smearing
    record_smear("state_time_baseline", "all", fold, vy, "none", Sb)
    bpred <- back_with(as.numeric(predict(bfit, newdata = dat[va, control_cols, drop = FALSE])), Sb)
    preds <- push(preds, data.frame(
      model = "state_time_baseline", lambda_rule = "none", fold = fold,
      validation_year = vy, dat[va, id_cols, drop = FALSE], actual = a_va,
      predicted = bpred, residual = a_va - bpred, row.names = NULL,
      stringsAsFactors = FALSE))
    metrics <- push(metrics, metric_row("state_time_baseline", "none", fold, vy, "all", a_va, bpred))

    ## (b) Pooled LASSO ------------------------------------------------------
    process_spec("pooled_lasso",
                 list(rows = tr, controls = control_cols, interactions = FALSE),
                 va, "all", fold, vy)

    ## (c) Pooled LASSO + state-by-predictor interactions --------------------
    process_spec("pooled_lasso_state_interactions",
                 list(rows = tr, controls = control_cols, interactions = TRUE),
                 va, "all", fold, vy)

    ## (d) Separate CA / FL LASSO sensitivity models -------------------------
    # Fit within one state (state control dropped; time unpenalized), predict
    # that state's validation rows; then pool the two for an "all" metric.
    combo <- list(min = rep(NA_real_, length(va)), `1se` = rep(NA_real_, length(va)))
    for (st in c("California", "Florida")) {
      s_tr <- tr[dat$state[tr] == st]
      s_va <- va[dat$state[va] == st]
      if (length(unique(dat$target_year[s_tr])) < 3 || !length(s_va)) next
      abbr <- if (st == "California") "CA" else "FL"
      spec <- list(rows = s_tr, controls = "control_time_index", interactions = FALSE)
      ps    <- process_spec(sprintf("separate_lasso_%s", abbr), spec, s_va, st, fold, vy)
      tuned <- ps$tuned
      dva   <- build_design(spec, spec$rows, s_va)
      pos   <- match(s_va, va)
      for (rule in c("min", "1se")) {
        lam <- if (rule == "min") tuned$lambda.min else tuned$lambda.1se
        # Reuse the training-only smearing factor from this state model/rule.
        combo[[rule]][pos] <- back_with(as.numeric(predict(tuned$gfit, newx = dva$x, s = lam)), ps$S[[rule]])
      }
    }
    for (rule in c("min", "1se")) {
      p <- combo[[rule]]; ok <- !is.na(p)
      preds <- push(preds, data.frame(
        model = "separate_state_lasso", lambda_rule = rule, fold = fold,
        validation_year = vy, dat[va, id_cols, drop = FALSE], actual = a_va,
        predicted = p, residual = a_va - p, row.names = NULL, stringsAsFactors = FALSE))
      if (any(ok))
        metrics <- push(metrics, metric_row("separate_state_lasso", rule, fold, vy, "all", a_va[ok], p[ok]))
    }
  }

  list(predictions = do.call(rbind, preds),
       metrics     = do.call(rbind, metrics),
       coefficients= do.call(rbind, coefs),
       lambdas     = do.call(rbind, lambdas),
       smearing    = do.call(rbind, smears))
}

## ---------------------------------------------------------------------------
## EXECUTE
## ---------------------------------------------------------------------------
res <- run_pipeline("identity")

## Pooled out-of-time metrics by model x lambda_rule.
key <- interaction(res$predictions$model, res$predictions$lambda_rule, drop = TRUE)
overall_metrics <- do.call(rbind, lapply(split(res$predictions, key), function(df) {
  df <- df[!is.na(df$predicted), ]
  data.frame(model = df$model[1], lambda_rule = df$lambda_rule[1],
             scope = "pooled_all_folds", n = nrow(df),
             rmse = rmse(df$actual, df$predicted), mae = mae(df$actual, df$predicted),
             r2 = r2(df$actual, df$predicted), stringsAsFactors = FALSE)
}))
overall_metrics <- overall_metrics[order(overall_metrics$model, overall_metrics$lambda_rule), ]

## California- and Florida-specific pooled out-of-time performance (every model).
skey <- interaction(res$predictions$model, res$predictions$lambda_rule,
                    res$predictions$state, drop = TRUE)
state_performance <- do.call(rbind, lapply(split(res$predictions, skey), function(df) {
  df <- df[!is.na(df$predicted), ]
  if (!nrow(df)) return(NULL)
  data.frame(model = df$model[1], lambda_rule = df$lambda_rule[1],
             state = df$state[1], scope = "pooled_all_folds", n = nrow(df),
             rmse = rmse(df$actual, df$predicted), mae = mae(df$actual, df$predicted),
             r2 = r2(df$actual, df$predicted), stringsAsFactors = FALSE)
}))
state_performance <- state_performance[order(state_performance$model,
                       state_performance$lambda_rule, state_performance$state), ]

## lambda.min vs lambda.1se comparison (pooled out-of-time), penalized models.
lambda_rule_comparison <- do.call(rbind, lapply(
  split(overall_metrics, overall_metrics$model), function(df) {
    mn <- df[df$lambda_rule == "min", ]; se <- df[df$lambda_rule == "1se", ]
    if (!nrow(mn) || !nrow(se)) return(NULL)
    data.frame(model = df$model[1], n = mn$n,
               rmse_min = mn$rmse, rmse_1se = se$rmse,
               rmse_diff_1se_minus_min = se$rmse - mn$rmse,
               mae_min = mn$mae, mae_1se = se$mae,
               r2_min = mn$r2, r2_1se = se$r2, stringsAsFactors = FALSE)
  }))

## Residual diagnostics by model x lambda_rule (all, and per state).
resid_summ <- function(df, group) { df <- df[!is.na(df$residual), ]
  if (!nrow(df)) return(NULL)
  data.frame(model = df$model[1], lambda_rule = df$lambda_rule[1], group = group,
             n = nrow(df), mean_resid = mean(df$residual), sd_resid = sd(df$residual),
             mean_abs_resid = mean(abs(df$residual)), max_abs_resid = max(abs(df$residual)),
             stringsAsFactors = FALSE) }
rd_all <- do.call(rbind, lapply(split(res$predictions, key), resid_summ, group = "all"))
rd_st  <- do.call(rbind, lapply(
  split(res$predictions, list(res$predictions$model, res$predictions$lambda_rule,
                              res$predictions$state), drop = TRUE),
  function(df) resid_summ(df, df$state[1])))
residual_diagnostics <- rbind(rd_all, rd_st)

## Coefficient stability across validation periods, per model x lambda_rule.
ckey <- interaction(res$coefficients$model, res$coefficients$lambda_rule, drop = TRUE)
stability <- do.call(rbind, lapply(split(res$coefficients, ckey), function(df) {
  df <- df[df$term != "(Intercept)", ]
  do.call(rbind, lapply(split(df, df$term), function(t) {
    nz <- t$coefficient[abs(t$coefficient) > 0]
    data.frame(model = t$model[1], lambda_rule = t$lambda_rule[1], term = t$term[1],
               n_folds = nrow(t), n_selected = length(nz),
               selection_freq = length(nz) / nrow(t),
               mean_coef = mean(t$coefficient), sd_coef = sd(t$coefficient),
               mean_coef_when_selected = if (length(nz)) mean(nz) else NA_real_,
               sign_consistency = if (length(nz)) max(mean(nz > 0), mean(nz < 0)) else NA_real_,
               stringsAsFactors = FALSE)
  }))
}))
stability <- stability[order(stability$model, stability$lambda_rule,
                             -stability$selection_freq, -abs(stability$mean_coef)), ]

## Optional log-target sensitivity.
if (run_log_target) {
  cat("Running log-target sensitivity analysis...\n")
  res_log <- run_pipeline("log")
  lkey <- interaction(res_log$predictions$model, res_log$predictions$lambda_rule, drop = TRUE)
  log_overall <- do.call(rbind, lapply(split(res_log$predictions, lkey), function(df) {
    df <- df[!is.na(df$predicted), ]
    data.frame(model = df$model[1], lambda_rule = df$lambda_rule[1],
               scope = "pooled_all_folds_LOGTARGET", n = nrow(df),
               rmse = rmse(df$actual, df$predicted), mae = mae(df$actual, df$predicted),
               r2 = r2(df$actual, df$predicted), stringsAsFactors = FALSE)
  }))
  ## Raw-target vs log-target comparison (log predictions already smearing-corrected
  ## and back on the per-10k scale, so RMSE/MAE/R2 are directly comparable).
  raw_tab <- overall_metrics[, c("model", "lambda_rule", "rmse", "mae", "r2")]
  names(raw_tab)[3:5] <- paste0(names(raw_tab)[3:5], "_raw")
  log_tab <- log_overall[, c("model", "lambda_rule", "rmse", "mae", "r2")]
  names(log_tab)[3:5] <- paste0(names(log_tab)[3:5], "_log")
  raw_vs_log_comparison <- merge(raw_tab, log_tab, by = c("model", "lambda_rule"), all = TRUE)
  raw_vs_log_comparison$rmse_diff_log_minus_raw <-
    raw_vs_log_comparison$rmse_log - raw_vs_log_comparison$rmse_raw
  raw_vs_log_comparison <- raw_vs_log_comparison[
    order(raw_vs_log_comparison$model, raw_vs_log_comparison$lambda_rule), ]
}

## ---------------------------------------------------------------------------
## WRITE OUTPUTS (outputs/lasso_models/ only)
## ---------------------------------------------------------------------------
write.csv(fold_defs,            outp("fold_definitions.csv"),            row.names = FALSE)
write.csv(res$metrics,          outp("metrics_by_fold.csv"),             row.names = FALSE)
write.csv(overall_metrics,      outp("metrics_overall_out_of_time.csv"), row.names = FALSE)
write.csv(res$predictions,      outp("predictions.csv"),                 row.names = FALSE)
write.csv(residual_diagnostics, outp("residual_diagnostics.csv"),        row.names = FALSE)
write.csv(res$coefficients,     outp("coefficients_by_fold.csv"),        row.names = FALSE)
write.csv(res$lambdas,          outp("lambda_choices.csv"),              row.names = FALSE)
write.csv(stability,            outp("coefficient_stability.csv"),       row.names = FALSE)
write.csv(state_performance,    outp("ca_fl_state_performance.csv"),     row.names = FALSE)
write.csv(lambda_rule_comparison, outp("lambda_min_vs_1se_comparison.csv"), row.names = FALSE)
if (run_log_target) {
  write.csv(res_log$predictions, outp("log_target_predictions.csv"),        row.names = FALSE)
  write.csv(log_overall,         outp("log_target_metrics_overall.csv"),    row.names = FALSE)
  write.csv(res_log$smearing,    outp("log_target_smearing_factors.csv"),   row.names = FALSE)
  write.csv(raw_vs_log_comparison, outp("raw_vs_log_comparison.csv"),       row.names = FALSE)
}

manifest <- data.frame(
  field = c("run_mode", "is_preliminary", "input_file", "input_md5",
            "expected_v2_md5", "input_md5_matches_expected",
            "coordinator_confirmed_v2", "run_log_target",
            "log_retransformation", "lambda_selection",
            "primary_lambda_rule", "min_train_years", "min_inner_train_years",
            "seed", "n_rows", "n_predictors", "n_cocs", "target_year_range",
            "n_outer_folds", "outer_validation_years",
            "excluded_coc_fl518_reason", "excluded_target_2021_reason",
            "coc_boundaries", "interpretation",
            "R_version", "glmnet_version", "timestamp_utc"),
  value = c(run_mode, is_preliminary, input_file, input_md5,
            EXPECTED_V2_MD5, identical(input_md5, EXPECTED_V2_MD5),
            coordinator_confirmed_v2, run_log_target,
            "duan_smearing_training_only_fold_specific",
            "nested_forward_chaining_time_cv", primary_lambda_rule,
            min_train_years, min_inner_train_years, SEED, nrow(dat),
            length(predictor_cols), length(unique(dat$coc_number)),
            paste(range(dat$target_year), collapse = "-"), length(folds),
            paste(val_years, collapse = ";"),
            "FL-518 absent from v2: FHFA county HPI predictor unavailable for it (only Zillow-dark CoC not covered by coc_relative_home_price_index_2000_base)",
            "2021 PIT outcome excluded as target: COVID-disrupted enumeration not comparable",
            "FY2024 HUD CoC boundaries applied retrospectively via ACS 2024 tract-population shares",
            "coefficients are predictive associations, not causal effects",
            R.version.string, as.character(packageVersion("glmnet")),
            format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")),
  stringsAsFactors = FALSE)
write.csv(manifest, outp("run_manifest.csv"), row.names = FALSE)

## Required plain-language statements about the definitive v2 run.
statements <- c(
  "# FINAL LASSO analysis — required statements (CA/FL homelessness, v2)",
  "",
  sprintf("- Definitive input: %s (MD5 %s; matches expected: %s).",
          input_file, input_md5, identical(input_md5, EXPECTED_V2_MD5)),
  sprintf("- The v2 modeling dataset contains %d rows and %d CoCs.",
          nrow(dat), length(unique(dat$coc_number))),
  "- FL-518 is excluded because the FHFA House Price Index (HPI) predictor is unavailable for it.",
  "- The 2021 PIT outcome is excluded (COVID-disrupted enumeration is not comparable across years).",
  "- FY2024 CoC boundaries are applied retrospectively; historical CoC mergers/splits remain a measurement-error source.",
  "- All coefficients and selection results are PREDICTIVE ASSOCIATIONS, not causal effects.",
  "- Validation is out-of-time only: expanding-window rolling origin over target years",
  sprintf("  %s; lambda is tuned by nested forward-chaining within each training window;", paste(val_years, collapse = ", ")),
  "  scaling and Duan smearing are fit on training rows only; no random row splits and no in-sample metrics.")
writeLines(statements, outp("analysis_statements.md"))

wb <- createWorkbook()
addSheet <- function(nm, df) { addWorksheet(wb, nm); writeData(wb, nm, df) }
addSheet("run_manifest",     manifest)
addSheet("fold_definitions", fold_defs)
addSheet("metrics_overall",  overall_metrics)
addSheet("metrics_by_fold",  res$metrics)
addSheet("coef_stability",   stability)
addSheet("residual_diag",    residual_diagnostics)
addSheet("lambda_choices",   res$lambdas)
addSheet("ca_fl_performance", state_performance)
addSheet("lambda_min_vs_1se", lambda_rule_comparison)
if (run_log_target) {
  addSheet("raw_vs_log",   raw_vs_log_comparison)
  addSheet("log_smearing", res_log$smearing)
}
saveWorkbook(wb, outp("model_summary.xlsx"), overwrite = TRUE)

## ---------------------------------------------------------------------------
## CONSOLE SUMMARY
## ---------------------------------------------------------------------------
banner("Out-of-time performance (pooled across rolling-origin folds)")
print(overall_metrics[, c("model", "lambda_rule", "n", "rmse", "mae", "r2")], row.names = FALSE)
cat(sprintf("\nTop stable predictors (pooled_lasso, lambda.%s, by selection frequency):\n",
            primary_lambda_rule))
top <- stability[stability$model == "pooled_lasso" &
                 stability$lambda_rule == primary_lambda_rule, ]
print(head(top[, c("term", "selection_freq", "mean_coef", "sign_consistency")], 12), row.names = FALSE)

cat("\nOutputs written to ", OUTPUT_DIR, "/ with prefix '", tag, "_'.\n", sep = "")
if (is_preliminary)
  banner("PRELIMINARY: association/prediction only, not causal. Awaiting v2 QA/EDA sign-off before any definitive reporting.")
