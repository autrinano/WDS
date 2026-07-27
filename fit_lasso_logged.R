## ---------------------------------------------------------------------------
## fit_lasso_logged.R
##
## LASSO on a log-transformed homelessness rate and nine log-transformed
## predictors, following the Module 4 workflow exactly:
##
##   1. model.matrix()          build the design matrix
##   2. cv.glmnet(alpha = 1)    K-fold cross validation to choose lambda
##   3. extract.coef()          pull the non-zero coefficients
##   4. lm() on selected vars   relaxed LASSO, for inference
##   5. backward selection      drop the least significant term until all remain
##   6. plot(fit, 1) / (fit, 2) model diagnosis
##
## Every step here is one the course covered. Deliberately NOT included:
## rolling-origin validation, Duan smearing retransformation, and training-only
## scaling. Those belong to the wider project pipeline (see fit_lasso_models.R)
## and are documented there; mixing them in here would put machinery in the
## write-up that the module does not cover.
##
## Nothing outside outputs/lasso_logged/ is written.
## ---------------------------------------------------------------------------

.libPaths(c(file.path(getwd(), "_r_libs"), .libPaths()))

suppressMessages({
  library(glmnet)
  library(coefplot)
  library(car)
  library(openxlsx)
  library(tools)
})

INPUT_XLSX   <- "outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx"
INPUT_SHEET  <- "LASSO Model Data"
EXPECTED_MD5 <- "5d3fd16b32c687e5207ea59c902e7bef"
OUT          <- "outputs/lasso_logged"

ID_COLS  <- c("state", "state_abbr", "coc_number", "coc_name",
              "predictor_year", "target_year")
TARGET   <- "target_homeless_rate_per_10k"
CONTROLS <- c("control_state_florida", "control_time_index")

## The nine predictors to log.
LOG_VARS <- c(
  "coc_population_density_per_sq_mile",
  "coc_real_gdp_per_capita_2017_usd",
  "coc_hic_psh_beds_per_10k",
  "coc_hic_temporary_beds_per_10k",
  "coc_permits_per_1000_housing_units",
  "coc_permits_value_per_1000_housing_units_2025_usd",
  "coc_real_median_household_income_2025_usd",
  "coc_real_per_capita_personal_income_2025_usd",
  "coc_relative_home_price_index_2000_base"
)

dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
dir.create(file.path(OUT, "figures"), showWarnings = FALSE, recursive = TRUE)

write_owned <- function(x, path) {
  norm <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  root <- normalizePath(OUT,           winslash = "/", mustWork = TRUE)
  if (!startsWith(norm, root)) stop("Refusing to write outside ", OUT, ": ", path)
  utils::write.csv(x, path, row.names = FALSE); invisible(path)
}
msg <- function(...) cat(sprintf(...), "\n", sep = "")

## ---------------------------------------------------------------------------
## Load and check the data
## ---------------------------------------------------------------------------

live_md5 <- unname(tools::md5sum(INPUT_XLSX))
if (!identical(live_md5, EXPECTED_MD5))
  stop("The input workbook has changed. Expected MD5 ", EXPECTED_MD5,
       ", found ", live_md5, ". Stopping.")

dat <- read.xlsx(INPUT_XLSX, sheet = INPUT_SHEET)
PREDICTORS <- setdiff(names(dat), c(ID_COLS, TARGET, CONTROLS))
stopifnot(nrow(dat) == 887, length(PREDICTORS) == 38)

chk <- dat[, c(TARGET, CONTROLS, PREDICTORS)]
bad <- vapply(chk, function(z) sum(!is.finite(z)), integer(1))
if (any(bad > 0)) stop("Missing or infinite values in: ",
                       paste(names(bad)[bad > 0], collapse = ", "))
msg("Data loaded: %d rows, %d predictors, no missing values.",
    nrow(dat), length(PREDICTORS))

## ---------------------------------------------------------------------------
## Log transformations
##
## log(0) is undefined. Two of the nine predictors contain real zeros -- CoC
## years with no shelter beds at all -- so those use log(1 + x) instead, which
## turns 0 into 0 and leaves the ordering unchanged. Nothing is dropped and no
## made-up number is added.
## ---------------------------------------------------------------------------

tf <- data.frame(variable = character(), transform = character(),
                 min_original = numeric(), n_zero = integer(),
                 reason = character(), stringsAsFactors = FALSE)

model_dat <- dat
for (v in LOG_VARS) {
  z <- dat[[v]]
  if (min(z) > 0) {
    model_dat[[v]] <- log(z)
    tf <- rbind(tf, data.frame(variable = v, transform = "log(x)",
      min_original = min(z), n_zero = 0L,
      reason = "all values above zero", stringsAsFactors = FALSE))
  } else {
    model_dat[[v]] <- log1p(z)
    tf <- rbind(tf, data.frame(variable = v, transform = "log(1 + x)",
      min_original = min(z), n_zero = sum(z == 0),
      reason = sprintf("%d real zeros (CoC-years with no beds); log(0) undefined",
                       sum(z == 0)), stringsAsFactors = FALSE))
  }
}
model_dat[[TARGET]] <- log(dat[[TARGET]])
tf <- rbind(data.frame(variable = TARGET, transform = "log(x)",
  min_original = min(dat[[TARGET]]), n_zero = 0L,
  reason = "smallest rate is 4.83, so plain log works",
  stringsAsFactors = FALSE), tf)
write_owned(tf, file.path(OUT, "LOGGED_transformation_log.csv"))
msg("Logged the target and %d predictors (%d used log(1+x)).",
    length(LOG_VARS), sum(tf$transform == "log(1 + x)"))

## ---------------------------------------------------------------------------
## Step 1: design matrix
## ---------------------------------------------------------------------------

fit_frame <- model_dat[, c(TARGET, CONTROLS, PREDICTORS)]
Y    <- fit_frame[[TARGET]]
X.fl <- model.matrix(as.formula(paste(TARGET, "~ .")), data = fit_frame)[, -1]
msg("\nDesign matrix: %d rows x %d columns.", nrow(X.fl), ncol(X.fl))

## ---------------------------------------------------------------------------
## Step 2: cv.glmnet -- K-fold cross validation to choose lambda
##
## The two baseline controls are forced into every model by setting their
## penalty.factor to 0, the technique from the "Force in" slide.
## ---------------------------------------------------------------------------

pf <- ifelse(colnames(X.fl) %in% CONTROLS, 0, 1)

set.seed(10)
fit.fl.cv <- cv.glmnet(X.fl, Y, alpha = 1, nfolds = 10, intercept = TRUE,
                       penalty.factor = pf)

i.min <- which(fit.fl.cv$lambda == fit.fl.cv$lambda.min)
i.1se <- which(fit.fl.cv$lambda == fit.fl.cv$lambda.1se)

msg("lambda.min = %.5f   CV error %.5f   %d non-zero",
    fit.fl.cv$lambda.min, fit.fl.cv$cvm[i.min], fit.fl.cv$nzero[i.min])
msg("lambda.1se = %.5f   CV error %.5f   %d non-zero",
    fit.fl.cv$lambda.1se, fit.fl.cv$cvm[i.1se], fit.fl.cv$nzero[i.1se])

cv_tbl <- data.frame(
  rule = c("lambda.min", "lambda.1se"),
  lambda = c(fit.fl.cv$lambda.min, fit.fl.cv$lambda.1se),
  cv_error_mse = c(fit.fl.cv$cvm[i.min], fit.fl.cv$cvm[i.1se]),
  cv_error_se  = c(fit.fl.cv$cvsd[i.min], fit.fl.cv$cvsd[i.1se]),
  n_nonzero    = c(fit.fl.cv$nzero[i.min], fit.fl.cv$nzero[i.1se]),
  stringsAsFactors = FALSE)
write_owned(cv_tbl, file.path(OUT, "LOGGED_cv_summary.csv"))

## The two plots from the slides.
png(file.path(OUT, "figures", "LOGGED_01_cv_curve.png"),
    width = 1000, height = 700, res = 130)
plot(fit.fl.cv); title("cv.glmnet: log target, 9 logged predictors", line = 2.6)
dev.off()

png(file.path(OUT, "figures", "LOGGED_02_coefficient_path.png"),
    width = 1100, height = 800, res = 130)
plot(glmnet(X.fl, Y, alpha = 1, penalty.factor = pf), xvar = "lambda", label = TRUE)
title("LASSO path (log target)", line = 2.6)
dev.off()

## ---------------------------------------------------------------------------
## Step 3: extract.coef -- the variables LASSO selected
## ---------------------------------------------------------------------------

coef.min <- extract.coef(fit.fl.cv, lambda = "lambda.min")
coef.1se <- extract.coef(fit.fl.cv, lambda = "lambda.1se")
var.min  <- setdiff(coef.min$Coefficient, "(Intercept)")
var.1se  <- setdiff(coef.1se$Coefficient, "(Intercept)")

names(coef.min)[names(coef.min) == "Value"] <- "coefficient"
names(coef.1se)[names(coef.1se) == "Value"] <- "coefficient"
coef.min$lambda_rule <- "lambda.min"; coef.1se$lambda_rule <- "lambda.1se"
class_coefs <- rbind(coef.min, coef.1se)
class_coefs$logged_variable <- class_coefs$Coefficient %in% LOG_VARS
write_owned(class_coefs, file.path(OUT, "LOGGED_class_coefficients.csv"))

msg("\nSelected at lambda.min: %d variables. At lambda.1se: %d.",
    length(var.min), length(var.1se))

## ---------------------------------------------------------------------------
## Step 4: Relaxed LASSO -- refit the selected variables with lm()
## ---------------------------------------------------------------------------

keep <- intersect(var.min, names(fit_frame))
fit.min.lm <- lm(as.formula(paste(TARGET, "~", paste(keep, collapse = " + "))),
                 data = fit_frame)
s0 <- summary(fit.min.lm)
msg("\nRelaxed LASSO lm(): %d predictors, adj R2 = %.4f, %d significant at .05",
    length(keep), s0$adj.r.squared,
    sum(s0$coefficients[-1, 4] < .05))
writeLines(capture.output(s0), file.path(OUT, "LOGGED_relaxed_lasso_summary.txt"))

relaxed <- data.frame(term = rownames(s0$coefficients),
                      estimate = s0$coefficients[, 1],
                      std_error = s0$coefficients[, 2],
                      t_value = s0$coefficients[, 3],
                      p_value = s0$coefficients[, 4],
                      stringsAsFactors = FALSE, row.names = NULL)
relaxed$logged_variable <- relaxed$term %in% LOG_VARS
write_owned(relaxed, file.path(OUT, "LOGGED_relaxed_lasso_lm.csv"))

## ---------------------------------------------------------------------------
## Step 5: Fine-tuning by backward selection
##
## Drop the least significant predictor one at a time, using Anova() to read
## each term's p-value, until every remaining predictor is significant at .05.
## ---------------------------------------------------------------------------

msg("\nBackward selection:")
fit.back <- fit.min.lm
steps <- data.frame(step = integer(), dropped = character(),
                    p_value = numeric(), n_predictors = integer(),
                    adj_r2 = numeric(), stringsAsFactors = FALSE)
k <- 0
repeat {
  av <- Anova(fit.back, type = "II")
  pv <- av[["Pr(>F)"]]; names(pv) <- rownames(av)
  pv <- pv[!is.na(pv) & names(pv) != "Residuals"]
  if (length(pv) == 0 || max(pv) <= .05) break
  drop_var <- names(pv)[which.max(pv)]
  k <- k + 1
  steps <- rbind(steps, data.frame(step = k, dropped = drop_var,
    p_value = max(pv), n_predictors = length(pv) - 1,
    adj_r2 = summary(update(fit.back, paste(". ~ . -", drop_var)))$adj.r.squared,
    stringsAsFactors = FALSE))
  msg("  %2d. drop %-52s p = %.3f", k, drop_var, max(pv))
  fit.back <- update(fit.back, paste(". ~ . -", drop_var))
}
fit.final <- fit.back
s <- summary(fit.final)
final_terms <- setdiff(names(coef(fit.final)), "(Intercept)")
msg("Final model: %d predictors, all significant. Adj R2 = %.4f",
    length(final_terms), s$adj.r.squared)

write_owned(steps, file.path(OUT, "LOGGED_backward_selection_steps.csv"))
writeLines(capture.output(s), file.path(OUT, "LOGGED_final_model_summary.txt"))

final_tbl <- data.frame(term = rownames(s$coefficients),
                        estimate = s$coefficients[, 1],
                        std_error = s$coefficients[, 2],
                        t_value = s$coefficients[, 3],
                        p_value = s$coefficients[, 4],
                        stringsAsFactors = FALSE, row.names = NULL)
final_tbl$logged_variable <- final_tbl$term %in% LOG_VARS
final_tbl$direction <- ifelse(final_tbl$estimate > 0, "increases", "decreases")
final_tbl$direction[final_tbl$term == "(Intercept)"] <- ""
write_owned(final_tbl, file.path(OUT, "LOGGED_final_model_coefficients.csv"))

## ---------------------------------------------------------------------------
## Step 6: Model diagnosis
## ---------------------------------------------------------------------------

png(file.path(OUT, "figures", "LOGGED_03_residuals_vs_fitted.png"),
    width = 900, height = 700, res = 130)
plot(fit.final, 1)
dev.off()

png(file.path(OUT, "figures", "LOGGED_04_qq_plot.png"),
    width = 900, height = 700, res = 130)
plot(fit.final, 2)
dev.off()

diag_tbl <- data.frame(
  measure = c("residual standard error", "adjusted R-squared", "F statistic",
              "model p-value", "n observations", "n predictors",
              "mean residual", "residual SD"),
  value = c(sprintf("%.4f", s$sigma), sprintf("%.4f", s$adj.r.squared),
            sprintf("%.1f", s$fstatistic[1]),
            format.pval(pf(s$fstatistic[1], s$fstatistic[2], s$fstatistic[3],
                           lower.tail = FALSE), digits = 3),
            nrow(fit_frame), length(final_terms),
            sprintf("%.2e", mean(residuals(fit.final))),
            sprintf("%.4f", sd(residuals(fit.final)))),
  stringsAsFactors = FALSE)
write_owned(diag_tbl, file.path(OUT, "LOGGED_model_diagnostics.csv"))

manifest <- data.frame(
  key = c("run_timestamp", "input_workbook", "input_md5", "rows",
          "target_transform", "n_logged_predictors", "cross_validation",
          "seed", "selection", "r_version"),
  value = c(format(Sys.time()), INPUT_XLSX, live_md5, nrow(dat), "log(target)",
            length(LOG_VARS), "cv.glmnet, 10-fold", "10",
            "LASSO at lambda.min, then backward selection to p < .05",
            R.version.string), stringsAsFactors = FALSE)
write_owned(manifest, file.path(OUT, "LOGGED_run_manifest.csv"))

## ---------------------------------------------------------------------------
## Summary
## ---------------------------------------------------------------------------

msg("\n================ FINAL MODEL ================")
inc <- final_tbl[final_tbl$estimate > 0 & final_tbl$term != "(Intercept)", ]
dec <- final_tbl[final_tbl$estimate < 0, ]
msg("\nThe next-year homelessness rate INCREASES with:")
for (i in seq_len(nrow(inc)))
  msg("  %-52s %+8.4f%s", inc$term[i], inc$estimate[i],
      ifelse(inc$logged_variable[i], "   [logged]", ""))
msg("\nThe next-year homelessness rate DECREASES with:")
for (i in seq_len(nrow(dec)))
  msg("  %-52s %+8.4f%s", dec$term[i], dec$estimate[i],
      ifelse(dec$logged_variable[i], "   [logged]", ""))
msg("\nAdjusted R-squared: %.4f on %d predictors", s$adj.r.squared, length(final_terms))
msg("\nOutputs in %s/", OUT)
