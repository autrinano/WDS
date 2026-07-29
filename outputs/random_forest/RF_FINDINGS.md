# Decision Tree and Random Forest findings

## What was fit

A pruned regression tree and a Random Forest were fit to predict next-year CoC homelessness rates per 10,000 residents. Both use the audited v2 model input and the same rolling-origin validation years as the completed LASSO and neural-network benchmarks.

## Primary factor-model result

- Pruned decision tree: RMSE 17.790, MAE 12.639, R2 0.467 (n = 555).
- Random Forest: RMSE 11.268, MAE 8.030, R2 0.786 (n = 555).
- These are out-of-time scores: each validation year was predicted using earlier target years only. OOB MSE was used only as a within-forest diagnostic, not as the reported test result.

## Most useful Random Forest variables

- coc_hic_temporary_beds_per_10k (mean permutation importance 21.916)
- coc_hic_psh_beds_per_10k (mean permutation importance 16.031)
- coc_log_estimated_population (mean permutation importance 14.608)
- coc_real_gdp_per_capita_2017_usd (mean permutation importance 10.351)
- coc_population_density_per_sq_mile (mean permutation importance 10.222)

## Interpretation

Tree splits and Random Forest importance are predictive associations. They do not show that changing a listed factor would cause homelessness to rise or fall. Correlated variables can share or exchange importance, so this list is not a policy-effect ranking.
