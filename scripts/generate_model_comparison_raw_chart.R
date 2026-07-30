###############################################################################
# generate_model_comparison_raw_chart.R
#
# Creates a presentation-ready RMSE comparison for the project's five key
# models. It reads the already-saved summary and does not fit or refit any
# model. The relaxed LASSO is shown with a dagger because its saved score is
# an in-sample, back-transformed log-target fit rather than an out-of-time one.
###############################################################################

OUT <- "outputs/model_comparison"
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

owned_path <- function(path) {
  root <- normalizePath(OUT, winslash = "/", mustWork = TRUE)
  parent <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  if (!startsWith(parent, root)) stop("Refusing to write outside ", OUT, ": ", path)
  path
}

metrics_path <- "outputs/model_comparison/model_comparison_metrics.csv"
if (!file.exists(metrics_path)) stop("Missing saved model metrics: ", metrics_path)
metrics <- read.csv(metrics_path, stringsAsFactors = FALSE, check.names = FALSE)

required <- c("model", "rmse", "mae", "mse")
if (!all(required %in% names(metrics))) {
  stop("Saved model metrics do not contain: ", paste(setdiff(required, names(metrics)), collapse = ", "))
}
if (any(!is.finite(as.matrix(metrics[, c("rmse", "mae", "mse")])))) {
  stop("Saved model metrics contain a non-finite raw error value.")
}

model_order <- c(
  "Random forest",
  "Neural net (32-16 + dropout)",
  "Multiple regression",
  "Rolling-origin LASSO (provided code)",
  "Relaxed LASSO (state + time controls)"
)
chart <- metrics[match(model_order, metrics$model), c("model", "rmse")]
if (anyNA(chart$model) || any(!is.finite(chart$rmse))) {
  stop("Could not locate a finite RMSE for every key model.")
}
chart$label <- c(
  "Random Forest",
  "Neural Net (32-16)",
  "Multiple Regression",
  "Rolling-Origin LASSO",
  "Relaxed LASSO†"
)
chart$color <- c("#53B283", "#DA907A", "#8F98B2", "#6489D9", "#E0B14B")

png(owned_path(file.path(OUT, "key_models_rmse_comparison.png")),
    width = 1400, height = 850, res = 140, bg = "#17181E")
op <- par(no.readonly = TRUE)
par(mar = c(5.2, 13, 7.2, 3.4), xaxs = "i", yaxs = "i",
    family = "sans", bg = "#17181E", fg = "#E9EAEC", col.axis = "#A9ADB7", col.lab = "#A9ADB7")
plot.new()
plot.window(xlim = c(0, 20), ylim = c(0.35, 5.65))
abline(v = seq(0, 20, 5), col = "#30323A", lwd = 1)
axis(1, at = seq(0, 20, 5), labels = seq(0, 20, 5), tick = FALSE,
     line = -0.25, cex.axis = 0.92, col.axis = "#A9ADB7")
segments(0, 0.55, 20, 0.55, col = "#3A3C45", lwd = 1.4)

y <- rev(seq_len(nrow(chart)))
bar_height <- 0.48
rect(0, y - bar_height / 2, chart$rmse, y + bar_height / 2,
     col = chart$color, border = NA)
text(-0.42, y, labels = chart$label, adj = 1, cex = 1.02,
     col = "#E9EAEC", font = 2, xpd = NA)
text(chart$rmse + 0.32, y, labels = sprintf("%.2f", chart$rmse), adj = 0,
     cex = 1.02, col = "#E9EAEC", font = 2)
title(main = "Random Forest had the lowest out-of-time prediction error",
      cex.main = 1.6, font.main = 2, col.main = "#F5F5F6", line = 3.15)
mtext("Out-of-time RMSE (lower is better)", side = 1, line = 2.35,
      cex = 0.95, col = "#A9ADB7")
mtext("555 held-out CoC-years for all models except † Relaxed LASSO, an in-sample teaching fit (n = 887).",
      side = 1, line = 3.75, cex = 0.7, col = "#A9ADB7")
par(op)
dev.off()

message("Wrote outputs/model_comparison/key_models_rmse_comparison.png")
