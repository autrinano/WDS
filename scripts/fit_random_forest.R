###############################################################################
# fit_random_forest.R
#
# Course-style regression tree and Random Forest benchmark for the CA/FL CoC
# homelessness panel.  The mechanics follow Module 9:
#   rpart() -> a single, pruned regression tree
#   randomForest() -> bootstrap trees averaged into a Random Forest
#   mtry / ntree / variable-importance diagnostics
#
# The validation differs from the classroom baseball example for one necessary
# reason: rows are ordered in time.  All tuning uses only earlier target years
# and each final score is on the next held-out year.  OOB MSE is exported as a
# diagnostic, never used as the project's headline performance measure.
#
# Owns scripts/fit_random_forest.R and outputs/random_forest/ only.
###############################################################################

.libPaths(c(file.path(getwd(), "_r_libs"), .libPaths()))

suppressPackageStartupMessages({
  library(openxlsx)
  library(rpart)
  library(randomForest)
  library(tools)
})

## ---------------------------------------------------------------------------
## 1. CONTRACT AND CONFIGURATION
## ---------------------------------------------------------------------------
INPUT_XLSX   <- "outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx"
INPUT_SHEET  <- "LASSO Model Data"
EXPECTED_MD5 <- "5d3fd16b32c687e5207ea59c902e7bef"
PRIOR_CSV    <- "outputs/lasso_sensitivity/data/S4_persistence_data.csv"
OUT          <- "outputs/random_forest"

VALIDATION_YEARS <- c(2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025)
ID_COLS <- c("state", "state_abbr", "coc_number", "coc_name",
             "predictor_year", "target_year")
TARGET   <- "target_homeless_rate_per_10k"
CONTROLS <- c("control_state_florida", "control_time_index")

# These match the regression-tree defaults emphasized in Module 9.  ntree is
# deliberately fixed before scoring; the OOB curve is retained as a stability
# diagnostic, while mtry is selected by time-respecting inner validation.
NTREE       <- 250L
NTREE_TUNE  <- 100L
NODESIZE    <- 5L
TREE_MIN_SPLIT  <- 20L
TREE_MIN_BUCKET <- 7L
TREE_MAX_DEPTH  <- 4L       # keeps the presentation tree readable
CP_GRID <- c(0, 0.001, 0.002, 0.005, 0.01, 0.02, 0.04)
SEED <- 20260729L

dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUT, "figures"), recursive = TRUE, showWarnings = FALSE)

owned_path <- function(path) {
  root <- normalizePath(OUT, winslash = "/", mustWork = TRUE)
  parent <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  if (!startsWith(parent, root)) stop("Refusing to write outside ", OUT, ": ", path)
  path
}
write_owned <- function(x, path) {
  utils::write.csv(x, owned_path(path), row.names = FALSE)
  invisible(path)
}
msg <- function(...) cat(sprintf(...), "\n", sep = "")

rmse <- function(a, p) sqrt(mean((a - p)^2))
mae  <- function(a, p) mean(abs(a - p))
r2   <- function(a, p) { sst <- sum((a - mean(a))^2)
                         if (sst == 0) NA_real_ else 1 - sum((a - p)^2) / sst }

## ---------------------------------------------------------------------------
## 2. INPUT GATE
## ---------------------------------------------------------------------------
if (!file.exists(INPUT_XLSX)) stop("Model input not found: ", INPUT_XLSX)
live_md5 <- unname(tools::md5sum(INPUT_XLSX))
if (!identical(live_md5, EXPECTED_MD5)) {
  stop("MD5 mismatch on ", INPUT_XLSX,
       "\n  expected ", EXPECTED_MD5, "\n  observed ", live_md5,
       "\nStopping rather than modeling an unaudited workbook.")
}
dat <- openxlsx::read.xlsx(INPUT_XLSX, sheet = INPUT_SHEET)
PREDICTORS <- setdiff(names(dat), c(ID_COLS, TARGET, CONTROLS))

stopifnot(nrow(dat) == 887L, length(unique(dat$coc_number)) == 70L,
          length(PREDICTORS) == 38L)
bad <- vapply(dat[c(TARGET, CONTROLS, PREDICTORS)],
              function(z) sum(!is.finite(z)), integer(1))
if (any(bad > 0)) {
  stop("Non-finite values present in: ", paste(names(bad)[bad > 0], collapse = ", "),
       ". No imputation is allowed.")
}
msg("Input verified: %d rows, %d CoCs, %d predictors; MD5 matches.",
    nrow(dat), length(unique(dat$coc_number)), length(PREDICTORS))

## The primary factor model is directly comparable with LASSO and NN.  The two
## persistence variants use the existing, eligibility-matched sensitivity data
## so we can test whether trees can ignore the 38 factors once prior rate is known.
feature_sets <- list(
  factors = list(data = dat, features = c(CONTROLS, PREDICTORS),
                 label = "2 controls + 38 candidate predictors")
)
if (file.exists(PRIOR_CSV)) {
  pri <- read.csv(PRIOR_CSV, stringsAsFactors = FALSE)
  if (!"prior_homeless_rate_per_10k" %in% names(pri))
    stop("Prior-rate sensitivity data lacks prior_homeless_rate_per_10k.")
  pbad <- vapply(pri[c(TARGET, CONTROLS, PREDICTORS, "prior_homeless_rate_per_10k")],
                 function(z) sum(!is.finite(z)), integer(1))
  if (any(pbad > 0)) stop("Non-finite values in persistence data: ",
                          paste(names(pbad)[pbad > 0], collapse = ", "))
  feature_sets$factors_plus_prior <- list(
    data = pri, features = c(CONTROLS, PREDICTORS, "prior_homeless_rate_per_10k"),
    label = "2 controls + 38 predictors + prior-year rate")
  feature_sets$prior_only <- list(
    data = pri, features = "prior_homeless_rate_per_10k", label = "prior-year rate only")
}

## ---------------------------------------------------------------------------
## 3. TIME-SAFE TUNING HELPERS
## ---------------------------------------------------------------------------
## Inner validation uses a sequence of earlier years only.  The final outer
## validation year is never touched by tuning, tree pruning, or mtry selection.
inner_years <- function(d, outer_train_idx) {
  yrs <- sort(unique(d$target_year[outer_train_idx]))
  if (length(yrs) < 3) return(integer(0))
  yrs[3:length(yrs)]
}

mtry_grid <- function(p) {
  if (p == 1L) return(1L)
  # Module 9 recommends p/3 as a starting point.  We compare that value against
  # five spread-out alternatives; a dense 1:p grid would add hundreds of near-
  # duplicate bootstrap fits without changing the classroom idea of tuning mtry.
  unique(pmax(1L, pmin(p, as.integer(round(c(1, p / 6, p / 3, p / 2,
                                               2 * p / 3, p))))))
}

fit_tree <- function(d, features, train_idx, cp, maxdepth = TREE_MAX_DEPTH) {
  f <- reformulate(features, response = TARGET)
  rpart::rpart(f, data = d[train_idx, c(TARGET, features), drop = FALSE],
               method = "anova",
               control = rpart::rpart.control(cp = cp, minsplit = TREE_MIN_SPLIT,
                 minbucket = TREE_MIN_BUCKET, maxdepth = maxdepth,
                 xval = 0))
}

tune_tree_cp <- function(d, features, outer_train_idx) {
  iy <- inner_years(d, outer_train_idx)
  if (!length(iy)) return(list(cp = 0.01, scores = data.frame()))
  rows <- lapply(CP_GRID, function(cp) {
    errs <- vapply(iy, function(vy) {
      tr <- outer_train_idx[d$target_year[outer_train_idx] < vy]
      va <- outer_train_idx[d$target_year[outer_train_idx] == vy]
      fit <- fit_tree(d, features, tr, cp)
      rmse(d[[TARGET]][va], as.numeric(predict(fit, d[va, features, drop = FALSE])))
    }, numeric(1))
    data.frame(cp = cp, inner_rmse = mean(errs), n_inner_splits = length(errs))
  })
  scores <- do.call(rbind, rows)
  list(cp = scores$cp[which.min(scores$inner_rmse)], scores = scores)
}

fit_rf <- function(d, features, train_idx, mtry, seed, ntree = NTREE) {
  set.seed(seed)
  f <- reformulate(features, response = TARGET)
  randomForest::randomForest(
    f, data = d[train_idx, c(TARGET, features), drop = FALSE],
    mtry = mtry, ntree = ntree, nodesize = NODESIZE,
    importance = TRUE, keep.inbag = TRUE
  )
}

tune_rf_mtry <- function(d, features, outer_train_idx, seed_offset = 0L) {
  grid <- mtry_grid(length(features)); iy <- inner_years(d, outer_train_idx)
  if (!length(iy)) return(list(mtry = grid[1], scores = data.frame()))
  rows <- lapply(grid, function(m) {
    errs <- vapply(seq_along(iy), function(j) {
      vy <- iy[j]
      tr <- outer_train_idx[d$target_year[outer_train_idx] < vy]
      va <- outer_train_idx[d$target_year[outer_train_idx] == vy]
      fit <- fit_rf(d, features, tr, m, SEED + seed_offset + 100L * m + j,
                    ntree = NTREE_TUNE)
      rmse(d[[TARGET]][va], as.numeric(predict(fit, d[va, features, drop = FALSE])))
    }, numeric(1))
    data.frame(mtry = m, inner_rmse = mean(errs), n_inner_splits = length(errs))
  })
  scores <- do.call(rbind, rows)
  list(mtry = scores$mtry[which.min(scores$inner_rmse)], scores = scores)
}

metric_table <- function(predictions, keys) {
  groups <- split(predictions, predictions[keys], drop = TRUE)
  do.call(rbind, lapply(groups, function(g) {
    cbind(g[1, keys, drop = FALSE], data.frame(
      n = nrow(g), rmse = rmse(g$actual, g$predicted),
      mae = mae(g$actual, g$predicted), r2 = r2(g$actual, g$predicted),
      stringsAsFactors = FALSE))
  }))
}

## ---------------------------------------------------------------------------
## 4. OUTER ROLLING-ORIGIN EVALUATION
## ---------------------------------------------------------------------------
pred_rows <- list(); tuning_rows <- list(); importance_rows <- list()
fold_rows <- list(); tree_rules <- list()

for (set_name in names(feature_sets)) {
  fs <- feature_sets[[set_name]]; d <- fs$data; features <- fs$features
  years <- VALIDATION_YEARS[VALIDATION_YEARS %in% d$target_year]
  msg("\n=== %s: %d rows, %d inputs ===", set_name, nrow(d), length(features))

  for (fi in seq_along(years)) {
    vy <- years[fi]
    tr <- which(d$target_year < vy); va <- which(d$target_year == vy)
    if (!length(tr) || !length(va)) next
    stopifnot(max(d$target_year[tr]) < vy)
    fold_rows[[length(fold_rows) + 1]] <- data.frame(
      feature_set = set_name, fold = fi, validation_year = vy,
      n_train_rows = length(tr), n_validation_rows = length(va),
      train_year_min = min(d$target_year[tr]), train_year_max = max(d$target_year[tr]),
      stringsAsFactors = FALSE)

    ## (a) Single, pruned regression tree: explanation-oriented baseline.
    tree_tuned <- tune_tree_cp(d, features, tr)
    if (nrow(tree_tuned$scores)) {
      tmp <- tree_tuned$scores
      tmp <- data.frame(feature_set = set_name, fold = fi, validation_year = vy,
        model = "decision_tree", tuning_parameter = "cp", parameter_value = tmp$cp,
        inner_rmse = tmp$inner_rmse, n_inner_splits = tmp$n_inner_splits,
        selected = tmp$cp == tree_tuned$cp, stringsAsFactors = FALSE)
      tuning_rows[[length(tuning_rows) + 1]] <- tmp
    }
    tfit <- fit_tree(d, features, tr, tree_tuned$cp)
    tpred <- as.numeric(predict(tfit, d[va, features, drop = FALSE]))

    ## (b) Random Forest: predictive ensemble.  mtry is chosen with inner
    ## forward chaining; OOB MSE remains a diagnostic only.
    rf_tuned <- tune_rf_mtry(d, features, tr, seed_offset = 10000L * fi)
    if (nrow(rf_tuned$scores)) {
      tmp <- rf_tuned$scores
      tmp <- data.frame(feature_set = set_name, fold = fi, validation_year = vy,
        model = "random_forest", tuning_parameter = "mtry", parameter_value = tmp$mtry,
        inner_rmse = tmp$inner_rmse, n_inner_splits = tmp$n_inner_splits,
        selected = tmp$mtry == rf_tuned$mtry, stringsAsFactors = FALSE)
      tuning_rows[[length(tuning_rows) + 1]] <- tmp
    }
    rfit <- fit_rf(d, features, tr, rf_tuned$mtry, SEED + 100000L * fi)
    rpred <- as.numeric(predict(rfit, d[va, features, drop = FALSE]))
    oob_mse <- tail(rfit$mse, 1)

    ids <- d[va, ID_COLS, drop = FALSE]
    add_pred <- function(model, p) data.frame(
      feature_set = set_name, model = model, fold = fi, validation_year = vy,
      ids, actual = d[[TARGET]][va], predicted = p,
      residual = d[[TARGET]][va] - p, stringsAsFactors = FALSE)
    pred_rows[[length(pred_rows) + 1]] <- add_pred("decision_tree", tpred)
    pred_rows[[length(pred_rows) + 1]] <- add_pred("random_forest", rpred)

    imp <- as.data.frame(randomForest::importance(rfit, type = 1))
    importance_rows[[length(importance_rows) + 1]] <- data.frame(
      feature_set = set_name, fold = fi, validation_year = vy,
      variable = rownames(imp), permutation_importance = imp[, 1],
      selected_mtry = rf_tuned$mtry, oob_mse = oob_mse, row.names = NULL,
      stringsAsFactors = FALSE)
    msg("  %d  n=%3d | tree cp=%0.3f RMSE=%6.3f | RF mtry=%2d RMSE=%6.3f",
        vy, length(va), tree_tuned$cp, rmse(d[[TARGET]][va], tpred),
        rf_tuned$mtry, rmse(d[[TARGET]][va], rpred))
  }
}

predictions <- do.call(rbind, pred_rows)
tuning <- do.call(rbind, tuning_rows)
importance_by_fold <- do.call(rbind, importance_rows)
fold_definitions <- do.call(rbind, fold_rows)
metrics_overall <- metric_table(predictions, c("feature_set", "model"))
metrics_overall <- metrics_overall[order(metrics_overall$feature_set, metrics_overall$rmse), ]
metrics_by_fold <- metric_table(predictions, c("feature_set", "model", "validation_year"))
metrics_by_state <- metric_table(predictions, c("feature_set", "model", "state"))

importance_summary <- do.call(rbind, lapply(
  split(importance_by_fold, interaction(importance_by_fold$feature_set,
                                        importance_by_fold$variable, drop = TRUE)),
  function(g) data.frame(feature_set = g$feature_set[1], variable = g$variable[1],
    n_folds = nrow(g), mean_permutation_importance = mean(g$permutation_importance),
    sd_permutation_importance = sd(g$permutation_importance),
    positive_fold_share = mean(g$permutation_importance > 0), stringsAsFactors = FALSE)))
importance_summary <- importance_summary[order(importance_summary$feature_set,
                                               -importance_summary$mean_permutation_importance), ]

## ---------------------------------------------------------------------------
## 5. FULL-DATA, PRESENTATION-ONLY TREE AND FOREST DIAGNOSTICS
## ---------------------------------------------------------------------------
primary <- feature_sets$factors; pd <- primary$data; pf <- primary$features
full_idx <- seq_len(nrow(pd))
full_tree_tuned <- tune_tree_cp(pd, pf, full_idx)
full_rf_tuned <- tune_rf_mtry(pd, pf, full_idx, seed_offset = 900000L)
# This two-level tree is a presentation aid only: it deliberately sacrifices
# detail so an audience can see the first two threshold decisions.  The scored
# decision-tree benchmark above retains its independently tuned depth-four cap.
presentation_tree <- fit_tree(pd, pf, full_idx, full_tree_tuned$cp, maxdepth = 2L)
presentation_rf <- fit_rf(pd, pf, full_idx, full_rf_tuned$mtry, SEED + 999999L)

frame <- presentation_tree$frame
internal <- rownames(frame)[frame$var != "<leaf>"]
if (length(internal)) {
  tree_rules <- data.frame(
    node = internal, split_variable = frame[internal, "var"],
    n_training_rows = frame[internal, "n"], deviance = frame[internal, "dev"],
    stringsAsFactors = FALSE)
}

## Compare completed model families on identical factor-model scored rows.
comparison <- metrics_overall[metrics_overall$feature_set == "factors", ]
comparison$family <- ifelse(comparison$model == "random_forest", "Random Forest", "Decision Tree")
lasso_path <- "outputs/lasso_models/FINAL_metrics_overall_out_of_time.csv"
nn_path <- "outputs/neural_net/NN_metrics_overall.csv"
if (file.exists(lasso_path)) {
  la <- read.csv(lasso_path, stringsAsFactors = FALSE)
  la <- la[la$model %in% c("pooled_lasso", "pooled_lasso_state_interactions") & la$lambda_rule == "min", ]
  comparison <- rbind(comparison, data.frame(feature_set = "factors", model = la$model,
    n = la$n, rmse = la$rmse, mae = la$mae, r2 = la$r2, family = "LASSO"))
}
if (file.exists(nn_path)) {
  nn <- read.csv(nn_path, stringsAsFactors = FALSE)
  nn <- nn[nn$feature_set == "factors" & nn$architecture %in% c("class_16_8", "wide_32_16_drop"), ]
  comparison <- rbind(comparison, data.frame(feature_set = "factors", model = nn$architecture,
    n = nn$n, rmse = nn$rmse, mae = nn$mae, r2 = nn$r2, family = "Neural Net"))
}
comparison <- comparison[order(comparison$rmse), ]

## ---------------------------------------------------------------------------
## 6. WRITE OWNED OUTPUTS
## ---------------------------------------------------------------------------
write_owned(fold_definitions, file.path(OUT, "RF_fold_definitions.csv"))
write_owned(predictions, file.path(OUT, "RF_predictions.csv"))
write_owned(metrics_overall, file.path(OUT, "RF_metrics_overall.csv"))
write_owned(metrics_by_fold, file.path(OUT, "RF_metrics_by_fold.csv"))
write_owned(metrics_by_state, file.path(OUT, "RF_metrics_by_state.csv"))
write_owned(tuning, file.path(OUT, "RF_time_tuning.csv"))
write_owned(importance_by_fold, file.path(OUT, "RF_importance_by_fold.csv"))
write_owned(importance_summary, file.path(OUT, "RF_importance_summary.csv"))
write_owned(tree_rules, file.path(OUT, "TREE_presentation_rules.csv"))
write_owned(comparison, file.path(OUT, "RF_cross_model_comparison.csv"))

manifest <- data.frame(
  field = c("input_workbook", "input_md5", "input_rows", "n_cocs", "n_predictors",
            "outer_validation_years", "scored_rows_primary", "random_split_used",
            "random_forest_ntree", "random_forest_ntree_tuning", "random_forest_nodesize", "mtry_selection",
            "tree_pruning", "oob_role", "interpretation", "r_version",
            "randomForest_version", "rpart_version", "timestamp_utc"),
  value = c(INPUT_XLSX, live_md5, nrow(dat), length(unique(dat$coc_number)), length(PREDICTORS),
            paste(VALIDATION_YEARS, collapse = ","),
            sum(predictions$feature_set == "factors" & predictions$model == "random_forest"),
            "No: rolling-origin only", NTREE, NTREE_TUNE, NODESIZE,
            "nested forward-chaining RMSE on training years only",
            "nested forward-chaining CP selection; maxdepth=4 for readable presentation tree",
            "diagnostic only; never headline validation metric",
            "predictive associations and feature-importance rankings are not causal effects",
            R.version.string, as.character(packageVersion("randomForest")),
            as.character(packageVersion("rpart")),
            format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")),
  stringsAsFactors = FALSE)
write_owned(manifest, file.path(OUT, "RF_run_manifest.csv"))
writeLines(capture.output(sessionInfo()), owned_path(file.path(OUT, "session_info_random_forest.txt")))

## ---------------------------------------------------------------------------
## 7. FIGURES
## ---------------------------------------------------------------------------
pretty_name <- function(x) {
  map <- c(
    coc_hic_temporary_beds_per_10k = "Temporary beds per 10k",
    coc_hic_psh_beds_per_10k = "PSH beds per 10k",
    coc_log_estimated_population = "Estimated CoC population (log)",
    coc_real_gdp_per_capita_2017_usd = "Real GDP per capita",
    coc_population_density_per_sq_mile = "Population density",
    coc_group_quarters_per_1000_residents = "Group-quarters population",
    coc_homeownership_rate_pct = "Homeownership rate",
    coc_housing_cost_burdened_households_pct = "Housing-cost burden",
    coc_international_migration_rate_per_1000 = "International migration rate",
    coc_real_per_capita_personal_income_2025_usd = "Real personal income per capita"
  )
  ifelse(x %in% names(map), unname(map[x]), gsub("_", " ", x))
}

draw_presentation_tree <- function(tree_fit, path) {
  fr <- tree_fit$frame
  root <- "1"; left <- "2"; right <- "3"
  leaves <- c("4", "5", "6", "7")
  internal <- rownames(fr)[fr$var != "<leaf>"]
  # rpart stores a primary split followed by competitor and surrogate splits
  # for each internal node. Locate the primary split for the requested node.
  primary_split <- function(node) {
    pos <- match(node, internal)
    starts <- cumsum(c(1L, head(1L + fr[internal, "ncompete"] +
                              fr[internal, "nsurrogate"], -1L)))
    tree_fit$splits[starts[pos], "index"]
  }
  node_label <- function(node) {
    variable <- pretty_name(fr[node, "var"])
    cutoff <- primary_split(node)
    paste0(variable, " < ", format(round(cutoff, 2), trim = TRUE))
  }
  leaf_label <- function(node) {
    paste0("Predicted rate\n", format(round(fr[node, "yval"], 1), nsmall = 1),
           " per 10k\n(n = ", fr[node, "n"], ")")
  }
  png(owned_path(path), width = 1800, height = 1050, res = 150)
  par(mar = c(1, 1, 4, 1), xpd = NA)
  plot.new(); plot.window(xlim = c(0, 1), ylim = c(0, 1))
  title(main = "How one regression tree makes a prediction", cex.main = 1.6, font.main = 2)
  # connections first, so the node boxes remain clean and prominent
  segments(.50, .77, .25, .56, lwd = 2, col = "#6B7280")
  segments(.50, .77, .75, .56, lwd = 2, col = "#6B7280")
  segments(.25, .43, .125, .22, lwd = 2, col = "#6B7280")
  segments(.25, .43, .375, .22, lwd = 2, col = "#6B7280")
  segments(.75, .43, .625, .22, lwd = 2, col = "#6B7280")
  segments(.75, .43, .875, .22, lwd = 2, col = "#6B7280")
  text(.365, .68, "Yes", col = "#2563EB", font = 2, cex = .9)
  text(.635, .68, "No", col = "#B45309", font = 2, cex = .9)
  text(.17, .35, "Yes", col = "#2563EB", font = 2, cex = .85)
  text(.33, .35, "No", col = "#B45309", font = 2, cex = .85)
  text(.67, .35, "Yes", col = "#2563EB", font = 2, cex = .85)
  text(.83, .35, "No", col = "#B45309", font = 2, cex = .85)
  rect(.31, .77, .69, .89, col = "#DCEEFF", border = "#2563EB", lwd = 2)
  text(.50, .83, node_label(root), cex = 1.15, font = 2)
  rect(.08, .43, .42, .56, col = "#E8F3FF", border = "#60A5FA", lwd = 2)
  rect(.58, .43, .92, .56, col = "#FFF3DF", border = "#F59E0B", lwd = 2)
  text(.25, .495, node_label(left), cex = 1.0, font = 2)
  text(.75, .495, node_label(right), cex = 1.0, font = 2)
  for (i in seq_along(leaves)) {
    xx <- c(.125, .375, .625, .875)[i]
    rect(xx - .105, .09, xx + .105, .22, col = "#ECFDF5", border = "#10B981", lwd = 2)
    text(xx, .155, leaf_label(leaves[i]), cex = .92, font = 2)
  }
  mtext("Illustrative full-data tree for explanation only; it is not a causal rule or a test score.",
        side = 1, line = -1, cex = .85, col = "#4B5563")
  dev.off()
}

draw_presentation_tree(presentation_tree,
  file.path(OUT, "figures", "TREE_01_pruned_regression_tree.png"))

## These compact, colour-coded figures are intentionally designed for slides.
## The full numbers remain available in the CSV outputs.
png(owned_path(file.path(OUT, "figures", "RF_04_permutation_importance.png")),
    width = 1400, height = 850, res = 150)
imp <- importance_summary[importance_summary$feature_set == "factors", ][1:10, ]
op <- par(mar = c(5, 13, 3, 2))
barplot(rev(imp$mean_permutation_importance), names.arg = rev(pretty_name(imp$variable)),
        horiz = TRUE, las = 1, col = "#0EA5A4", border = NA,
        xlab = "Mean permutation importance", cex.names = .9,
        main = "Random Forest: most useful predictors")
mtext("Higher values mean shuffling that variable hurt prediction more; not causal effects.",
      side = 3, line = .15, cex = .85, col = "#4B5563")
par(op); dev.off()

png(owned_path(file.path(OUT, "figures", "RF_05_cross_model_rmse.png")),
    width = 1400, height = 850, res = 150)
short_model <- c(
  random_forest = "Random Forest",
  wide_32_16_drop = "Neural Net (32-16)",
  class_16_8 = "Neural Net (16-8)",
  pooled_lasso_state_interactions = "LASSO + state interactions",
  pooled_lasso = "Pooled LASSO",
  decision_tree = "Single decision tree"
)
cols <- c("Decision Tree" = "#94A3B8", "Random Forest" = "#10B981",
          "LASSO" = "#60A5FA", "Neural Net" = "#F59E8B")
comparison$display_model <- unname(short_model[comparison$model])
op <- par(mar = c(5, 10, 3, 2))
bp <- barplot(rev(comparison$rmse), names.arg = rev(comparison$display_model),
              horiz = TRUE, las = 1, col = rev(cols[comparison$family]), border = NA,
              xlab = "Out-of-time RMSE (lower is better)", xlim = c(0, max(comparison$rmse) * 1.22),
              cex.names = .9, main = "Random Forest had the lowest prediction error")
text(rev(comparison$rmse), bp, labels = sprintf("%.2f", rev(comparison$rmse)),
     pos = 4, cex = 1, font = 2)
par(op); dev.off()

# Keep the analytic diagnostics below for appendix use.
png(owned_path(file.path(OUT, "figures", "RF_01_oob_error_by_trees.png")),
    width = 1100, height = 700, res = 130)
plot(seq_len(NTREE), presentation_rf$mse, type = "l", lwd = 2, col = "#1f78b4",
     xlab = "Number of trees", ylab = "OOB mean squared error",
     main = "Random Forest OOB error convergence (diagnostic only)")
abline(v = NTREE, lty = 2, col = "grey40")
dev.off()

png(owned_path(file.path(OUT, "figures", "RF_02_mtry_time_tuning.png")),
    width = 1100, height = 700, res = 130)
tt <- tuning[tuning$model == "random_forest" & tuning$feature_set == "factors", ]
plot(range(tt$parameter_value), range(tt$inner_rmse), type = "n", xlab = "mtry",
     ylab = "Inner forward-validation RMSE",
     main = "Random Forest mtry tuning within each training window")
for (yr in sort(unique(tt$validation_year))) {
  z <- tt[tt$validation_year == yr, ]; z <- z[order(z$parameter_value), ]
  lines(z$parameter_value, z$inner_rmse, type = "b", pch = 19,
        col = as.integer(factor(yr, levels = sort(unique(tt$validation_year)))))
}
legend("topright", legend = sort(unique(tt$validation_year)),
       col = seq_along(sort(unique(tt$validation_year))), lty = 1, pch = 19,
       title = "Outer validation year", bty = "n", cex = .8)
dev.off()

png(owned_path(file.path(OUT, "figures", "RF_03_observed_vs_predicted.png")),
    width = 900, height = 900, res = 130)
g <- predictions[predictions$feature_set == "factors" & predictions$model == "random_forest", ]
plot(g$predicted, g$actual, pch = 19, cex = .55,
     col = ifelse(g$state == "California", "#1f78b4", "#e31a1c"),
     xlab = "Predicted rate per 10k", ylab = "Observed rate per 10k",
     main = "Random Forest: observed vs predicted (out of time)")
abline(0, 1, lty = 2)
legend("topleft", c("California", "Florida"), pch = 19,
       col = c("#1f78b4", "#e31a1c"), bty = "n")
dev.off()

## ---------------------------------------------------------------------------
## 8. PLAIN-LANGUAGE FINDINGS
## ---------------------------------------------------------------------------
primary_metrics <- metrics_overall[metrics_overall$feature_set == "factors", ]
rf_primary <- primary_metrics[primary_metrics$model == "random_forest", ]
tree_primary <- primary_metrics[primary_metrics$model == "decision_tree", ]
top_imp <- importance_summary[importance_summary$feature_set == "factors", ][1:5, ]
findings <- c(
  "# Decision Tree and Random Forest findings",
  "",
  "## What was fit",
  "",
  "A pruned regression tree and a Random Forest were fit to predict next-year CoC homelessness rates per 10,000 residents. Both use the audited v2 model input and the same rolling-origin validation years as the completed LASSO and neural-network benchmarks.",
  "",
  "## Primary factor-model result",
  "",
  sprintf("- Pruned decision tree: RMSE %.3f, MAE %.3f, R2 %.3f (n = %d).", tree_primary$rmse, tree_primary$mae, tree_primary$r2, tree_primary$n),
  sprintf("- Random Forest: RMSE %.3f, MAE %.3f, R2 %.3f (n = %d).", rf_primary$rmse, rf_primary$mae, rf_primary$r2, rf_primary$n),
  "- These are out-of-time scores: each validation year was predicted using earlier target years only. OOB MSE was used only as a within-forest diagnostic, not as the reported test result.",
  "",
  "## Most useful Random Forest variables",
  "",
  paste0("- ", top_imp$variable, " (mean permutation importance ", sprintf("%.3f", top_imp$mean_permutation_importance), ")"),
  "",
  "## Interpretation",
  "",
  "Tree splits and Random Forest importance are predictive associations. They do not show that changing a listed factor would cause homelessness to rise or fall. Correlated variables can share or exchange importance, so this list is not a policy-effect ranking."
)
writeLines(findings, owned_path(file.path(OUT, "RF_FINDINGS.md")))

msg("\n================ RANDOM FOREST RESULTS ================")
print(metrics_overall, row.names = FALSE)
msg("\nPrimary Random Forest: RMSE %.3f | MAE %.3f | R2 %.3f", rf_primary$rmse, rf_primary$mae, rf_primary$r2)
msg("Outputs written only to %s", OUT)
