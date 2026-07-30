###############################################################################
# generate_model_comparison_chart.R
#
# Produces one cross-family performance chart from the completed, directly
# comparable out-of-time factor-model results.  The chart intentionally uses
# only models evaluated on the same 555 held-out CoC-years.  It does not refit
# any model and writes only to outputs/model_comparison/.
###############################################################################

OUT <- "outputs/model_comparison"
.libPaths(c(file.path(getwd(), "_r_libs"), .libPaths()))
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

owned_path <- function(path) {
  root <- normalizePath(OUT, winslash = "/", mustWork = TRUE)
  parent <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  if (!startsWith(parent, root)) stop("Refusing to write outside ", OUT, ": ", path)
  path
}

required_file <- function(path) {
  if (!file.exists(path)) stop("Required completed-model output is missing: ", path)
  path
}

lasso <- read.csv(required_file("outputs/lasso_models/FINAL_metrics_overall_out_of_time.csv"),
                  stringsAsFactors = FALSE)
nn <- read.csv(required_file("outputs/neural_net/NN_metrics_overall.csv"),
               stringsAsFactors = FALSE)
rf <- read.csv(required_file("outputs/random_forest/RF_metrics_overall.csv"),
               stringsAsFactors = FALSE)

## Four models have the same audited rolling-origin evaluation (555 held-out
## CoC-years). The saved relaxed LASSO is an in-sample log-target teaching
## model, so the chart retains its R2 but deliberately leaves its raw-scale
## out-of-time error metrics blank.
pick_one <- function(d, test, label) {
  out <- d[test, c("n", "rmse", "mae", "r2")]
  if (nrow(out) != 1L) stop("Could not uniquely locate ", label)
  out
}
ols <- pick_one(nn, nn$feature_set == "factors" & nn$architecture == "no_hidden", "multiple regression")
nn_3216 <- pick_one(nn, nn$feature_set == "factors" & nn$architecture == "wide_32_16_drop", "32-16 neural network")
forest <- pick_one(rf, rf$feature_set == "factors" & rf$model == "random_forest", "random forest")
## User-supplied rolling-origin LASSO: lambda is selected solely on the latest
## available training year, then the model is refit through the year preceding
## the held-out test year. This is intentionally distinct from FINAL_* LASSO.
run_user_rolling_lasso <- function(input_path) {
  data_all <- readxl::read_excel(input_path, sheet = "LASSO Model Data")
  target <- "target_homeless_rate_per_10k"
  controls <- c("control_state_florida", "control_time_index")
  excluded <- c("state", "state_abbr", "coc_number", "coc_name", "predictor_year",
                "target_year", target, controls)
  predictors <- setdiff(names(data_all), excluded)
  log_vars <- c("coc_population_density_per_sq_mile", "coc_real_gdp_per_capita_2017_usd",
                "coc_hic_psh_beds_per_10k", "coc_hic_temporary_beds_per_10k",
                "coc_permits_per_1000_housing_units",
                "coc_permits_value_per_1000_housing_units_2025_usd",
                "coc_real_median_household_income_2025_usd",
                "coc_real_per_capita_personal_income_2025_usd",
                "coc_relative_home_price_index_2000_base")
  data_log <- data_all
  for (v in log_vars) data_log[[v]] <- if (min(data_log[[v]]) > 0) log(data_log[[v]]) else log1p(data_log[[v]])
  data_log[[target]] <- log(data_log[[target]])
  fit_data <- data_log[, c(target, controls, predictors)]
  y <- fit_data[[target]]
  x <- model.matrix(as.formula(paste(target, "~ .")), data = fit_data)[, -1, drop = FALSE]
  penalty_factor <- ifelse(colnames(x) %in% controls, 0, 1)
  years <- c(2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025)
  predictions <- vector("list", length(years))
  for (i in seq_along(years)) {
    test_year <- years[i]
    outer_train <- which(data_all$target_year < test_year)
    outer_test <- which(data_all$target_year == test_year)
    train_years <- data_all$target_year[outer_train]
    tune_year <- max(train_years)
    inner_train <- outer_train[train_years < tune_year]
    inner_valid <- outer_train[train_years == tune_year]
    tuning_fit <- glmnet::glmnet(x[inner_train, , drop = FALSE], y[inner_train], alpha = 1,
                                 penalty.factor = penalty_factor)
    tuning_predictions <- predict(tuning_fit, newx = x[inner_valid, , drop = FALSE], s = tuning_fit$lambda)
    tuning_mse <- colMeans(sweep(tuning_predictions, 1, y[inner_valid], "-") ^ 2)
    selected_lambda <- tuning_fit$lambda[which.min(tuning_mse)]
    fitted <- glmnet::glmnet(x[outer_train, , drop = FALSE], y[outer_train], alpha = 1,
                             lambda = tuning_fit$lambda, penalty.factor = penalty_factor)
    predictions[[i]] <- data.frame(actual = data_all[[target]][outer_test],
      predicted = exp(as.numeric(predict(fitted, newx = x[outer_test, , drop = FALSE], s = selected_lambda))))
  }
  p <- do.call(rbind, predictions)
  data.frame(n = nrow(p), rmse = sqrt(mean((p$actual - p$predicted)^2)),
    mae = mean(abs(p$actual - p$predicted)),
    r2 = 1 - sum((p$actual - p$predicted)^2) / sum((p$actual - mean(p$actual))^2))
}
input_for_user_lasso <- required_file("outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx")
rolling_lasso <- run_user_rolling_lasso(input_for_user_lasso)

## Reconstruct saved relaxed-LASSO fitted values.  This is not a refit: it uses
## the archived coefficients, exact saved transformations, and audited workbook
## to calculate raw-scale fitted-value metrics after inverse-transforming exp(y).
relaxed_coef <- read.csv(required_file("outputs/lasso_logged/LOGGED_relaxed_lasso_lm.csv"),
                          stringsAsFactors = FALSE)
input_path <- required_file("outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx")
if (!identical(unname(tools::md5sum(input_path)), "5d3fd16b32c687e5207ea59c902e7bef"))
  stop("Relaxed-LASSO metric calculation aborted: v2 workbook MD5 does not match.")
raw_dat <- openxlsx::read.xlsx(input_path, sheet = "LASSO Model Data")
target <- "target_homeless_rate_per_10k"
log_vars <- c("coc_population_density_per_sq_mile", "coc_real_gdp_per_capita_2017_usd",
              "coc_hic_psh_beds_per_10k", "coc_hic_temporary_beds_per_10k",
              "coc_permits_per_1000_housing_units",
              "coc_permits_value_per_1000_housing_units_2025_usd",
              "coc_real_median_household_income_2025_usd",
              "coc_real_per_capita_personal_income_2025_usd",
              "coc_relative_home_price_index_2000_base")
logged_dat <- raw_dat
for (v in log_vars) logged_dat[[v]] <- if (min(raw_dat[[v]]) > 0) log(raw_dat[[v]]) else log1p(raw_dat[[v]])
terms <- relaxed_coef$term[relaxed_coef$term != "(Intercept)"]
coef_vec <- relaxed_coef$estimate[match(terms, relaxed_coef$term)]
pred_log <- relaxed_coef$estimate[relaxed_coef$term == "(Intercept)"] +
  as.numeric(as.matrix(logged_dat[, terms]) %*% coef_vec)
actual <- raw_dat[[target]]
predicted <- exp(pred_log)
relaxed_rmse <- sqrt(mean((actual - predicted)^2))
relaxed_mae <- mean(abs(actual - predicted))
relaxed_r2_raw <- 1 - sum((actual - predicted)^2) / sum((actual - mean(actual))^2)

metrics <- rbind(
  data.frame(model = "Multiple regression", evaluation = "rolling-origin, raw target", ols),
  data.frame(model = "Relaxed LASSO (state + time controls)", evaluation = "in-sample, back-transformed log target†", n = 887L,
             rmse = relaxed_rmse, mae = relaxed_mae, r2 = relaxed_r2_raw),
  data.frame(model = "Rolling-origin LASSO (provided code)", evaluation = "rolling-origin, raw target", rolling_lasso),
  data.frame(model = "Neural net (32-16 + dropout)", evaluation = "rolling-origin, raw target", nn_3216),
  data.frame(model = "Random forest", evaluation = "rolling-origin, raw target", forest)
)
metrics$mse <- metrics$rmse ^ 2
metrics$rmse_index <- min(metrics$rmse) / metrics$rmse * 100
metrics$mae_index  <- min(metrics$mae) / metrics$mae * 100
metrics$mse_index  <- min(metrics$mse) / metrics$mse * 100
metrics$r2_pct <- metrics$r2 * 100
write.csv(metrics, owned_path(file.path(OUT, "model_comparison_metrics.csv")), row.names = FALSE)

model_cols <- c("#5B6770", "#E6AB02", "#1F78B4", "#6A3D9A", "#E6550D")
index_matrix <- as.matrix(metrics[, c("rmse_index", "mae_index", "mse_index", "r2_pct")])

png(owned_path(file.path(OUT, "model_comparison_common_metrics.png")),
    width = 2200, height = 1500, res = 180)
op <- par(no.readonly = TRUE)
par(mar = c(5.2, 5.2, 6.3, 2.5), xaxs = "i", yaxs = "i")
barplot(index_matrix, beside = TRUE, col = model_cols, border = NA,
        names.arg = c("RMSE", "MAE", "MSE", expression(R^2)), ylim = c(0, 108),
        ylab = "Performance index / R² percentage (higher is better)", cex.names = 1.2)
abline(h = seq(0, 100, 20), col = "grey88", lwd = 1)
title(main = "Five-model comparison")
legend("top", inset = c(0, -0.06), legend = metrics$model, fill = model_cols,
       bty = "n", ncol = 3, cex = 0.85, xpd = NA)
mtext("Error metrics are indexed to the best score. † Relaxed LASSO uses in-sample back-transformed log-target fits; it is not an out-of-time comparison.",
      side = 1, line = 3.5, cex = 0.8)
par(op)
dev.off()

writeLines(c(
  "# Model comparison chart",
  "",
  "This chart compares the five requested models. It reads completed output CSVs",
  "and summaries only; it does not refit a model.",
  "",
  "The grouped bar chart puts metrics on the x-axis and models in the legend.",
  "RMSE, MAE, and MSE are error-metric performance indexes: 100 is the best",
  "rolling-origin score among the four models with like-for-like evaluation.",
  "Included metrics: RMSE, MAE, MSE (derived as RMSE squared), and R-squared.",
  "F1 is not applicable because homelessness rate prediction is a regression task,",
  "not a classification task.",
  "",
  "The relaxed LASSO's saved result is an in-sample log-target model (n = 887),",
  "not a rolling-origin raw-target result. Its raw-scale RMSE, MAE, MSE, and R²",
  "are calculated from saved coefficients after inverse-transforming fitted values.",
  "They remain marked with a dagger and must not be read as an out-of-time comparison."
), owned_path(file.path(OUT, "README.md")))

message("Wrote outputs/model_comparison/model_comparison_common_metrics.png")
