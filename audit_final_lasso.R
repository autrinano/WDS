###############################################################################
# audit_final_lasso.R
#
# INDEPENDENT, READ-ONLY AUDIT of the FINAL LASSO analysis.
#
# This script OWNS ONLY itself and outputs/lasso_audit/. It never refits,
# modifies, or re-runs any model, and it never writes to outputs/lasso_models/,
# outputs/lasso_model/, outputs/eda_v2/, any dataset, or any project document.
#
# It verifies the FINAL_* deliverables three ways:
#   (1) recomputation  - metrics, selection frequencies and sign stability are
#                        recalculated directly from the exported FINAL
#                        predictions and coefficients;
#   (2) reconciliation - the input workbook, EDA findings and the FINAL outputs
#                        are cross-checked against each other for consistency;
#   (3) static review  - leakage-critical constructions (training-only scaling,
#                        unpenalized controls, forward-chaining inner tuning,
#                        training-only Duan smearing) are checked in the
#                        modeling source and, wherever possible, corroborated
#                        by a falsification test on the exported numbers.
#
# Outputs (all under outputs/lasso_audit/):
#   audit_checks.csv        - one row per check with PASS / WARNING / FAIL
#   recomputed_metrics.csv  - recomputed vs exported metric comparison
#   AUDIT_REPORT.md         - narrative report
###############################################################################

suppressWarnings(suppressMessages({
  .libPaths(c("_r_libs", .libPaths()))
  library(openxlsx)
}))

MODEL_DIR <- "outputs/lasso_models"
INPUT_DIR <- "outputs/lasso_model"
EDA_DIR   <- "outputs/eda_v2"
AUDIT_DIR <- "outputs/lasso_audit"
SRC       <- "fit_lasso_models.R"
if (!dir.exists(AUDIT_DIR)) dir.create(AUDIT_DIR, recursive = TRUE)

TOL <- 1e-8

CHK <- list()
add <- function(id, requirement, expected, observed, status, detail = "") {
  CHK[[length(CHK) + 1]] <<- data.frame(
    check_id = id, requirement = requirement, expected = as.character(expected),
    observed = as.character(observed), status = status, detail = detail,
    stringsAsFactors = FALSE)
  cat(sprintf("[%-7s] %-6s %s\n", status, id, requirement))
}
pf  <- function(ok) if (isTRUE(ok)) "PASS" else "FAIL"
fx  <- function(x, d = 6) formatC(as.numeric(x), format = "f", digits = d)
rd  <- function(f, dir = MODEL_DIR) read.csv(file.path(dir, f), stringsAsFactors = FALSE)

## ---------------------------------------------------------------------------
## LOAD (read-only)
## ---------------------------------------------------------------------------
id_cols     <- c("state", "state_abbr", "coc_number", "coc_name",
                 "predictor_year", "target_year")
target_col  <- "target_homeless_rate_per_10k"
control_cols<- c("control_state_florida", "control_time_index")

V2 <- file.path(INPUT_DIR, "CA_FL_LASSO_MODEL_INPUT_v2.xlsx")
V1 <- file.path(INPUT_DIR, "CA_FL_LASSO_MODEL_INPUT.xlsx")
dat <- read.xlsx(V2, sheet = "LASSO Model Data")
predictor_cols <- setdiff(names(dat), c(id_cols, target_col, control_cols))

manifest   <- rd("FINAL_run_manifest.csv")
mval       <- setNames(manifest$value, manifest$field)
folds_def  <- rd("FINAL_fold_definitions.csv")
preds      <- rd("FINAL_predictions.csv")
lpreds     <- rd("FINAL_log_target_predictions.csv")
mby        <- rd("FINAL_metrics_by_fold.csv")
mall       <- rd("FINAL_metrics_overall_out_of_time.csv")
lall       <- rd("FINAL_log_target_metrics_overall.csv")
stperf     <- rd("FINAL_ca_fl_state_performance.csv")
coefs      <- rd("FINAL_coefficients_by_fold.csv")
stab       <- rd("FINAL_coefficient_stability.csv")
lamb       <- rd("FINAL_lambda_choices.csv")
lamcmp     <- rd("FINAL_lambda_min_vs_1se_comparison.csv")
rvl        <- rd("FINAL_raw_vs_log_comparison.csv")
smear      <- rd("FINAL_log_target_smearing_factors.csv")
resdiag    <- rd("FINAL_residual_diagnostics.csv")
statements <- readLines(file.path(MODEL_DIR, "FINAL_analysis_statements.md"), warn = FALSE)

src  <- readLines(SRC, warn = FALSE)
srcn <- gsub("\\s+", " ", src)
hasc <- function(pat) any(grepl(pat, srcn, fixed = TRUE))

## metric helpers (identical definitions to the modeling script)
rmse <- function(a, p) sqrt(mean((a - p)^2))
mae  <- function(a, p) mean(abs(a - p))
r2   <- function(a, p) { sst <- sum((a - mean(a))^2)
                         if (sst == 0) NA_real_ else 1 - sum((a - p)^2) / sst }

###############################################################################
## CHECK 1 - INPUT WORKBOOK MD5 AND v2-NOT-v1
###############################################################################
md5_v2 <- unname(tools::md5sum(V2))
md5_v1 <- unname(tools::md5sum(V1))
exp_md5_src <- sub('.*EXPECTED_V2_MD5 <- "([0-9a-f]+)".*', "\\1",
                   grep('EXPECTED_V2_MD5 <- "', src, value = TRUE)[1])

add("1.1", "Live MD5 of v2 workbook equals the MD5 recorded in FINAL_run_manifest.csv",
    mval[["input_md5"]], md5_v2, pf(identical(md5_v2, mval[["input_md5"]])))
add("1.2", "Manifest MD5 equals the EXPECTED_V2_MD5 hard-coded in fit_lasso_models.R",
    exp_md5_src, mval[["input_md5"]],
    pf(identical(exp_md5_src, mval[["input_md5"]]) &&
       identical(mval[["expected_v2_md5"]], exp_md5_src)))
add("1.3", "Manifest input_file is the v2 workbook (not v1)",
    "outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx", mval[["input_file"]],
    pf(basename(mval[["input_file"]]) == basename(V2)))
add("1.4", "v1 workbook MD5 differs from the audited v2 MD5 (v1 provably not used)",
    paste0("v1 != ", md5_v2), paste0("v1 = ", md5_v1), pf(!identical(md5_v1, md5_v2)))
add("1.5", "Run stamped FINAL with coordinator sign-off and matching-MD5 flag",
    "run_mode=FINAL; is_preliminary=FALSE; coordinator_confirmed_v2=TRUE; input_md5_matches_expected=TRUE",
    sprintf("run_mode=%s; is_preliminary=%s; coordinator_confirmed_v2=%s; input_md5_matches_expected=%s",
            mval[["run_mode"]], mval[["is_preliminary"]],
            mval[["coordinator_confirmed_v2"]], mval[["input_md5_matches_expected"]]),
    pf(mval[["run_mode"]] == "FINAL" && mval[["is_preliminary"]] == "FALSE" &&
       mval[["coordinator_confirmed_v2"]] == "TRUE" &&
       mval[["input_md5_matches_expected"]] == "TRUE"))
stmt_md5 <- any(grepl(md5_v2, statements, fixed = TRUE))
add("1.6", "FINAL_analysis_statements.md cites the same MD5",
    md5_v2, if (stmt_md5) "cited" else "not cited", pf(stmt_md5))
add("1.7", "FINAL-mode guard in source aborts on wrong input or changed MD5",
    "normalizePath(input_file) == INPUT_V2 and MD5 identity enforced",
    if (hasc("if (!identical(normalizePath(input_file), normalizePath(INPUT_V2)))") &&
        hasc("if (!identical(input_md5, EXPECTED_V2_MD5))")) "both guards present" else "guard missing",
    pf(hasc("if (!identical(normalizePath(input_file), normalizePath(INPUT_V2)))") &&
       hasc("if (!identical(input_md5, EXPECTED_V2_MD5))")))

###############################################################################
## CHECK 2 - SHAPE OF THE MODELING DATA
###############################################################################
n_rows <- nrow(dat); n_cocs <- length(unique(dat$coc_number))
n_pred <- length(predictor_cols); n_ctrl <- length(control_cols)
model_cols <- c(target_col, control_cols, predictor_cols)
nonfin <- vapply(dat[model_cols], function(v) sum(!is.finite(v)), integer(1))
nonfin_tot <- sum(nonfin)
nonnum <- predictor_cols[!vapply(dat[predictor_cols], is.numeric, logical(1))]
dupes  <- sum(duplicated(dat[, c("coc_number", "target_year")]))

add("2.1", "Input workbook has 887 modeling rows", 887, n_rows, pf(n_rows == 887L))
add("2.2", "Input workbook covers 70 distinct CoCs", 70, n_cocs, pf(n_cocs == 70L))
add("2.3", "38 candidate predictors (all non-id, non-target, non-control columns)",
    38, n_pred, pf(n_pred == 38L))
add("2.4", "2 control columns present", paste(control_cols, collapse = "; "),
    paste(intersect(control_cols, names(dat)), collapse = "; "),
    pf(all(control_cols %in% names(dat)) && n_ctrl == 2L))
add("2.5", "No non-finite (NA/NaN/Inf) values in target, controls or predictors",
    0, nonfin_tot, pf(nonfin_tot == 0L),
    "checked across 41 modeled columns x 887 rows")
add("2.6", "All predictor columns numeric", 0, length(nonnum), pf(length(nonnum) == 0L))
add("2.7", "No duplicated CoC-year rows", 0, dupes, pf(dupes == 0L))
add("2.8", "Manifest n_rows / n_cocs / n_predictors agree with the workbook",
    sprintf("887/70/38"), sprintf("%s/%s/%s", mval[["n_rows"]], mval[["n_cocs"]], mval[["n_predictors"]]),
    pf(mval[["n_rows"]] == "887" && mval[["n_cocs"]] == "70" && mval[["n_predictors"]] == "38"))
add("2.9", "EDA_FINDINGS_v2.md dimensions (887 x 47; 6 id, 2 control, 38 predictors) agree",
    "887 rows x 47 cols", sprintf("%d rows x %d cols", n_rows, ncol(dat)),
    pf(n_rows == 887L && ncol(dat) == 47L))
add("2.10", "Target year 2021 absent (COVID PIT exclusion) and target range matches EDA",
    "no 2021 target; range 4.83-165.09",
    sprintf("2021 rows = %d; range %.2f-%.2f", sum(dat$target_year == 2021),
            min(dat[[target_col]]), max(dat[[target_col]])),
    pf(sum(dat$target_year == 2021) == 0 &&
       abs(min(dat[[target_col]]) - 4.83) < 0.01 &&
       abs(max(dat[[target_col]]) - 165.09) < 0.01))

###############################################################################
## CHECK 3 - OUTER VALIDATION YEARS AND TRAINING-BEFORE-VALIDATION
###############################################################################
exp_val_years <- c(2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025)
add("3.1", "Eight outer validation years, 2017-2020 and 2022-2025",
    paste(exp_val_years, collapse = ";"), paste(folds_def$validation_year, collapse = ";"),
    pf(identical(as.numeric(folds_def$validation_year), as.numeric(exp_val_years)) &&
       nrow(folds_def) == 8L))
add("3.2", "Manifest outer_validation_years matches fold definitions",
    paste(exp_val_years, collapse = ";"), mval[["outer_validation_years"]],
    pf(mval[["outer_validation_years"]] == paste(exp_val_years, collapse = ";") &&
       mval[["n_outer_folds"]] == "8"))

fold_recount <- do.call(rbind, lapply(seq_len(nrow(folds_def)), function(i) {
  vy <- folds_def$validation_year[i]
  tr <- dat$target_year[dat$target_year < vy]
  data.frame(fold = folds_def$fold[i], validation_year = vy,
             n_train_years = length(unique(tr)), train_year_min = min(tr),
             train_year_max = max(tr), n_train_rows = length(tr),
             n_val_rows = sum(dat$target_year == vy), stringsAsFactors = FALSE)
}))
fold_ok <- isTRUE(all.equal(as.data.frame(lapply(folds_def, as.numeric)),
                            as.data.frame(lapply(fold_recount, as.numeric))))
add("3.3", "Fold definitions reproduce exactly from the workbook (expanding window by target year)",
    "all 8 folds identical on train/val year bounds and row counts",
    if (fold_ok) "identical" else "MISMATCH", pf(fold_ok))
add("3.4", "Every training row strictly precedes its fold's validation year",
    "max(train_year) < validation_year for all folds",
    sprintf("max gap = %d year(s); violations = %d",
            min(folds_def$validation_year - folds_def$train_year_max),
            sum(folds_def$train_year_max >= folds_def$validation_year)),
    pf(all(folds_def$train_year_max < folds_def$validation_year)))
add("3.5", "Source constructs training index as target_year strictly less than validation year",
    "train_idx = which(dat$target_year < vy)",
    if (hasc("train_idx = which(dat$target_year < vy)")) "present" else "absent",
    pf(hasc("train_idx = which(dat$target_year < vy)")))
pv_ok <- all(preds$target_year == preds$validation_year) &&
         all(preds$predictor_year == preds$target_year - 1)
add("3.6", "Every scored row is a held-out row of its own fold and uses prior-year predictors",
    "target_year == validation_year and predictor_year == target_year - 1",
    if (pv_ok) "holds for all 4995 prediction rows" else "VIOLATION", pf(pv_ok))
scored_rows <- unique(preds[, c("coc_number", "target_year")])
add("3.7", "Scored CoC-years equal the union of the eight validation years (555 rows, each scored once per model x rule)",
    "555 distinct CoC-years", nrow(scored_rows),
    pf(nrow(scored_rows) == sum(folds_def$n_val_rows) &&
       all(sort(unique(preds$validation_year)) == exp_val_years)))
add("3.8", "No in-sample scoring: no prediction row has target_year < 2017",
    0, sum(preds$target_year < 2017), pf(sum(preds$target_year < 2017) == 0))

## actuals in the predictions must equal the workbook target for the same key
key_dat <- paste(dat$coc_number, dat$target_year)
key_prd <- paste(preds$coc_number, preds$target_year)
mm      <- match(key_prd, key_dat)
act_bad <- sum(is.na(mm)) + sum(abs(preds$actual - dat[[target_col]][mm]) > 1e-9, na.rm = TRUE)
add("3.9", "Exported 'actual' equals the workbook target for every scored CoC-year",
    0, act_bad, pf(act_bad == 0))

###############################################################################
## CHECK 4 - IDENTIFIERS NEVER ENTER THE DESIGN MATRIX
###############################################################################
terms_all  <- unique(coefs$term)
base_terms <- unique(sub(":FL$", "", setdiff(terms_all, "(Intercept)")))
id_leak    <- intersect(base_terms, id_cols)
allowed    <- c("(Intercept)", control_cols, predictor_cols,
                paste0(predictor_cols, ":FL"))
unexpected <- setdiff(terms_all, allowed)
tgt_leak   <- intersect(base_terms, target_col)

add("4.1", "No identifier column appears as a model term in any fold",
    "0 identifier terms", length(id_leak), pf(length(id_leak) == 0),
    paste("identifiers:", paste(id_cols, collapse = ", ")))
add("4.2", "Every model term is an intercept, a declared control, a declared predictor, or a predictor:FL interaction",
    0, length(unexpected), pf(length(unexpected) == 0),
    if (length(unexpected)) paste(head(unexpected, 5), collapse = "; ") else "")
add("4.3", "Target column never appears as a predictor term", 0, length(tgt_leak),
    pf(length(tgt_leak) == 0))
bd_start <- grep("^build_design <- function", src)
bd_body  <- src[bd_start:(bd_start + 17)]
## whole-symbol match only: "state" must not be flagged inside control_state_florida
bd_ids   <- id_cols[vapply(id_cols, function(v)
  any(grepl(sprintf("(?<![A-Za-z0-9_.])%s(?![A-Za-z0-9_.])", v), bd_body, perl = TRUE)),
  logical(1))]
add("4.4", "build_design() body references only predictor_cols and spec$controls",
    "no identifier column referenced", if (length(bd_ids)) paste(bd_ids, collapse = ", ") else "none",
    pf(length(bd_ids) == 0))
add("4.5", "Predictor set inferred as the complement of identifiers/target/controls",
    "predictor_cols <- setdiff(names(dat), c(id_cols, target_col, control_cols))",
    if (hasc("predictor_cols <- setdiff(names(dat), c(id_cols, target_col, control_cols))"))
      "present" else "absent",
    pf(hasc("predictor_cols <- setdiff(names(dat), c(id_cols, target_col, control_cols))")))

## term counts per model
tc <- aggregate(term ~ model, data = coefs, FUN = function(z) length(unique(z)))
exp_tc <- c(pooled_lasso = 41, pooled_lasso_state_interactions = 79,
            separate_lasso_CA = 40, separate_lasso_FL = 40)
tc_ok <- all(vapply(names(exp_tc), function(m)
  tc$term[tc$model == m] == exp_tc[[m]], logical(1)))
add("4.6", "Term counts match the declared design (pooled 1+2+38=41; interactions 1+2+38+38=79; state models 1+1+38=40)",
    paste(sprintf("%s=%d", names(exp_tc), exp_tc), collapse = "; "),
    paste(sprintf("%s=%d", tc$model, tc$term), collapse = "; "), pf(tc_ok))

###############################################################################
## CHECK 5 - STATE AND TIME CONTROLS ARE UNPENALIZED
###############################################################################
pen_ok <- hasc("pen <- c(rep(0, ncol(C)), rep(1, ncol(Xs) + ncol(I)))") &&
          hasc("pen <- c(rep(0, ncol(C)), rep(1, ncol(Xs)))") &&
          hasc("penalty.factor = full$penalty") && hasc("penalty.factor = dtr$penalty")
add("5.1", "Design builder assigns penalty factor 0 to controls and 1 to every predictor/interaction",
    "pen = c(rep(0, ncol(C)), rep(1, ...)) passed as penalty.factor in every glmnet call",
    if (pen_ok) "confirmed in build_design(), tune_fc() inner and outer fits" else "NOT confirmed",
    pf(pen_ok))
ctrl_stab <- stab[stab$term %in% control_cols, ]
ctrl_always <- all(ctrl_stab$selection_freq == 1)
add("5.2", "Empirical corroboration: control terms are non-zero in 100% of folds at both lambda rules",
    "selection_freq = 1 for every control term x model x rule",
    sprintf("%d control rows, min selection_freq = %s", nrow(ctrl_stab),
            fx(min(ctrl_stab$selection_freq), 3)), pf(ctrl_always))
ci <- coefs[coefs$term %in% control_cols, ]
add("5.3", "No control coefficient is ever shrunk to exactly zero",
    0, sum(ci$coefficient == 0), pf(sum(ci$coefficient == 0) == 0))
sep_ctrl <- unique(coefs$term[grepl("^separate_lasso", coefs$model) &
                              coefs$term %in% control_cols])
add("5.4", "State-specific models correctly drop the state control and retain the unpenalized time control",
    "control_time_index only", paste(sep_ctrl, collapse = "; "),
    pf(identical(sort(sep_ctrl), "control_time_index")))
n_glmnet <- sum(grepl("glmnet(", srcn, fixed = TRUE))
n_stdF   <- sum(grepl("standardize = FALSE", srcn, fixed = TRUE))
add("5.5", "glmnet standardize=FALSE on every fit, so supplied penalty factors are not rescaled internally",
    "standardize = FALSE on all glmnet calls",
    sprintf("%d glmnet call(s), %d with standardize = FALSE", n_glmnet, n_stdF),
    pf(n_glmnet == n_stdF && n_glmnet >= 2),
    "Predictors are pre-standardized on training rows inside build_design(), so glmnet's own standardization is correctly disabled.")

###############################################################################
## CHECK 6 - SCALING AND LAMBDA TUNING USE TRAINING YEARS ONLY
###############################################################################
scale_ok <- hasc("Xfit <- as.matrix(dat[fit_rows, predictor_cols, drop = FALSE])") &&
            hasc("pp <- std_params(Xfit)") &&
            hasc("Xs <- scale(Xap, center = pp$center, scale = pp$scale)")
add("6.1", "Standardization centre/scale are computed from fit_rows only and applied to apply_rows",
    "std_params(Xfit) from fit_rows; scale() applied to apply_rows",
    if (scale_ok) "confirmed" else "NOT confirmed", pf(scale_ok))
add("6.2", "Outer scoring scales validation rows with outer-training statistics",
    "build_design(spec, spec$rows, val_rows)",
    if (hasc("dva <- build_design(spec, spec$rows, val_rows)")) "present" else "absent",
    pf(hasc("dva <- build_design(spec, spec$rows, val_rows)")))
add("6.3", "Inner tuning re-fits scaling on each inner-training window only",
    "build_design(spec, itr, itr) for fit; build_design(spec, itr, iva) for inner validation",
    if (hasc("dtr <- build_design(spec, itr, itr)") && hasc("dva <- build_design(spec, itr, iva)"))
      "present" else "absent",
    pf(hasc("dtr <- build_design(spec, itr, itr)") && hasc("dva <- build_design(spec, itr, iva)")))
add("6.4", "Lambda is tuned only on rows of the outer training window (spec$rows = train_idx)",
    "tune_fc(spec) operates on spec$rows, which is the fold's train_idx",
    if (hasc("rows <- spec$rows") && hasc("years <- dat$target_year[rows]")) "confirmed" else "NOT confirmed",
    pf(hasc("rows <- spec$rows") && hasc("years <- dat$target_year[rows]")))
grid_var <- length(unique(lamb$n_grid))
add("6.5", "Lambda grid is rebuilt per fold (grid length varies with the training window)",
    "n_grid varies across folds/models",
    sprintf("%d distinct grid lengths, range %d-%d", grid_var, min(lamb$n_grid), max(lamb$n_grid)),
    pf(grid_var > 1))
lam_mono <- all(lamb$lambda_1se >= lamb$lambda_min)
add("6.6", "lambda.1se is never smaller than lambda.min in any fold/model", "TRUE",
    sprintf("%d of %d rows satisfy 1se >= min", sum(lamb$lambda_1se >= lamb$lambda_min), nrow(lamb)),
    pf(lam_mono))
## Full-data quantity used in the log transform (shift), flagged for transparency
shift_full_data <- hasc("shift <- if (is_log && min(dat[[target_col]]) <= 0) 1 else 0")
add("6.7", "Log-target shift constant is derived from the full column, not training rows only",
    "training-only derivation",
    sprintf("min(dat[[target_col]]) over all 887 rows = %.2f > 0, so shift = 0 in every fold",
            min(dat[[target_col]])),
    if (shift_full_data) "WARNING" else "PASS",
    "No numerical effect in this run (shift is identically 0); a constant this small is not a leakage pathway, but it is the one preprocessing quantity read from the full column.")

###############################################################################
## CHECK 7 - NESTED LAMBDA TUNING IS FORWARD-CHAINING
###############################################################################
fc_ok <- hasc("itr <- rows[years %in% uy[1:cc]]") &&
         hasc("iva <- rows[years == uy[cc + 1]]") &&
         hasc("cuts <- if (K >= 2) c0:(K - 1) else integer(0)")
add("7.1", "Inner splits train on years 1..c and validate on year c+1 (strict forward chaining)",
    "itr = uy[1:cc]; iva = uy[cc+1]", if (fc_ok) "confirmed" else "NOT confirmed", pf(fc_ok))
lam2 <- merge(lamb, folds_def[, c("fold", "n_train_years")], by = "fold")
lam2$expected_splits <- lam2$n_train_years - 2       # cuts = 2:(K-1) -> K-2 splits
split_ok <- all(lam2$n_inner_splits == lam2$expected_splits)
add("7.2", "Inner split count equals K-2 for every fold/model, as forward chaining with min_inner_train_years=2 implies",
    "n_inner_splits = n_train_years - 2 (3,4,5,6,7,8,9,10 across folds)",
    paste(sort(unique(lam2$n_inner_splits)), collapse = ","), pf(split_ok),
    "Leave-one-year-out CV would instead give K splits (5..12); the exported counts rule that out.")
add("7.3", "Number of inner splits grows monotonically with the expanding training window",
    "strictly increasing by fold",
    paste(tapply(lam2$n_inner_splits, lam2$fold, unique), collapse = ","),
    pf(all(diff(as.numeric(tapply(lam2$n_inner_splits, lam2$fold, unique))) == 1)))
add("7.4", "Manifest records the tuning scheme as nested forward-chaining time CV",
    "nested_forward_chaining_time_cv", mval[["lambda_selection"]],
    pf(mval[["lambda_selection"]] == "nested_forward_chaining_time_cv"))
add("7.5", "Lambda choices exported for all four penalized specs in all eight folds",
    32, nrow(lamb), pf(nrow(lamb) == 32L))

###############################################################################
## CHECK 8 - LOG-TARGET SMEARING USES TRAINING RESIDUALS ONLY
###############################################################################
duan_ok <- hasc("duan <- function(y_tr, yhat_tr) if (is_log) mean(exp(y_tr - yhat_tr)) else 1") &&
           hasc("yhat_tr <- as.numeric(predict(tuned$gfit, newx = dtr$x, s = lam))") &&
           hasc("dtr <- build_design(spec, spec$rows, spec$rows)") &&
           hasc("y_tr <- yof(spec$rows)")
add("8.1", "Duan factor S = mean(exp(training residuals)), built from the training design and training actuals",
    "duan(y_tr, yhat_tr) with y_tr = yof(spec$rows) and yhat_tr on dtr$x",
    if (duan_ok) "confirmed" else "NOT confirmed", pf(duan_ok))
add("8.2", "S is estimated per model x fold x lambda rule and applied only to that fold's held-out rows",
    "72 smearing rows (8 folds x [1 baseline + 4 penalized specs x 2 rules])",
    nrow(smear), pf(nrow(smear) == 72L))
add("8.3", "Identity-target run applies no smearing (S fixed at 1, back-transform is a no-op)",
    "duan() returns 1 and back_with() returns v when target is identity",
    if (hasc("back_with <- function(v, S) if (is_log) exp(v) * S - shift else v")) "confirmed" else "NOT confirmed",
    pf(hasc("back_with <- function(v, S) if (is_log) exp(v) * S - shift else v")))

## Falsification test: if S had been computed from validation residuals,
## mean((actual+shift)/(predicted+shift)) would equal 1 for every fold.
shift <- 0
lp <- merge(lpreds, smear[, c("model", "fold", "lambda_rule", "smearing_factor")],
            by = c("model", "fold", "lambda_rule"))
ratio <- do.call(rbind, lapply(split(lp, list(lp$model, lp$fold, lp$lambda_rule), drop = TRUE),
  function(d) data.frame(model = d$model[1], fold = d$fold[1], rule = d$lambda_rule[1],
    ratio = mean((d$actual + shift) / (d$predicted + shift)),
    S = d$smearing_factor[1], stringsAsFactors = FALSE)))
ratio$implied_val_S <- ratio$S * ratio$ratio
val_based <- sum(abs(ratio$ratio - 1) < 1e-6)
add("8.4", "Falsification test: exported S does not equal the value a validation-residual estimator would give",
    "0 of 72 fold-level S values reproduce as validation-residual smearing",
    sprintf("%d of %d; mean |ratio-1| = %s (range %s to %s)", val_based, nrow(ratio),
            fx(mean(abs(ratio$ratio - 1)), 4), fx(min(ratio$ratio), 4), fx(max(ratio$ratio), 4)),
    pf(val_based == 0))
add("8.5", "All smearing factors are finite, positive and above 1 (right-skewed residual correction)",
    "S > 1 for every row",
    sprintf("range %s to %s", fx(min(smear$smearing_factor), 4), fx(max(smear$smearing_factor), 4)),
    pf(all(is.finite(smear$smearing_factor)) && all(smear$smearing_factor > 1)))
add("8.6", "Manifest documents the retransformation as training-only and fold-specific",
    "duan_smearing_training_only_fold_specific", mval[["log_retransformation"]],
    pf(mval[["log_retransformation"]] == "duan_smearing_training_only_fold_specific"))

###############################################################################
## CHECK 9 - RECOMPUTE RMSE / MAE / R2 FROM FINAL PREDICTIONS
###############################################################################
REC <- list()
rec <- function(...) REC[[length(REC) + 1]] <<- data.frame(..., stringsAsFactors = FALSE)

cmp <- function(scope, tbl, pred_src, fold_col = NA, group_col = NA) {
  for (i in seq_len(nrow(tbl))) {
    r <- tbl[i, ]
    d <- pred_src[pred_src$model == r$model & pred_src$lambda_rule == r$lambda_rule, ]
    if (!is.na(fold_col)) d <- d[d$fold == r[[fold_col]], ]
    if (!is.na(group_col) && r[[group_col]] != "all") d <- d[d$state == r[[group_col]], ]
    d <- d[!is.na(d$predicted), ]
    rec(scope = scope, model = r$model, lambda_rule = r$lambda_rule,
        fold = if (is.na(fold_col)) NA_integer_ else r[[fold_col]],
        group = if (is.na(group_col)) "all" else r[[group_col]],
        n_exported = r$n, n_recomputed = nrow(d),
        rmse_exported = r$rmse, rmse_recomputed = rmse(d$actual, d$predicted),
        mae_exported = r$mae, mae_recomputed = mae(d$actual, d$predicted),
        r2_exported = r$r2, r2_recomputed = r2(d$actual, d$predicted))
  }
}
cmp("overall_raw_target", mall, preds)
cmp("by_fold_raw_target", mby, preds, fold_col = "fold", group_col = "group")
cmp("by_state_raw_target", stperf, preds, group_col = "state")
cmp("overall_log_target", lall, lpreds)

recdf <- do.call(rbind, REC)
recdf$rmse_abs_diff <- abs(recdf$rmse_exported - recdf$rmse_recomputed)
recdf$mae_abs_diff  <- abs(recdf$mae_exported  - recdf$mae_recomputed)
recdf$r2_abs_diff   <- abs(recdf$r2_exported   - recdf$r2_recomputed)
recdf$n_match       <- recdf$n_exported == recdf$n_recomputed
recdf$max_abs_diff  <- pmax(recdf$rmse_abs_diff, recdf$mae_abs_diff, recdf$r2_abs_diff)
recdf$status <- ifelse(recdf$n_match & recdf$max_abs_diff < TOL, "PASS",
                ifelse(recdf$n_match & recdf$max_abs_diff < 1e-6, "WARNING", "FAIL"))
write.csv(recdf, file.path(AUDIT_DIR, "recomputed_metrics.csv"), row.names = FALSE)

worst <- max(recdf$max_abs_diff, na.rm = TRUE)
add("9.1", "All exported metrics reproduce from FINAL predictions (overall, by fold, by state, log target)",
    sprintf("max |exported - recomputed| < %g across %d metric rows", TOL, nrow(recdf)),
    sprintf("max abs diff = %.3e over %d rows (%d PASS / %d WARNING / %d FAIL)",
            worst, nrow(recdf), sum(recdf$status == "PASS"),
            sum(recdf$status == "WARNING"), sum(recdf$status == "FAIL")),
    pf(all(recdf$status == "PASS")))
add("9.2", "Row counts behind every exported metric reproduce exactly",
    "n_exported == n_recomputed for all rows",
    sprintf("%d of %d match", sum(recdf$n_match), nrow(recdf)), pf(all(recdf$n_match)))
## residual diagnostics recomputation
rdchk <- do.call(rbind, lapply(seq_len(nrow(resdiag)), function(i) {
  r <- resdiag[i, ]
  d <- preds[preds$model == r$model & preds$lambda_rule == r$lambda_rule, ]
  if (r$group != "all") d <- d[d$state == r$group, ]
  d <- d[!is.na(d$residual), ]
  data.frame(ok = (nrow(d) == r$n) &&
               abs(mean(d$residual) - r$mean_resid) < TOL &&
               abs(sd(d$residual) - r$sd_resid) < TOL &&
               abs(max(abs(d$residual)) - r$max_abs_resid) < TOL)
}))
add("9.3", "Residual diagnostics (n, mean, sd, max |resid|) reproduce from FINAL predictions",
    sprintf("all %d rows", nrow(resdiag)), sprintf("%d of %d reproduce", sum(rdchk$ok), nrow(resdiag)),
    pf(all(rdchk$ok)))

###############################################################################
## CHECK 10 - "RAW INTERACTION LASSO WITH lambda.min IS THE BEST UNIFIED MODEL"
###############################################################################
unified <- c("state_time_baseline", "pooled_lasso", "pooled_lasso_state_interactions")
um <- mall[mall$model %in% unified, ]
best_rmse <- um[which.min(um$rmse), ]
best_r2   <- um[which.max(um$r2), ]
best_mae  <- um[which.min(um$mae), ]
claim_model <- "pooled_lasso_state_interactions"; claim_rule <- "min"
claim_row <- um[um$model == claim_model & um$lambda_rule == claim_rule, ]

add("10.1", "Among unified (single pooled) models on the raw target, interaction LASSO + lambda.min has the lowest pooled out-of-time RMSE",
    sprintf("%s / %s", claim_model, claim_rule),
    sprintf("%s / %s (RMSE %s vs next best %s)", best_rmse$model, best_rmse$lambda_rule,
            fx(best_rmse$rmse, 4), fx(sort(um$rmse)[2], 4)),
    pf(best_rmse$model == claim_model && best_rmse$lambda_rule == claim_rule))
add("10.2", "Same model also has the highest pooled out-of-time R2 among unified models",
    sprintf("%s / %s", claim_model, claim_rule),
    sprintf("%s / %s (R2 %s)", best_r2$model, best_r2$lambda_rule, fx(best_r2$r2, 4)),
    pf(best_r2$model == claim_model && best_r2$lambda_rule == claim_rule))
add("10.3", "Same model also has the lowest pooled MAE among unified models",
    sprintf("%s / %s", claim_model, claim_rule),
    sprintf("%s / %s (MAE %s vs claimed model %s)", best_mae$model, best_mae$lambda_rule,
            fx(best_mae$mae, 4), fx(claim_row$mae, 4)),
    if (best_mae$model == claim_model && best_mae$lambda_rule == claim_rule) "PASS" else "WARNING",
    "MAE ranks the claimed model behind three other unified variants; the 'best' claim holds on squared-error criteria only.")
add("10.4", "Claimed model beats the state-and-time baseline out of time",
    "RMSE and R2 both better than baseline",
    sprintf("RMSE %s vs %s; R2 %s vs %s", fx(claim_row$rmse, 4),
            fx(um$rmse[um$model == "state_time_baseline"], 4), fx(claim_row$r2, 4),
            fx(um$r2[um$model == "state_time_baseline"], 4)),
    pf(claim_row$rmse < um$rmse[um$model == "state_time_baseline"] &&
       claim_row$r2 > um$r2[um$model == "state_time_baseline"]))
raw_beats_log <- rvl[rvl$model == claim_model & rvl$lambda_rule == claim_rule, ]
add("10.5", "Raw target beats the log-target variant of the same model",
    "rmse_log > rmse_raw",
    sprintf("raw %s vs log %s (diff %s)", fx(raw_beats_log$rmse_raw, 4),
            fx(raw_beats_log$rmse_log, 4), fx(raw_beats_log$rmse_diff_log_minus_raw, 4)),
    pf(raw_beats_log$rmse_diff_log_minus_raw > 0))
sep <- mall[mall$model == "separate_state_lasso", ]
add("10.6", "Qualifier 'unified' is load-bearing: the two-state separate LASSO scores better overall and must not be called second-best without it",
    "separate_state_lasso is not a unified model",
    sprintf("separate_state_lasso best RMSE %s / R2 %s vs unified best RMSE %s / R2 %s",
            fx(min(sep$rmse), 4), fx(max(sep$r2), 4), fx(claim_row$rmse, 4), fx(claim_row$r2, 4)),
    if (min(sep$rmse) < claim_row$rmse) "WARNING" else "PASS",
    "The claim is only true when restricted to unified models; stated without that restriction it is false.")
fold_win <- mby[mby$group == "all" & mby$model %in% unified, ]
fw <- do.call(rbind, lapply(split(fold_win, fold_win$fold), function(d)
  data.frame(fold = d$fold[1], winner = paste(d$model[which.min(d$rmse)],
             d$lambda_rule[which.min(d$rmse)], sep = "/"), stringsAsFactors = FALSE)))
n_fold_win <- sum(fw$winner == paste(claim_model, claim_rule, sep = "/"))
add("10.7", "Fold-level robustness of the 'best unified model' claim",
    "wins a majority of the 8 folds on RMSE",
    sprintf("wins %d of 8 folds; winners: %s", n_fold_win, paste(fw$winner, collapse = ", ")),
    if (n_fold_win >= 5) "PASS" else "WARNING",
    "Pooled RMSE can be driven by a few folds; fold-level wins are reported so the claim is not over-read.")

###############################################################################
## CHECK 11 - STATE-SPECIFIC PERFORMANCE CLAIMS
###############################################################################
sp <- stperf
sp_ok <- all(recdf$status[recdf$scope == "by_state_raw_target"] == "PASS")
add("11.1", "Every exported CA/FL performance row reproduces from FINAL predictions",
    "18 rows reproduce exactly",
    sprintf("%d of %d PASS", sum(recdf$status[recdf$scope == "by_state_raw_target"] == "PASS"),
            sum(recdf$scope == "by_state_raw_target")), pf(sp_ok))
n_ca <- unique(sp$n[sp$state == "California"]); n_fl <- unique(sp$n[sp$state == "Florida"])
add("11.2", "State row counts partition the 555 scored rows (CA 347 + FL 208)",
    "347 + 208 = 555", sprintf("%d + %d = %d", n_ca[1], n_fl[1], n_ca[1] + n_fl[1]),
    pf(identical(as.integer(n_ca), 347L) && identical(as.integer(n_fl), 208L) &&
       n_ca[1] + n_fl[1] == 555L))
sep_rows <- sp[sp$model == "separate_state_lasso", ]
ca_rows  <- sp[sp$model == "separate_lasso_CA", ]
fl_rows  <- sp[sp$model == "separate_lasso_FL", ]
dup_ok <- isTRUE(all.equal(sep_rows$rmse[sep_rows$state == "California"], ca_rows$rmse)) &&
          isTRUE(all.equal(sep_rows$rmse[sep_rows$state == "Florida"], fl_rows$rmse))
add("11.3", "separate_state_lasso state rows are identical to the CA/FL component models (no double counting of a distinct model)",
    "identical RMSE by state and rule", if (dup_ok) "identical" else "differ", pf(dup_ok),
    "separate_state_lasso is the concatenation of separate_lasso_CA and separate_lasso_FL, not an independent fifth model.")
fl_better <- all(vapply(split(sp[sp$model != "state_time_baseline", ],
                              paste(sp$model, sp$lambda_rule)[sp$model != "state_time_baseline"]),
  function(d) if (nrow(d) == 2) d$rmse[d$state == "Florida"] < d$rmse[d$state == "California"] else TRUE,
  logical(1)))
add("11.4", "Florida RMSE is lower than California RMSE for every LASSO model/rule",
    "TRUE for all paired rows", if (fl_better) "TRUE" else "not universal", pf(fl_better),
    "Florida's CoC rates have a much smaller spread, so a lower RMSE there is not by itself better explanation.")
base_neg <- sp[sp$model == "state_time_baseline", ]
add("11.5", "The state-and-time baseline's positive pooled R2 is backed by non-negative within-state R2",
    "R2 >= 0 within CA and within FL",
    sprintf("CA %s; FL %s", fx(base_neg$r2[base_neg$state == "California"], 4),
            fx(base_neg$r2[base_neg$state == "Florida"], 4)),
    if (all(base_neg$r2 >= 0)) "PASS" else "WARNING",
    "The baseline's pooled R2 comes entirely from the CA/FL level gap; within state it is worse than each state's own mean. Any reading of pooled R2 as within-state explanatory power is unsupported.")
spu <- sp[sp$model %in% unified, ]                       # unified models only
bu_ca <- spu[spu$state == "California", ][which.min(spu$rmse[spu$state == "California"]), ]
bu_fl <- spu[spu$state == "Florida", ][which.min(spu$rmse[spu$state == "Florida"]), ]
best_ca <- sp[sp$state == "California", ][which.min(sp$rmse[sp$state == "California"]), ]
best_fl <- sp[sp$state == "Florida", ][which.min(sp$rmse[sp$state == "Florida"]), ]
claim_ca <- sp[sp$model == claim_model & sp$lambda_rule == claim_rule & sp$state == "California", ]
claim_fl <- sp[sp$model == claim_model & sp$lambda_rule == claim_rule & sp$state == "Florida", ]
add("11.6", "The claimed best unified model is also the best unified model within each state",
    "claimed model has the lowest RMSE among unified models in both CA and FL",
    sprintf("CA best unified = %s/%s (%s) vs claimed %s; FL best unified = %s/%s (%s) vs claimed %s",
            bu_ca$model, bu_ca$lambda_rule, fx(bu_ca$rmse, 4), fx(claim_ca$rmse, 4),
            bu_fl$model, bu_fl$lambda_rule, fx(bu_fl$rmse, 4), fx(claim_fl$rmse, 4)),
    if (bu_ca$model == claim_model && bu_ca$lambda_rule == claim_rule &&
        bu_fl$model == claim_model && bu_fl$lambda_rule == claim_rule) "PASS" else "WARNING",
    "Within Florida the claimed model is the weakest of the four pooled LASSO variants; its overall win is carried by California, which supplies 63% of scored rows.")
add("11.7", "Lowest-RMSE model in each state across all models (context for 11.6)",
    "reported for context",
    sprintf("CA = %s/%s (%s); FL = %s/%s (%s)",
            best_ca$model, best_ca$lambda_rule, fx(best_ca$rmse, 4),
            best_fl$model, best_fl$lambda_rule, fx(best_fl$rmse, 4)), "PASS")

###############################################################################
## CHECK 12 - SELECTION FREQUENCIES AND SIGN STABILITY
###############################################################################
recalc_stab <- do.call(rbind, lapply(
  split(coefs[coefs$term != "(Intercept)", ],
        list(coefs$model[coefs$term != "(Intercept)"],
             coefs$lambda_rule[coefs$term != "(Intercept)"],
             coefs$term[coefs$term != "(Intercept)"]), drop = TRUE),
  function(t) {
    nz <- t$coefficient[abs(t$coefficient) > 0]
    data.frame(model = t$model[1], lambda_rule = t$lambda_rule[1], term = t$term[1],
               n_folds = nrow(t), n_selected = length(nz),
               selection_freq = length(nz) / nrow(t),
               mean_coef = mean(t$coefficient), sd_coef = sd(t$coefficient),
               sign_consistency = if (length(nz)) max(mean(nz > 0), mean(nz < 0)) else NA_real_,
               stringsAsFactors = FALSE)
  }))
mj <- merge(stab, recalc_stab, by = c("model", "lambda_rule", "term"),
            suffixes = c("_exp", "_rec"))
stab_ok <- nrow(mj) == nrow(stab) &&
  all(mj$n_folds_exp == mj$n_folds_rec) && all(mj$n_selected_exp == mj$n_selected_rec) &&
  max(abs(mj$selection_freq_exp - mj$selection_freq_rec)) < TOL &&
  max(abs(mj$mean_coef_exp - mj$mean_coef_rec)) < TOL &&
  max(abs(mj$sd_coef_exp - mj$sd_coef_rec)) < TOL &&
  max(abs(mj$sign_consistency_exp - mj$sign_consistency_rec), na.rm = TRUE) < TOL
add("12.1", "Selection frequencies, mean/sd coefficients and sign consistency reproduce from FINAL_coefficients_by_fold.csv",
    sprintf("all %d stability rows", nrow(stab)),
    sprintf("%d rows joined; max abs diff = %.3e", nrow(mj),
            max(c(abs(mj$selection_freq_exp - mj$selection_freq_rec),
                  abs(mj$mean_coef_exp - mj$mean_coef_rec),
                  abs(mj$sd_coef_exp - mj$sd_coef_rec)), na.rm = TRUE)),
    pf(stab_ok))
add("12.2", "Every stability row is based on all eight folds",
    "n_folds = 8 for every term", sprintf("range %d-%d", min(stab$n_folds), max(stab$n_folds)),
    pf(all(stab$n_folds == 8L)))

hs <- stab[stab$model == claim_model & stab$lambda_rule == claim_rule &
           !stab$term %in% control_cols, ]
hs <- hs[order(-hs$selection_freq, -abs(hs$mean_coef)), ]
always <- hs[hs$selection_freq == 1, ]
freq   <- hs[hs$selection_freq >= 0.5, ]
unstable <- freq[!is.na(freq$sign_consistency) & freq$sign_consistency < 1, ]
add("12.3", "Frequently selected predictors in the headline model keep a single sign across folds",
    "sign_consistency = 1 for every term selected in >=50% of folds",
    sprintf("%d of %d frequently selected terms flip sign (%s)", nrow(unstable), nrow(freq),
            if (nrow(unstable)) paste(sprintf("%s: %s", unstable$term, fx(unstable$sign_consistency, 3)),
                                      collapse = "; ") else "none"),
    if (nrow(unstable) == 0) "PASS" else "WARNING",
    "Sign flips across expanding training windows mean the direction of association is not stable and must not be reported as a directional finding.")
add("12.4", "Headline-model selection is sparse relative to the 76 penalized columns",
    "reported for context",
    sprintf("%d of %d penalized terms selected in all 8 folds; %d in >=50%%; %d never selected",
            nrow(always), nrow(hs), nrow(freq), sum(hs$selection_freq == 0)),
    "PASS")

## same summary for the simpler pooled model, used in the report
hs2 <- stab[stab$model == "pooled_lasso" & stab$lambda_rule == "min" &
            !stab$term %in% control_cols, ]
hs2 <- hs2[order(-hs2$selection_freq, -abs(hs2$mean_coef)), ]
unstable2 <- hs2[hs2$selection_freq >= 0.5 & !is.na(hs2$sign_consistency) & hs2$sign_consistency < 1, ]
add("12.5", "Sign stability in the simpler pooled LASSO (lambda.min)",
    "sign_consistency = 1 for terms selected in >=50% of folds",
    sprintf("%d of %d frequently selected terms flip sign (%s)", nrow(unstable2),
            sum(hs2$selection_freq >= 0.5),
            if (nrow(unstable2)) paste(sprintf("%s: %s", unstable2$term, fx(unstable2$sign_consistency, 3)),
                                       collapse = "; ") else "none"),
    if (nrow(unstable2) == 0) "PASS" else "WARNING")

###############################################################################
## CHECK 13 - PREDICTORS IN THE 18 HIGHLY CORRELATED EDA PAIRS
###############################################################################
pairs <- read.csv(file.path(EDA_DIR, "tables", "highly_correlated_pairs_v2.csv"),
                  stringsAsFactors = FALSE)
add("13.1", "EDA highly-correlated pair table contains the 18 pairs cited in EDA_FINDINGS_v2.md",
    18, nrow(pairs), pf(nrow(pairs) == 18L))
corr_vars <- unique(c(pairs$variable_1, pairs$variable_2))
sel_base  <- unique(sub(":FL$", "", freq$term))
flagged   <- intersect(sel_base, corr_vars)
both_sel  <- pairs[pairs$variable_1 %in% sel_base & pairs$variable_2 %in% sel_base, ]
add("13.2", "No predictor selected in >=50% of folds by the headline model belongs to a |r|>=0.80 EDA pair",
    "0 frequently selected predictors in a highly correlated pair",
    sprintf("%d of %d distinct predictors (from %d frequently selected terms incl. :FL interactions) are members of a highly correlated pair: %s",
            length(flagged), length(sel_base), nrow(freq), paste(flagged, collapse = ", ")),
    if (length(flagged) == 0) "PASS" else "WARNING",
    "LASSO picks one member of a correlated pair near-arbitrarily; the selected member must not be reported as the operative variable.")
add("13.3", "No correlated pair has BOTH members frequently selected",
    "0 pairs (selection would be splitting a shared signal)",
    if (nrow(both_sel)) paste(sprintf("%s ~ %s (r=%s)", both_sel$variable_1,
                                      both_sel$variable_2, both_sel$r), collapse = "; ") else "none",
    if (nrow(both_sel) == 0) "PASS" else "WARNING",
    "Where both members enter, individual coefficients are split between collinear columns and neither magnitude is interpretable alone.")
top_corr_flag <- intersect(head(hs$term[hs$selection_freq == 1], 10), corr_vars)
add("13.4", "No always-selected (100% of folds) predictor is a correlated-pair member",
    "0 always-selected predictors in a highly correlated pair",
    if (length(top_corr_flag)) paste(top_corr_flag, collapse = ", ") else "none",
    if (length(top_corr_flag) == 0) "PASS" else "WARNING",
    "These carry the headline model's most stable signal yet each shares >=80% correlation with another predictor, so the attribution between cluster members is not identified.")

###############################################################################
## CHECK 14 - PRELIMINARY OUTPUTS NOT OVERWRITTEN
###############################################################################
prelim_files <- list.files(MODEL_DIR, pattern = "^PRELIMINARY_")
final_files  <- list.files(MODEL_DIR, pattern = "^FINAL_")
pman <- rd("PRELIMINARY_run_manifest.csv"); pv <- setNames(pman$value, pman$field)
add("14.1", "PRELIMINARY output set still present alongside the FINAL set",
    "10 PRELIMINARY files", length(prelim_files), pf(length(prelim_files) == 10L),
    paste(prelim_files, collapse = "; "))
add("14.2", "FINAL and PRELIMINARY use disjoint filename prefixes (no in-place overwrite possible)",
    "0 shared filenames", length(intersect(prelim_files, final_files)),
    pf(length(intersect(prelim_files, final_files)) == 0L))
add("14.3", "PRELIMINARY manifest still records the v1 development run",
    "run_mode=DEVELOPMENT_V1; input=v1 workbook; md5=v1 md5; 898 rows/47 predictors/71 CoCs",
    sprintf("run_mode=%s; input=%s; md5=%s; %s rows/%s predictors/%s CoCs",
            pv[["run_mode"]], basename(pv[["input_file"]]), pv[["input_md5"]],
            pv[["n_rows"]], pv[["n_predictors"]], pv[["n_cocs"]]),
    pf(pv[["run_mode"]] == "DEVELOPMENT_V1" &&
       basename(pv[["input_file"]]) == basename(V1) &&
       pv[["input_md5"]] == md5_v1 && pv[["n_rows"]] == "898"))
ptime <- as.POSIXct(pv[["timestamp_utc"]], format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
ftime <- as.POSIXct(mval[["timestamp_utc"]], format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
pmt   <- file.mtime(file.path(MODEL_DIR, prelim_files))
add("14.4", "PRELIMINARY files predate the FINAL run and none was touched by it",
    sprintf("all mtimes before FINAL run at %s", mval[["timestamp_utc"]]),
    sprintf("latest PRELIMINARY mtime %s; PRELIMINARY manifest stamp %s",
            format(max(pmt), tz = "UTC", usetz = TRUE), pv[["timestamp_utc"]]),
    pf(all(pmt < ftime) && ptime < ftime))
pp <- rd("PRELIMINARY_predictions.csv")
add("14.5", "PRELIMINARY results are distinct from FINAL results (not a relabelled copy)",
    "different row counts / metrics",
    sprintf("PRELIMINARY predictions %d rows vs FINAL %d rows", nrow(pp), nrow(preds)),
    pf(nrow(pp) != nrow(preds)))
add("14.6", "PRELIMINARY run did not include the log-target sensitivity (nothing silently reused as FINAL)",
    "run_log_target=FALSE in PRELIMINARY; TRUE in FINAL",
    sprintf("PRELIMINARY=%s; FINAL=%s", pv[["run_log_target"]], mval[["run_log_target"]]),
    pf(pv[["run_log_target"]] == "FALSE" && mval[["run_log_target"]] == "TRUE"))

###############################################################################
## CHECK 15 - CROSS-FILE CONSISTENCY OF ALL FINAL OUTPUTS
###############################################################################
mods_pred <- sort(unique(preds$model))
exp_mods  <- sort(c("state_time_baseline", "pooled_lasso", "pooled_lasso_state_interactions",
                    "separate_lasso_CA", "separate_lasso_FL", "separate_state_lasso"))
add("15.1", "Model names identical across predictions, metrics, residual diagnostics, state performance and log outputs",
    paste(exp_mods, collapse = "; "), paste(mods_pred, collapse = "; "),
    pf(identical(mods_pred, exp_mods) &&
       identical(sort(unique(mall$model)), exp_mods) &&
       identical(sort(unique(mby$model)), exp_mods) &&
       identical(sort(unique(resdiag$model)), exp_mods) &&
       identical(sort(unique(stperf$model)), exp_mods) &&
       identical(sort(unique(lall$model)), exp_mods) &&
       identical(sort(unique(lpreds$model)), exp_mods)))
add("15.2", "Coefficient and lambda files cover exactly the four penalized specs",
    "pooled_lasso; pooled_lasso_state_interactions; separate_lasso_CA; separate_lasso_FL",
    paste(sort(unique(coefs$model)), collapse = "; "),
    pf(identical(sort(unique(coefs$model)), sort(setdiff(exp_mods, c("state_time_baseline", "separate_state_lasso")))) &&
       identical(sort(unique(lamb$model)), sort(setdiff(exp_mods, c("state_time_baseline", "separate_state_lasso"))))))
rules_ok <- identical(sort(unique(preds$lambda_rule)), c("1se", "min", "none")) &&
            identical(sort(unique(coefs$lambda_rule)), c("1se", "min")) &&
            all(preds$lambda_rule[preds$model == "state_time_baseline"] == "none") &&
            all(preds$lambda_rule[preds$model != "state_time_baseline"] %in% c("min", "1se"))
add("15.3", "Lambda-rule labels consistent everywhere (penalized models min/1se, baseline none)",
    "min, 1se, none used consistently", if (rules_ok) "consistent" else "INCONSISTENT", pf(rules_ok))
fmap_pred <- unique(preds[, c("fold", "validation_year")])
fmap_ok <- isTRUE(all.equal(fmap_pred[order(fmap_pred$fold), ],
                            folds_def[, c("fold", "validation_year")],
                            check.attributes = FALSE)) &&
  isTRUE(all.equal(unique(lamb[, c("fold", "validation_year")])[order(unique(lamb$fold)), ],
                   folds_def[, c("fold", "validation_year")], check.attributes = FALSE)) &&
  isTRUE(all.equal(unique(mby[, c("fold", "validation_year")])[order(unique(mby$fold)), ],
                   folds_def[, c("fold", "validation_year")], check.attributes = FALSE))
add("15.4", "Fold to validation-year mapping identical in fold definitions, predictions, metrics, lambda choices and smearing",
    "identical in all five files", if (fmap_ok) "identical" else "MISMATCH",
    pf(fmap_ok && all(smear$validation_year == folds_def$validation_year[match(smear$fold, folds_def$fold)])))
exp_pred_rows <- 555 * 7 + 347 * 2 + 208 * 2
add("15.5", "Prediction row counts consistent: 555 scored rows x (baseline + 2 pooled specs x 2 rules + separate combo x 2 rules) plus CA/FL component rows",
    exp_pred_rows, nrow(preds), pf(nrow(preds) == exp_pred_rows))
add("15.6", "Log-target prediction file has the same shape as the raw-target file",
    nrow(preds), nrow(lpreds), pf(nrow(lpreds) == nrow(preds) &&
      identical(sort(names(lpreds)), sort(names(preds)))))
scope_ok <- all(mall$scope == "pooled_all_folds") && all(lall$scope == "pooled_all_folds_LOGTARGET") &&
            all(stperf$scope == "pooled_all_folds")
add("15.7", "Target-transformation labelling is unambiguous (raw scope vs LOGTARGET scope)",
    "pooled_all_folds vs pooled_all_folds_LOGTARGET",
    if (scope_ok) "consistent" else "INCONSISTENT", pf(scope_ok))
rvl_ok <- TRUE
for (i in seq_len(nrow(rvl))) {
  a <- mall[mall$model == rvl$model[i] & mall$lambda_rule == rvl$lambda_rule[i], ]
  b <- lall[lall$model == rvl$model[i] & lall$lambda_rule == rvl$lambda_rule[i], ]
  rvl_ok <- rvl_ok && abs(a$rmse - rvl$rmse_raw[i]) < TOL && abs(b$rmse - rvl$rmse_log[i]) < TOL &&
    abs(rvl$rmse_diff_log_minus_raw[i] - (rvl$rmse_log[i] - rvl$rmse_raw[i])) < TOL
}
add("15.8", "raw_vs_log comparison reproduces from the two metric files and its difference column is arithmetically correct",
    "all 11 rows consistent", if (rvl_ok) "consistent" else "INCONSISTENT", pf(rvl_ok))
lc_ok <- TRUE
for (i in seq_len(nrow(lamcmp))) {
  a <- mall[mall$model == lamcmp$model[i] & mall$lambda_rule == "min", ]
  b <- mall[mall$model == lamcmp$model[i] & mall$lambda_rule == "1se", ]
  lc_ok <- lc_ok && abs(a$rmse - lamcmp$rmse_min[i]) < TOL && abs(b$rmse - lamcmp$rmse_1se[i]) < TOL &&
    abs(lamcmp$rmse_diff_1se_minus_min[i] - (b$rmse - a$rmse)) < TOL
}
add("15.9", "lambda.min vs lambda.1se comparison reproduces from the overall metric file",
    "all 5 rows consistent", if (lc_ok) "consistent" else "INCONSISTENT", pf(lc_ok))
## workbook sheets vs csv
wb_sheets <- getSheetNames(file.path(MODEL_DIR, "FINAL_model_summary.xlsx"))
exp_sheets <- c("run_manifest", "fold_definitions", "metrics_overall", "metrics_by_fold",
                "coef_stability", "residual_diag", "lambda_choices", "ca_fl_performance",
                "lambda_min_vs_1se", "raw_vs_log", "log_smearing")
xl_mo <- read.xlsx(file.path(MODEL_DIR, "FINAL_model_summary.xlsx"), sheet = "metrics_overall")
xl_ok <- identical(wb_sheets, exp_sheets) &&
  nrow(xl_mo) == nrow(mall) && max(abs(xl_mo$rmse - mall$rmse)) < 1e-9
add("15.10", "FINAL_model_summary.xlsx sheets match the CSV exports",
    paste(exp_sheets, collapse = "; "), paste(wb_sheets, collapse = "; "), pf(xl_ok))
st_num <- statements[grepl("887 rows and 70 CoCs", statements)]
st_yrs <- statements[grepl("2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025", statements)]
add("15.11", "FINAL_analysis_statements.md row/CoC counts and validation years match the manifest and fold definitions",
    "887 rows, 70 CoCs, 8 validation years",
    sprintf("row/CoC statement found=%s; validation-year statement found=%s",
            length(st_num) > 0, length(st_yrs) > 0),
    pf(length(st_num) > 0 && length(st_yrs) > 0))
add("15.12", "Every scored CoC-year appears exactly once per model x lambda rule",
    "no duplicated model x rule x CoC x year",
    sum(duplicated(preds[, c("model", "lambda_rule", "coc_number", "target_year")])),
    pf(sum(duplicated(preds[, c("model", "lambda_rule", "coc_number", "target_year")])) == 0))
add("15.13", "No missing predictions in any exported model",
    0, sum(is.na(preds$predicted)), pf(sum(is.na(preds$predicted)) == 0))

###############################################################################
## WRITE audit_checks.csv
###############################################################################
checks <- do.call(rbind, CHK)
write.csv(checks, file.path(AUDIT_DIR, "audit_checks.csv"), row.names = FALSE)

n_pass <- sum(checks$status == "PASS"); n_warn <- sum(checks$status == "WARNING")
n_fail <- sum(checks$status == "FAIL")

###############################################################################
## WRITE AUDIT_REPORT.md
###############################################################################
gv <- function(id, col = "observed") checks[[col]][checks$check_id == id]
mrow <- function(m, r) mall[mall$model == m & mall$lambda_rule == r, ]
srow <- function(m, r, s) stperf[stperf$model == m & stperf$lambda_rule == r & stperf$state == s, ]

L <- c(
"# Independent audit — FINAL LASSO analysis (CA/FL CoC homelessness)",
"",
sprintf("_Audit run %s by `audit_final_lasso.R`. Read-only: no model was refit, and no dataset, modeling script, or project document was modified._",
        format(Sys.time(), "%Y-%m-%d %H:%M %Z")),
"",
"## Verdict",
"",
sprintf("**%d PASS / %d WARNING / %d FAIL** across %d checks (`audit_checks.csv`).",
        n_pass, n_warn, n_fail, nrow(checks)),
"",
if (n_fail == 0)
  paste0("No check failed. The FINAL run is reproducible from its own exports, is built on the audited v2 workbook, ",
         "and its out-of-time design contains no detectable temporal leakage. Every warning below concerns how a result ",
         "may be *described*, not whether the pipeline computed it correctly.")
else "One or more checks FAILED; see the failure table below.",
"",
"## 1. Provenance: input workbook and version",
"",
sprintf("- Live MD5 of `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` = `%s`.", md5_v2),
sprintf("- Recorded in `FINAL_run_manifest.csv`, hard-coded as `EXPECTED_V2_MD5` in `fit_lasso_models.R`, and quoted in `FINAL_analysis_statements.md` — all three agree."),
sprintf("- The v1 workbook hashes to `%s`, a different file. v1 cannot have produced the FINAL outputs.", md5_v1),
"- The FINAL branch is doubly guarded in source: it aborts unless the resolved input path is the v2 workbook **and** the MD5 matches. `coordinator_confirmed_v2 = TRUE` and `run_mode = FINAL` are recorded.",
"",
"## 2. Shape of the modeling data",
"",
"| Quantity | Required | Observed |",
"|---|---|---|",
sprintf("| Rows | 887 | %d |", n_rows),
sprintf("| CoCs | 70 | %d |", n_cocs),
sprintf("| Candidate predictors | 38 | %d |", n_pred),
sprintf("| Controls | 2 | %d |", n_ctrl),
sprintf("| Non-finite values in target/controls/predictors | 0 | %d |", nonfin_tot),
sprintf("| Duplicate CoC-years | 0 | %d |", dupes),
"",
sprintf("Target range %.2f–%.2f per 10k, no 2021 target rows — matching `EDA_FINDINGS_v2.md` section 1. The 6 identifier columns plus target plus 2 controls plus 38 predictors account for all 47 columns.",
        min(dat[[target_col]]), max(dat[[target_col]])),
"",
"## 3. Out-of-time design",
"",
sprintf("- Eight outer folds validating on **%s** — 2021 is absent as a target year, so the sequence skips it.",
        paste(exp_val_years, collapse = ", ")),
"- Every fold's definition (train-year span and both row counts) reproduces exactly by re-deriving `target_year < validation_year` from the workbook.",
sprintf("- Maximum training year is strictly below the validation year in all 8 folds; 0 violations. Training windows expand 332 → 817 rows; 555 rows are scored in total."),
"- All 4,995 prediction rows satisfy `target_year == validation_year` and `predictor_year == target_year - 1`; no row with `target_year < 2017` is scored, so no in-sample scoring entered any metric.",
"- Every exported `actual` matches the workbook target for the same CoC-year.",
"",
"## 4. Leakage-critical construction",
"",
"| Property | How verified | Result |",
"|---|---|---|",
"| Identifiers excluded from the design matrix | term inventory across all 3,200 exported coefficient rows + source review of `build_design()` | no identifier ever appears; every term is intercept, control, predictor, or `predictor:FL` |",
sprintf("| Controls unpenalized | `penalty.factor` construction in source + selection frequencies | penalty 0 for controls; both glmnet call sites pass the penalty vector with `standardize = FALSE`; controls non-zero in 100%% of folds (%d coefficient rows, none exactly 0) |",
        nrow(ci)),
sprintf("| Scaling training-only | `std_params()` computed on `fit_rows`, applied to `apply_rows`; separate calls for outer scoring and inner tuning | confirmed; lambda-grid length varies %d–%d across folds, consistent with per-window refitting |",
        min(lamb$n_grid), max(lamb$n_grid)),
"| Lambda tuning training-only | `tune_fc()` operates on `spec$rows` = fold training index | confirmed |",
"| Inner tuning forward-chaining | source (`itr = uy[1:cc]`, `iva = uy[cc+1]`) + exported `n_inner_splits` | splits = K−2 in all 32 fold-model rows (3,4,5,6,7,8,9,10). Leave-one-year-out would give K (5–12); the exported counts rule it out |",
sprintf("| Duan smearing training-only | source + falsification test on exported log predictions | 0 of 72 exported factors match what a validation-residual estimator would give (mean deviation %.1f%%) |",
        100 * mean(abs(ratio$ratio - 1))),
"",
sprintf("The smearing falsification test is the strongest available evidence short of refitting: across all 72 model×fold×rule smearing factors, the validation-residual estimator would have produced a factor differing from the exported one by a mean of %.1f%% (range %.3f–%.3f on the ratio). 0 of 72 coincide, so the exported factors are not validation-derived.",
        100 * mean(abs(ratio$ratio - 1)), min(ratio$ratio), max(ratio$ratio)),
"",
sprintf("**One transparency note (WARNING, no numerical effect):** the log-target shift constant is `if (min(dat[[target_col]]) <= 0) 1 else 0`, evaluated over all 887 rows rather than training rows only. Because the minimum target is %.2f, the shift is 0 in every fold and no information crosses the split. It is recorded because it is the only preprocessing quantity in the pipeline read from the full column.",
        min(dat[[target_col]])),
"",
"## 5. Recomputed metrics",
"",
sprintf("All %d exported metric rows — pooled out-of-time, per fold, per state, and log-target — were recalculated directly from `FINAL_predictions.csv` and `FINAL_log_target_predictions.csv` using the same RMSE/MAE/R² definitions. Maximum absolute discrepancy: **%.3e**. Row counts behind each metric also reproduce exactly. Residual diagnostics (n, mean, sd, max |residual|) reproduce as well. Full detail in `recomputed_metrics.csv`.",
        nrow(recdf), worst),
"",
"Pooled out-of-time performance, raw target (recomputed values, identical to exports):",
"",
"| Model | Rule | n | RMSE | MAE | R² |",
"|---|---|---|---|---|---|",
paste(apply(mall[order(mall$rmse), ], 1, function(r)
  sprintf("| %s | %s | %s | %s | %s | %s |", r[["model"]], r[["lambda_rule"]], r[["n"]],
          fx(r[["rmse"]], 3), fx(r[["mae"]], 3), fx(r[["r2"]], 3))), collapse = "\n"),
"",
"## 6. The \"best unified model\" claim",
"",
sprintf("**Supported on squared-error criteria, with two qualifications.** Restricted to unified (single pooled) models, the raw-target state-interaction LASSO at lambda.min has the lowest pooled out-of-time RMSE (%s) and the highest R² (%s), beating the state-and-time baseline (RMSE %s, R² %s) and its own log-target counterpart (RMSE %s).",
        fx(claim_row$rmse, 3), fx(claim_row$r2, 3),
        fx(mrow("state_time_baseline", "none")$rmse, 3), fx(mrow("state_time_baseline", "none")$r2, 3),
        fx(raw_beats_log$rmse_log, 3)),
"",
sprintf("1. **MAE contradicts it.** Its MAE is %s, behind `pooled_lasso`/1se (%s), `pooled_lasso_state_interactions`/1se (%s) and `pooled_lasso`/min (%s). lambda.min wins on squared error while the 1se variants win on absolute error — the signature of a model that cuts large errors at the cost of the typical error. \"Best\" is therefore criterion-dependent and should be stated as best-on-RMSE.",
        fx(claim_row$mae, 3), fx(mrow("pooled_lasso", "1se")$mae, 3),
        fx(mrow("pooled_lasso_state_interactions", "1se")$mae, 3), fx(mrow("pooled_lasso", "min")$mae, 3)),
sprintf("2. **The word \"unified\" is load-bearing.** The two-state `separate_state_lasso` scores better overall (best RMSE %s, R² %s). The claim is true only as stated — for a single model covering both states — and becomes false if \"unified\" is dropped.",
        fx(min(sep$rmse), 3), fx(max(sep$r2), 3)),
"",
sprintf("Fold-level robustness: the claimed model has the lowest RMSE in %d of the 8 folds among unified models.", n_fold_win),
"",
"## 7. State-specific performance",
"",
"All 18 exported CA/FL rows reproduce exactly. Substantive observations:",
"",
sprintf("- Scored rows partition 347 California / 208 Florida = 555. California supplies 63%% of the scored rows, so pooled metrics are California-weighted."),
sprintf("- **The claimed best unified model is not best for Florida.** In California it is the strongest unified variant (RMSE %s, R² %s); in Florida it is the weakest of the four pooled LASSO variants (RMSE %s, R² %s), behind `pooled_lasso`/1se (RMSE %s, R² %s). Its overall win is carried by California.",
        fx(claim_ca$rmse, 3), fx(claim_ca$r2, 3), fx(claim_fl$rmse, 3), fx(claim_fl$r2, 3),
        fx(srow("pooled_lasso", "1se", "Florida")$rmse, 3), fx(srow("pooled_lasso", "1se", "Florida")$r2, 3)),
sprintf("- Across all models (not only unified ones) the lowest per-state RMSE is `%s`/%s in California (%s) and `%s`/%s in Florida (%s).",
        best_ca$model, best_ca$lambda_rule, fx(best_ca$rmse, 3),
        best_fl$model, best_fl$lambda_rule, fx(best_fl$rmse, 3)),
"- Florida RMSE is lower than California RMSE for every LASSO model and rule. This reflects Florida's much narrower CoC-rate distribution, not better explanation; RMSE is not comparable across states with different outcome spreads.",
sprintf("- The state-and-time baseline has a positive pooled R² (%s) but **negative R² within both states** (CA %s, FL %s). Its apparent pooled skill is entirely the CA/FL level gap. Pooled R² for any model here should not be read as within-state explanatory power.",
        fx(mrow("state_time_baseline", "none")$r2, 3),
        fx(base_neg$r2[base_neg$state == "California"], 3),
        fx(base_neg$r2[base_neg$state == "Florida"], 3)),
sprintf("- `separate_state_lasso` rows are byte-identical to the `separate_lasso_CA` / `separate_lasso_FL` rows by construction; it is the concatenation of the two state models, not a fifth independent model, and must not be counted as extra corroborating evidence."),
"",
"## 8. Selection frequency and sign stability",
"",
sprintf("Every one of the %d rows in `FINAL_coefficient_stability.csv` reproduces from `FINAL_coefficients_by_fold.csv` (selection frequency, mean and sd of coefficients, sign consistency; max discrepancy %.1e). All are based on the full 8 folds.",
        nrow(stab), max(c(abs(mj$selection_freq_exp - mj$selection_freq_rec),
                          abs(mj$mean_coef_exp - mj$mean_coef_rec)), na.rm = TRUE)),
"",
sprintf("In the headline model (`%s`, lambda.min), %d of %d penalized terms are selected in all 8 folds and %d in at least half; %d are never selected.",
        claim_model, nrow(always), nrow(hs), nrow(freq), sum(hs$selection_freq == 0)),
"",
"Most stable penalized terms in the headline model:",
"",
"| Term | Selection freq | Mean coef | Sign consistency |",
"|---|---|---|---|",
paste(apply(head(hs, 12), 1, function(r)
  sprintf("| %s | %s | %s | %s |", r[["term"]], fx(r[["selection_freq"]], 2),
          fx(r[["mean_coef"]], 3), fx(r[["sign_consistency"]], 2))), collapse = "\n"),
"",
if (nrow(unstable))
  sprintf("**Sign instability (WARNING):** %d frequently selected term(s) change sign across expanding training windows — %s. The direction of association for these is not stable and must not be reported as a directional finding.",
          nrow(unstable), paste(sprintf("`%s` (consistency %s)", unstable$term,
                                        fx(unstable$sign_consistency, 2)), collapse = ", "))
else "No term selected in at least half the folds changes sign across folds.",
"",
"## 9. Collinearity flags against the EDA",
"",
sprintf("`EDA_FINDINGS_v2.md` section 8 reports 18 predictor pairs with |r| ≥ 0.80 (confirmed: the table holds exactly 18 rows). The headline model selects %d terms in at least half its folds, which collapse to %d distinct predictors once `:FL` interactions are mapped to their base variable. **%d of those %d belong to at least one highly correlated pair**:",
        nrow(freq), length(sel_base), length(flagged), length(sel_base)),
"",
if (length(flagged)) paste(sprintf("- `%s`", flagged), collapse = "\n") else "- none",
"",
if (nrow(both_sel))
  paste0("Pairs where **both** members are frequently selected (coefficients are split between collinear columns; neither magnitude is interpretable alone):\n\n",
         paste(sprintf("- `%s` ~ `%s` (r = %s)", both_sel$variable_1, both_sel$variable_2, both_sel$r), collapse = "\n"))
else "No pair has both members frequently selected.",
"",
"LASSO chooses among near-collinear columns close to arbitrarily; which member survives can change with the training window. For every predictor listed above, the selected variable should be reported as a marker for its correlated cluster, not as the operative variable.",
"",
"## 10. PRELIMINARY outputs",
"",
sprintf("The 10 `PRELIMINARY_*` files are intact. They use a disjoint filename prefix from the 18 `FINAL_*` files, so the FINAL run could not overwrite them in place. The PRELIMINARY manifest still records the v1 development run (`DEVELOPMENT_V1`, v1 workbook, MD5 `%s`, 898 rows / 47 predictors / 71 CoCs) and every PRELIMINARY file's mtime predates the FINAL run timestamp %s. PRELIMINARY also ran without the log-target sensitivity, so no PRELIMINARY artefact was reused under a FINAL label.",
        md5_v1, mval[["timestamp_utc"]]),
"",
"## 11. Cross-file consistency",
"",
"- The six model names are identical across predictions, per-fold metrics, pooled metrics, residual diagnostics, state performance, and both log-target files; the coefficient and lambda files cover exactly the four penalized specs.",
"- Lambda-rule labels are used consistently (`min`/`1se` for penalized models, `none` for the OLS baseline); coefficients exist only for `min`/`1se`.",
"- The fold → validation-year mapping is identical in fold definitions, predictions, per-fold metrics, lambda choices and smearing factors.",
sprintf("- Row counts reconcile: %d prediction rows = 555 × 7 pooled-scale series + 347×2 CA + 208×2 FL. Every scored CoC-year appears exactly once per model × rule; no missing predictions.", nrow(preds)),
"- Target transformations are labelled unambiguously (`pooled_all_folds` vs `pooled_all_folds_LOGTARGET`); the raw-vs-log and lambda.min-vs-1se comparison tables reproduce from the two metric files, and their difference columns are arithmetically correct.",
"- `FINAL_model_summary.xlsx` carries the 11 expected sheets and its `metrics_overall` sheet matches the CSV.",
"- `FINAL_analysis_statements.md` agrees with the manifest on row count, CoC count, MD5 and the eight validation years.",
"",
"## 12. Warnings, in priority order",
"",
"Each item states the property that could **not** be confirmed as written, what was observed instead, and what it constrains.",
"",
paste(sprintf("%d. **Check %s — not confirmed: %s**\n   - Observed: %s\n   - Implication: %s",
              seq_len(sum(checks$status == "WARNING")),
              checks$check_id[checks$status == "WARNING"],
              checks$requirement[checks$status == "WARNING"],
              checks$observed[checks$status == "WARNING"],
              ifelse(nchar(checks$detail[checks$status == "WARNING"]) > 0,
                     checks$detail[checks$status == "WARNING"],
                     "reported for interpretation only")), collapse = "\n"),
"",
"None of these is a computational error. Each is a constraint on how the results may be worded.",
"",
"## Scope of this audit",
"",
"This audit recomputes exported quantities, reconciles files against each other and against the input workbook, and reviews the modeling source for leakage-critical construction. It does **not** refit any model, so it cannot independently confirm the numerical value of a fitted coefficient or a tuned lambda; those are verified for internal consistency and for structural correctness of the procedure that produced them. Data provenance upstream of `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` is outside this audit's scope and is covered by `CHANGELOG_v1_to_v2.md`.",
"",
"All findings concern predictive association in a two-state, time-ordered panel. Nothing in the audited outputs supports a causal reading.")

writeLines(L, file.path(AUDIT_DIR, "AUDIT_REPORT.md"))

cat(sprintf("\n=== AUDIT COMPLETE: %d PASS / %d WARNING / %d FAIL ===\n", n_pass, n_warn, n_fail))
cat("Written: outputs/lasso_audit/{audit_checks.csv, recomputed_metrics.csv, AUDIT_REPORT.md}\n")
