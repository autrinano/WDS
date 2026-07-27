## ---------------------------------------------------------------------------
## fit_neural_net.R
##
## Feed-forward neural network benchmark for next-year CoC homelessness rates.
##
## Follows the Module 7 lecture recipe (keras_model_sequential -> dense ReLU
## layers -> compile -> fit -> pick epochs where validation loss bottoms out ->
## refit -> evaluate once), adapted in four ways that the project requires:
##
##   1. REGRESSION, not classification. One linear output unit, MSE loss, MAE
##      metric. No softmax, no cross-entropy.
##   2. NO RANDOM SPLITS. The lecture used sample(n, 10000). This uses the same
##      expanding-window rolling origin as the LASSO (validation years 2017-2020
##      and 2022-2025) so the two model families are directly comparable.
##   3. TIME-BASED INNER SPLIT. Epoch selection holds out the most recent
##      training year rather than keras' random validation_split, so no future
##      year can influence tuning.
##   4. TRAINING-ONLY SCALING. X and y are standardised with means and SDs
##      computed on the outer training rows only, refit for every fold.
##
## Additionally, because the panel is small (887 rows) and network training is
## stochastic, every fold is fit under several random seeds and the reported
## prediction is the seed ensemble mean. Single-seed results are recorded too so
## the seed noise is visible rather than hidden.
##
## No model from any earlier stage is refit, and nothing outside
## outputs/neural_net/ is written.
## ---------------------------------------------------------------------------

.libPaths(c(file.path(getwd(), "_r_libs"), .libPaths()))

suppressMessages({
  library(reticulate)
  reticulate::use_condaenv("r", required = TRUE)
  library(keras3)
  library(openxlsx)
  library(tools)
})

set.seed(20260725)

## ---------------------------------------------------------------------------
## CONFIGURATION
## ---------------------------------------------------------------------------

INPUT_XLSX    <- "outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx"
INPUT_SHEET   <- "LASSO Model Data"
EXPECTED_MD5  <- "5d3fd16b32c687e5207ea59c902e7bef"
PRIOR_CSV     <- "outputs/lasso_sensitivity/data/S4_persistence_data.csv"
OUT           <- "outputs/neural_net"

VALIDATION_YEARS <- c(2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025)
ID_COLS <- c("state", "state_abbr", "coc_number", "coc_name",
             "predictor_year", "target_year")
TARGET  <- "target_homeless_rate_per_10k"
CONTROLS <- c("control_state_florida", "control_time_index")

SEEDS       <- c(10, 42, 123, 2024, 31337)   # lecture used set_random_seed(10)
MAX_EPOCHS  <- 300
PATIENCE    <- 20
BATCH_SIZE  <- 32
OPTIMIZER   <- "rmsprop"                     # lecture default

dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
dir.create(file.path(OUT, "figures"), showWarnings = FALSE, recursive = TRUE)

## Every write goes through this; it refuses any path outside OUT.
write_owned <- function(x, path, ...) {
  norm <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  root <- normalizePath(OUT,           winslash = "/", mustWork = TRUE)
  if (!startsWith(norm, root)) stop("Refusing to write outside ", OUT, ": ", path)
  if (grepl("\\.csv$", path)) utils::write.csv(x, path, row.names = FALSE)
  else saveRDS(x, path)
  invisible(path)
}

msg <- function(...) cat(sprintf(...), "\n", sep = "")

## ---------------------------------------------------------------------------
## 1. INPUT GATE
## ---------------------------------------------------------------------------

if (!file.exists(INPUT_XLSX)) stop("Model input not found: ", INPUT_XLSX)
live_md5 <- unname(tools::md5sum(INPUT_XLSX))
if (!identical(live_md5, EXPECTED_MD5)) {
  stop("MD5 mismatch on ", INPUT_XLSX, "\n  expected ", EXPECTED_MD5,
       "\n  observed ", live_md5,
       "\nThe v2 workbook changed. Stopping rather than modelling a different file.")
}
msg("Input verified: %s (MD5 %s)", INPUT_XLSX, live_md5)

dat <- read.xlsx(INPUT_XLSX, sheet = INPUT_SHEET)

PREDICTORS <- setdiff(names(dat), c(ID_COLS, TARGET, CONTROLS))

stopifnot(nrow(dat) == 887, length(PREDICTORS) == 38,
          length(unique(dat$coc_number)) == 70)

## Strict finite gate. Nothing is imputed anywhere in this script.
chk <- dat[, c(TARGET, CONTROLS, PREDICTORS)]
bad <- vapply(chk, function(z) sum(!is.finite(z)), integer(1))
if (any(bad > 0)) {
  stop("Non-finite values present (NA/NaN/Inf) in: ",
       paste(names(bad)[bad > 0], collapse = ", "),
       "\nThe model input is required to be complete; refusing to impute.")
}
msg("Data: %d rows, %d CoCs, %d predictors, 0 non-finite values",
    nrow(dat), length(unique(dat$coc_number)), length(PREDICTORS))

## ---------------------------------------------------------------------------
## 2. FEATURE SETS
##
##   factors             2 controls + 38 predictors, all 887 rows, 8 folds.
##                       Directly comparable to the pooled LASSO.
##   factors_plus_prior  the same, plus each CoC's own prior-year rate.
##   prior_only          prior-year rate alone (persistence reference).
##
## The prior-rate rows come from the already-built sensitivity sample so that
## eligibility is identical to the LASSO persistence benchmark: a present and
## finite prior rate, an available FY2024 denominator, and
## pit_count_caution_flag == 0 (which removes every predictor_year 2021 row and
## therefore the 2022 validation fold).
## ---------------------------------------------------------------------------

build_feature_sets <- function() {
  sets <- list()

  sets$factors <- list(
    data = dat, features = c(CONTROLS, PREDICTORS),
    label = "2 controls + 38 predictors")

  if (file.exists(PRIOR_CSV)) {
    pri <- read.csv(PRIOR_CSV, stringsAsFactors = FALSE)
    if (!"prior_homeless_rate_per_10k" %in% names(pri)) {
      warning("prior_homeless_rate_per_10k missing from ", PRIOR_CSV,
              "; skipping the persistence variants.")
    } else {
      pbad <- sum(!is.finite(pri$prior_homeless_rate_per_10k))
      if (pbad > 0) stop("Non-finite prior rates in ", PRIOR_CSV)
      sets$factors_plus_prior <- list(
        data = pri, features = c(CONTROLS, PREDICTORS, "prior_homeless_rate_per_10k"),
        label = "2 controls + 38 predictors + prior-year rate")
      sets$prior_only <- list(
        data = pri, features = "prior_homeless_rate_per_10k",
        label = "prior-year rate only")
    }
  } else {
    warning("Persistence sample not found at ", PRIOR_CSV,
            "; running the factor model only.")
  }
  sets
}

FEATURE_SETS <- build_feature_sets()

## ---------------------------------------------------------------------------
## 3. ARCHITECTURES
##
## `no_hidden` is the zero-layer network from the lecture's logistic-regression
## prelude, here with a linear output: it is ordinary least squares expressed as
## a network, and it is the anchor that shows what the hidden layers actually
## buy. `class_16_8` is the lecture's Yelp architecture unchanged.
## ---------------------------------------------------------------------------

ARCHITECTURES <- list(
  no_hidden       = list(units = integer(0), dropout = 0,
                         label = "0 hidden layers (linear)"),
  class_16_8      = list(units = c(16, 8),   dropout = 0,
                         label = "16 -> 8 ReLU (lecture architecture)"),
  class_16_8_drop = list(units = c(16, 8),   dropout = 0.2,
                         label = "16 -> 8 ReLU + dropout 0.2"),
  wide_32_16_drop = list(units = c(32, 16),  dropout = 0.2,
                         label = "32 -> 16 ReLU + dropout 0.2"),
  shallow_8_drop  = list(units = 8,          dropout = 0.2,
                         label = "8 ReLU + dropout 0.2")
)

build_model <- function(arch, p) {
  m <- keras_model_sequential(input_shape = c(p))
  for (u in arch$units) {
    m <- m |> layer_dense(units = u, activation = "relu")
    if (arch$dropout > 0) m <- m |> layer_dropout(rate = arch$dropout)
  }
  m <- m |> layer_dense(units = 1)          # linear output: regression
  m |> compile(optimizer = OPTIMIZER, loss = "mse", metrics = c("mae"))
  m
}

n_params <- function(arch, p) {
  sizes <- c(p, arch$units, 1)
  sum(vapply(seq_len(length(sizes) - 1),
             function(i) (sizes[i] + 1) * sizes[i + 1], numeric(1)))
}

## ---------------------------------------------------------------------------
## 4. METRICS -- identical definitions to fit_lasso_models.R
## ---------------------------------------------------------------------------

rmse <- function(a, p) sqrt(mean((a - p)^2))
mae  <- function(a, p) mean(abs(a - p))
r2   <- function(a, p) { sst <- sum((a - mean(a))^2)
                         if (sst == 0) NA_real_ else 1 - sum((a - p)^2) / sst }

## ---------------------------------------------------------------------------
## 5. TRAINING-ONLY STANDARDISATION
## ---------------------------------------------------------------------------

std_params <- function(x) {
  mu <- colMeans(x)
  sd <- apply(x, 2, stats::sd)
  sd[!is.finite(sd) | sd == 0] <- 1        # constant column -> leave centred
  list(mu = mu, sd = sd)
}
apply_std <- function(x, prm) scale(x, center = prm$mu, scale = prm$sd)

## ---------------------------------------------------------------------------
## 6. ONE FOLD, ONE ARCHITECTURE, ONE SEED
##
## Two-stage, exactly as taught: fit on the inner training years while watching
## the held-out most-recent training year to find where validation loss bottoms
## out, then refit on the whole training window for that many epochs and score
## the validation year once.
## ---------------------------------------------------------------------------

fit_one <- function(d, features, arch, train_idx, valid_idx, seed) {
  ## Release the previous fold's graph. Without this, hundreds of sequential
  ## fits accumulate state and training slows down markedly.
  try(keras3::clear_session(), silent = TRUE)

  x_all <- as.matrix(d[, features, drop = FALSE])
  y_all <- d[[TARGET]]

  xtr_raw <- x_all[train_idx, , drop = FALSE]
  ytr_raw <- y_all[train_idx]

  ## Scaling fit on outer training rows only.
  xp <- std_params(xtr_raw)
  y_mu <- mean(ytr_raw); y_sd <- stats::sd(ytr_raw)
  if (!is.finite(y_sd) || y_sd == 0) y_sd <- 1

  xtr <- apply_std(xtr_raw, xp);  ytr <- (ytr_raw - y_mu) / y_sd
  xva <- apply_std(x_all[valid_idx, , drop = FALSE], xp)

  ## Time-based inner split: most recent training year is the inner validation.
  tr_years  <- d$target_year[train_idx]
  inner_cut <- max(tr_years)
  inner_tr  <- which(tr_years <  inner_cut)
  inner_va  <- which(tr_years == inner_cut)

  keras3::set_random_seed(seed)

  chosen_epochs <- NA_integer_
  inner_best    <- NA_real_

  if (length(inner_tr) > 0 && length(inner_va) > 0) {
    m0 <- build_model(arch, length(features))
    es <- callback_early_stopping(monitor = "val_loss", patience = PATIENCE,
                                  restore_best_weights = TRUE)
    h <- m0 |> fit(
      xtr[inner_tr, , drop = FALSE], ytr[inner_tr],
      epochs = MAX_EPOCHS, batch_size = BATCH_SIZE,
      validation_data = list(xtr[inner_va, , drop = FALSE], ytr[inner_va]),
      callbacks = list(es), verbose = 0, shuffle = TRUE)
    vl <- h$metrics$val_loss
    chosen_epochs <- which.min(vl)
    inner_best    <- min(vl)
  }
  if (!is.finite(chosen_epochs) || chosen_epochs < 1) chosen_epochs <- 30L

  ## Refit on the full training window for the chosen number of epochs.
  keras3::set_random_seed(seed)
  m <- build_model(arch, length(features))
  m |> fit(xtr, ytr, epochs = as.integer(chosen_epochs),
           batch_size = BATCH_SIZE, verbose = 0, shuffle = TRUE)

  pred_std <- as.numeric(predict(m, xva, verbose = 0))
  list(pred          = pred_std * y_sd + y_mu,   # back to the original scale
       chosen_epochs = as.integer(chosen_epochs),
       inner_best    = inner_best)
}

## ---------------------------------------------------------------------------
## 7. RUN EVERYTHING
## ---------------------------------------------------------------------------

## prior_only needs only the two anchor architectures; the wide nets have
## nothing to do with a single input.
arch_for_set <- function(set_name) {
  if (set_name == "prior_only") c("no_hidden", "class_16_8")
  else names(ARCHITECTURES)
}

pred_rows   <- list()
seed_rows   <- list()
epoch_rows  <- list()
arch_rows   <- list()

t_start <- Sys.time()

for (set_name in names(FEATURE_SETS)) {
  fs <- FEATURE_SETS[[set_name]]
  d  <- fs$data
  features <- fs$features

  fold_years <- VALIDATION_YEARS[
    vapply(VALIDATION_YEARS,
           function(vy) any(d$target_year == vy) && any(d$target_year < vy),
           logical(1))]

  msg("\n=== feature set: %s (%s) | %d rows | %d inputs | %d folds ===",
      set_name, fs$label, nrow(d), length(features), length(fold_years))

  for (arch_name in arch_for_set(set_name)) {
    arch <- ARCHITECTURES[[arch_name]]
    arch_rows[[length(arch_rows) + 1]] <- data.frame(
      feature_set = set_name, architecture = arch_name,
      architecture_label = arch$label, n_inputs = length(features),
      hidden_layers = length(arch$units),
      units = paste(arch$units, collapse = "-"), dropout = arch$dropout,
      n_parameters = n_params(arch, length(features)),
      stringsAsFactors = FALSE)

    for (vy in fold_years) {
      train_idx <- which(d$target_year <  vy)
      valid_idx <- which(d$target_year == vy)
      stopifnot(max(d$target_year[train_idx]) < vy)   # temporal ordering

      seed_preds <- matrix(NA_real_, nrow = length(valid_idx), ncol = length(SEEDS))
      for (si in seq_along(SEEDS)) {
        r <- fit_one(d, features, arch, train_idx, valid_idx, SEEDS[si])
        seed_preds[, si] <- r$pred

        a <- d[[TARGET]][valid_idx]
        seed_rows[[length(seed_rows) + 1]] <- data.frame(
          feature_set = set_name, architecture = arch_name, validation_year = vy,
          seed = SEEDS[si], n = length(a), rmse = rmse(a, r$pred),
          mae = mae(a, r$pred), r2 = r2(a, r$pred),
          chosen_epochs = r$chosen_epochs, inner_best_val_loss = r$inner_best,
          stringsAsFactors = FALSE)
        epoch_rows[[length(epoch_rows) + 1]] <- data.frame(
          feature_set = set_name, architecture = arch_name, validation_year = vy,
          seed = SEEDS[si], chosen_epochs = r$chosen_epochs,
          stringsAsFactors = FALSE)
      }

      ens <- rowMeans(seed_preds)
      pred_rows[[length(pred_rows) + 1]] <- data.frame(
        feature_set = set_name, architecture = arch_name,
        validation_year = vy,
        state = d$state[valid_idx], state_abbr = d$state_abbr[valid_idx],
        coc_number = d$coc_number[valid_idx], coc_name = d$coc_name[valid_idx],
        predictor_year = d$predictor_year[valid_idx],
        target_year = d$target_year[valid_idx],
        actual = d[[TARGET]][valid_idx], predicted = ens,
        residual = d[[TARGET]][valid_idx] - ens,
        pred_sd_across_seeds = apply(seed_preds, 1, stats::sd),
        stringsAsFactors = FALSE)

      msg("  %-16s %-16s %d  n=%3d  RMSE=%6.3f  epochs=%s",
          set_name, arch_name, vy, length(valid_idx),
          rmse(d[[TARGET]][valid_idx], ens),
          paste(range(vapply(seq_along(SEEDS), function(i)
            seed_rows[[length(seed_rows) - length(SEEDS) + i]]$chosen_epochs,
            numeric(1))), collapse = "-"))
    }
  }
}

predictions <- do.call(rbind, pred_rows)
seed_perf   <- do.call(rbind, seed_rows)
epochs_tbl  <- do.call(rbind, epoch_rows)
arch_tbl    <- unique(do.call(rbind, arch_rows))

elapsed <- as.numeric(difftime(Sys.time(), t_start, units = "mins"))
msg("\nAll fits complete in %.1f minutes.", elapsed)

## ---------------------------------------------------------------------------
## 8. METRICS
## ---------------------------------------------------------------------------

agg <- function(df, keys) {
  do.call(rbind, lapply(split(df, df[keys], drop = TRUE), function(g) {
    cbind(g[1, keys, drop = FALSE],
          data.frame(n = nrow(g), rmse = rmse(g$actual, g$predicted),
                     mae = mae(g$actual, g$predicted),
                     r2 = r2(g$actual, g$predicted),
                     mean_pred_sd_across_seeds = mean(g$pred_sd_across_seeds),
                     row.names = NULL, stringsAsFactors = FALSE))
  }))
}

metrics_overall <- agg(predictions, c("feature_set", "architecture"))
metrics_overall <- metrics_overall[order(metrics_overall$feature_set,
                                         metrics_overall$rmse), ]
metrics_by_fold  <- agg(predictions, c("feature_set", "architecture", "validation_year"))
metrics_by_state <- agg(predictions, c("feature_set", "architecture", "state"))

## ---------------------------------------------------------------------------
## 9. COMPARISON WITH THE COMPLETED LASSO, ON IDENTICAL ROWS
## ---------------------------------------------------------------------------

comparison <- NULL
LASSO_PRED <- "outputs/lasso_models/FINAL_predictions.csv"
if (file.exists(LASSO_PRED)) {
  lp <- read.csv(LASSO_PRED, stringsAsFactors = FALSE)
  key <- function(z) paste(z$coc_number, z$target_year)

  cmp <- list()
  for (fset in unique(predictions$feature_set)) {
    nn_f <- predictions[predictions$feature_set == fset, ]
    rows <- unique(key(nn_f))
    for (lm_name in unique(lp$model)) {
      for (rule in unique(lp$lambda_rule[lp$model == lm_name])) {
        l <- lp[lp$model == lm_name & lp$lambda_rule == rule, ]
        l <- l[key(l) %in% rows, ]
        if (nrow(l) == 0) next
        cmp[[length(cmp) + 1]] <- data.frame(
          comparison_rows = fset, family = "LASSO", model = lm_name,
          rule = rule, n = nrow(l), rmse = rmse(l$actual, l$predicted),
          mae = mae(l$actual, l$predicted), r2 = r2(l$actual, l$predicted),
          stringsAsFactors = FALSE)
      }
    }
    for (a in unique(nn_f$architecture)) {
      g <- nn_f[nn_f$architecture == a, ]
      cmp[[length(cmp) + 1]] <- data.frame(
        comparison_rows = fset, family = "neural_net", model = a,
        rule = "seed_ensemble", n = nrow(g), rmse = rmse(g$actual, g$predicted),
        mae = mae(g$actual, g$predicted), r2 = r2(g$actual, g$predicted),
        stringsAsFactors = FALSE)
    }
  }
  comparison <- do.call(rbind, cmp)
  comparison <- comparison[order(comparison$comparison_rows, comparison$rmse), ]
}

## ---------------------------------------------------------------------------
## 10. WRITE OUTPUTS
## ---------------------------------------------------------------------------

write_owned(predictions,     file.path(OUT, "NN_predictions.csv"))
write_owned(metrics_overall, file.path(OUT, "NN_metrics_overall.csv"))
write_owned(metrics_by_fold, file.path(OUT, "NN_metrics_by_fold.csv"))
write_owned(metrics_by_state,file.path(OUT, "NN_state_performance.csv"))
write_owned(seed_perf,       file.path(OUT, "NN_seed_variability.csv"))
write_owned(epochs_tbl,      file.path(OUT, "NN_epoch_selection.csv"))
write_owned(arch_tbl,        file.path(OUT, "NN_architectures.csv"))
if (!is.null(comparison)) write_owned(comparison, file.path(OUT, "NN_comparison_with_lasso.csv"))

manifest <- data.frame(
  key = c("run_timestamp_utc", "input_workbook", "input_md5", "input_rows",
          "n_cocs", "n_predictors", "validation_years", "seeds", "optimizer",
          "loss", "batch_size", "max_epochs", "early_stopping_patience",
          "inner_split", "scaling", "target_scaling", "elapsed_minutes",
          "r_version", "keras_version"),
  value = c(format(Sys.time(), tz = "UTC", usetz = TRUE), INPUT_XLSX, live_md5,
            nrow(dat), length(unique(dat$coc_number)), length(PREDICTORS),
            paste(VALIDATION_YEARS, collapse = ","),
            paste(SEEDS, collapse = ","), OPTIMIZER, "mse", BATCH_SIZE,
            MAX_EPOCHS, PATIENCE,
            "most recent training year held out (time-based, never random)",
            "X standardised on outer training rows only",
            "y standardised on outer training rows only; predictions inverted",
            sprintf("%.1f", elapsed), R.version.string,
            as.character(keras3::keras$`__version__`)),
  stringsAsFactors = FALSE)
write_owned(manifest, file.path(OUT, "NN_run_manifest.csv"))

writeLines(capture.output(sessionInfo()),
           file.path(OUT, "session_info_neural_net.txt"))

## ---------------------------------------------------------------------------
## 11. FIGURES
## ---------------------------------------------------------------------------

png(file.path(OUT, "figures", "NN_01_architecture_comparison.png"),
    width = 1100, height = 700, res = 130)
op <- par(mar = c(9, 4, 3, 1))
mo <- metrics_overall[metrics_overall$feature_set == "factors", ]
bp <- barplot(mo$rmse, names.arg = mo$architecture, las = 2,
              ylab = "Out-of-time RMSE", main = "Neural net architectures (factor model)",
              col = "grey70", ylim = c(0, max(mo$rmse) * 1.15))
text(bp, mo$rmse, sprintf("%.2f", mo$rmse), pos = 3, cex = .8)
par(op); dev.off()

png(file.path(OUT, "figures", "NN_02_observed_vs_predicted.png"),
    width = 900, height = 900, res = 130)
best <- metrics_overall$architecture[metrics_overall$feature_set == "factors"][1]
g <- predictions[predictions$feature_set == "factors" &
                 predictions$architecture == best, ]
plot(g$predicted, g$actual, pch = 19, cex = .5,
     col = ifelse(g$state == "California", "#1f78b4", "#e31a1c"),
     xlab = "Predicted rate per 10k", ylab = "Observed rate per 10k",
     main = sprintf("Observed vs predicted (%s)", best))
abline(0, 1, lty = 2)
legend("topleft", c("California", "Florida"), pch = 19,
       col = c("#1f78b4", "#e31a1c"), bty = "n")
dev.off()

png(file.path(OUT, "figures", "NN_03_rmse_by_year.png"),
    width = 1100, height = 700, res = 130)
bf <- metrics_by_fold[metrics_by_fold$feature_set == "factors", ]
archs <- unique(bf$architecture)
plot(range(bf$validation_year), range(bf$rmse), type = "n",
     xlab = "Validation year", ylab = "RMSE",
     main = "Out-of-time RMSE by validation year (factor model)")
for (i in seq_along(archs)) {
  s <- bf[bf$architecture == archs[i], ]
  s <- s[order(s$validation_year), ]
  lines(s$validation_year, s$rmse, col = i, lwd = 2, type = "b", pch = 19)
}
legend("topright", archs, col = seq_along(archs), lwd = 2, bty = "n", cex = .8)
dev.off()

if (!is.null(comparison)) {
  png(file.path(OUT, "figures", "NN_04_nn_vs_lasso.png"),
      width = 1200, height = 700, res = 130)
  op <- par(mar = c(11, 4, 3, 1))
  cc <- comparison[comparison$comparison_rows == "factors", ]
  cc <- cc[order(cc$rmse), ]
  bp <- barplot(cc$rmse, names.arg = paste(cc$model, cc$rule), las = 2,
                col = ifelse(cc$family == "neural_net", "#e31a1c", "grey70"),
                ylab = "Out-of-time RMSE",
                main = "Neural net vs LASSO on identical rows")
  text(bp, cc$rmse, sprintf("%.2f", cc$rmse), pos = 3, cex = .7)
  legend("topleft", c("neural net", "LASSO"), fill = c("#e31a1c", "grey70"), bty = "n")
  par(op); dev.off()
}

## ---------------------------------------------------------------------------
## 12. CONSOLE SUMMARY
## ---------------------------------------------------------------------------

msg("\n================ NEURAL NET RESULTS ================")
for (fset in unique(metrics_overall$feature_set)) {
  msg("\n-- %s --", fset)
  s <- metrics_overall[metrics_overall$feature_set == fset, ]
  for (i in seq_len(nrow(s)))
    msg("  %-18s n=%3d  RMSE=%7.3f  MAE=%7.3f  R2=%6.3f  (seed sd %.2f)",
        s$architecture[i], s$n[i], s$rmse[i], s$mae[i], s$r2[i],
        s$mean_pred_sd_across_seeds[i])
}
if (!is.null(comparison)) {
  msg("\n-- best of each family on the factor rows --")
  cc <- comparison[comparison$comparison_rows == "factors", ]
  for (fam in unique(cc$family)) {
    b <- cc[cc$family == fam, ][1, ]
    msg("  %-11s %-34s RMSE=%7.3f  R2=%6.3f", fam,
        paste(b$model, b$rule), b$rmse, b$r2)
  }
}
msg("\nOutputs written to %s/", OUT)
msg("Nothing outside that directory was modified.")
