# Model comparison chart

This chart compares the five requested models. It reads completed output CSVs
and summaries only; it does not refit a model.

The grouped bar chart puts metrics on the x-axis and models in the legend.
RMSE, MAE, and MSE are error-metric performance indexes: 100 is the best
rolling-origin score among the four models with like-for-like evaluation.
Included metrics: RMSE, MAE, MSE (derived as RMSE squared), and R-squared.
F1 is not applicable because homelessness rate prediction is a regression task,
not a classification task.

The relaxed LASSO's saved result is an in-sample log-target model (n = 887),
not a rolling-origin raw-target result. Its raw-scale RMSE, MAE, MSE, and R²
are calculated from saved coefficients after inverse-transforming fitted values.
They remain marked with a dagger and must not be read as an out-of-time comparison.
