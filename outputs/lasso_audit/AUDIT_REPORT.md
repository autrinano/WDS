# Independent audit — FINAL LASSO analysis (CA/FL CoC homelessness)

_Audit run 2026-07-24 20:31 EDT by `audit_final_lasso.R`. Read-only: no model was refit, and no dataset, modeling script, or project document was modified._

## Verdict

**93 PASS / 7 WARNING / 0 FAIL** across 100 checks (`audit_checks.csv`).

No check failed. The FINAL run is reproducible from its own exports, is built on the audited v2 workbook, and its out-of-time design contains no detectable temporal leakage. Every warning below concerns how a result may be *described*, not whether the pipeline computed it correctly.

## 1. Provenance: input workbook and version

- Live MD5 of `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` = `5d3fd16b32c687e5207ea59c902e7bef`.
- Recorded in `FINAL_run_manifest.csv`, hard-coded as `EXPECTED_V2_MD5` in `fit_lasso_models.R`, and quoted in `FINAL_analysis_statements.md` — all three agree.
- The v1 workbook hashes to `4110465a13203019171ff2b3e4d6bb8e`, a different file. v1 cannot have produced the FINAL outputs.
- The FINAL branch is doubly guarded in source: it aborts unless the resolved input path is the v2 workbook **and** the MD5 matches. `coordinator_confirmed_v2 = TRUE` and `run_mode = FINAL` are recorded.

## 2. Shape of the modeling data

| Quantity | Required | Observed |
|---|---|---|
| Rows | 887 | 887 |
| CoCs | 70 | 70 |
| Candidate predictors | 38 | 38 |
| Controls | 2 | 2 |
| Non-finite values in target/controls/predictors | 0 | 0 |
| Duplicate CoC-years | 0 | 0 |

Target range 4.83–165.09 per 10k, no 2021 target rows — matching `EDA_FINDINGS_v2.md` section 1. The 6 identifier columns plus target plus 2 controls plus 38 predictors account for all 47 columns.

## 3. Out-of-time design

- Eight outer folds validating on **2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025** — 2021 is absent as a target year, so the sequence skips it.
- Every fold's definition (train-year span and both row counts) reproduces exactly by re-deriving `target_year < validation_year` from the workbook.
- Maximum training year is strictly below the validation year in all 8 folds; 0 violations. Training windows expand 332 → 817 rows; 555 rows are scored in total.
- All 4,995 prediction rows satisfy `target_year == validation_year` and `predictor_year == target_year - 1`; no row with `target_year < 2017` is scored, so no in-sample scoring entered any metric.
- Every exported `actual` matches the workbook target for the same CoC-year.

## 4. Leakage-critical construction

| Property | How verified | Result |
|---|---|---|
| Identifiers excluded from the design matrix | term inventory across all 3,200 exported coefficient rows + source review of `build_design()` | no identifier ever appears; every term is intercept, control, predictor, or `predictor:FL` |
| Controls unpenalized | `penalty.factor` construction in source + selection frequencies | penalty 0 for controls; both glmnet call sites pass the penalty vector with `standardize = FALSE`; controls non-zero in 100% of folds (96 coefficient rows, none exactly 0) |
| Scaling training-only | `std_params()` computed on `fit_rows`, applied to `apply_rows`; separate calls for outer scoring and inner tuning | confirmed; lambda-grid length varies 77–100 across folds, consistent with per-window refitting |
| Lambda tuning training-only | `tune_fc()` operates on `spec$rows` = fold training index | confirmed |
| Inner tuning forward-chaining | source (`itr = uy[1:cc]`, `iva = uy[cc+1]`) + exported `n_inner_splits` | splits = K−2 in all 32 fold-model rows (3,4,5,6,7,8,9,10). Leave-one-year-out would give K (5–12); the exported counts rule it out |
| Duan smearing training-only | source + falsification test on exported log predictions | 0 of 72 exported factors match what a validation-residual estimator would give (mean deviation 11.0%) |

The smearing falsification test is the strongest available evidence short of refitting: across all 72 model×fold×rule smearing factors, the validation-residual estimator would have produced a factor differing from the exported one by a mean of 11.0% (range 0.808–1.671 on the ratio). 0 of 72 coincide, so the exported factors are not validation-derived.

**One transparency note (WARNING, no numerical effect):** the log-target shift constant is `if (min(dat[[target_col]]) <= 0) 1 else 0`, evaluated over all 887 rows rather than training rows only. Because the minimum target is 4.83, the shift is 0 in every fold and no information crosses the split. It is recorded because it is the only preprocessing quantity in the pipeline read from the full column.

## 5. Recomputed metrics

All 128 exported metric rows — pooled out-of-time, per fold, per state, and log-target — were recalculated directly from `FINAL_predictions.csv` and `FINAL_log_target_predictions.csv` using the same RMSE/MAE/R² definitions. Maximum absolute discrepancy: **6.395e-14**. Row counts behind each metric also reproduce exactly. Residual diagnostics (n, mean, sd, max |residual|) reproduce as well. Full detail in `recomputed_metrics.csv`.

Pooled out-of-time performance, raw target (recomputed values, identical to exports):

| Model | Rule | n | RMSE | MAE | R² |
|---|---|---|---|---|---|
| separate_lasso_FL | 1se | 208 | 10.409 | 7.347 | 0.373 |
| separate_lasso_FL | min | 208 | 10.441 | 7.886 | 0.369 |
| separate_state_lasso | 1se | 555 | 13.902 | 10.179 | 0.674 |
| separate_state_lasso | min | 555 | 14.058 | 10.576 | 0.667 |
| pooled_lasso_state_interactions | min | 555 | 14.692 | 10.141 | 0.636 |
| pooled_lasso_state_interactions | 1se | 555 | 15.127 | 9.911 | 0.615 |
| pooled_lasso | min | 555 | 15.297 | 10.158 | 0.606 |
| separate_lasso_CA | 1se | 347 | 15.626 | 11.877 | 0.582 |
| pooled_lasso | 1se | 555 | 15.805 | 9.805 | 0.579 |
| separate_lasso_CA | min | 347 | 15.835 | 12.188 | 0.571 |
| state_time_baseline | none | 555 | 21.931 | 14.983 | 0.190 |

## 6. The "best unified model" claim

**Supported on squared-error criteria, with two qualifications.** Restricted to unified (single pooled) models, the raw-target state-interaction LASSO at lambda.min has the lowest pooled out-of-time RMSE (14.692) and the highest R² (0.636), beating the state-and-time baseline (RMSE 21.931, R² 0.190) and its own log-target counterpart (RMSE 21.746).

1. **MAE contradicts it.** Its MAE is 10.141, behind `pooled_lasso`/1se (9.805), `pooled_lasso_state_interactions`/1se (9.911) and `pooled_lasso`/min (10.158). lambda.min wins on squared error while the 1se variants win on absolute error — the signature of a model that cuts large errors at the cost of the typical error. "Best" is therefore criterion-dependent and should be stated as best-on-RMSE.
2. **The word "unified" is load-bearing.** The two-state `separate_state_lasso` scores better overall (best RMSE 13.902, R² 0.674). The claim is true only as stated — for a single model covering both states — and becomes false if "unified" is dropped.

Fold-level robustness: the claimed model has the lowest RMSE in 6 of the 8 folds among unified models.

## 7. State-specific performance

All 18 exported CA/FL rows reproduce exactly. Substantive observations:

- Scored rows partition 347 California / 208 Florida = 555. California supplies 63% of the scored rows, so pooled metrics are California-weighted.
- **The claimed best unified model is not best for Florida.** In California it is the strongest unified variant (RMSE 16.751, R² 0.520); in Florida it is the weakest of the four pooled LASSO variants (RMSE 10.386, R² 0.376), behind `pooled_lasso`/1se (RMSE 8.472, R² 0.585). Its overall win is carried by California.
- Across all models (not only unified ones) the lowest per-state RMSE is `separate_lasso_CA`/1se in California (15.626) and `pooled_lasso`/1se in Florida (8.472).
- Florida RMSE is lower than California RMSE for every LASSO model and rule. This reflects Florida's much narrower CoC-rate distribution, not better explanation; RMSE is not comparable across states with different outcome spreads.
- The state-and-time baseline has a positive pooled R² (0.190) but **negative R² within both states** (CA -0.126, FL -0.072). Its apparent pooled skill is entirely the CA/FL level gap. Pooled R² for any model here should not be read as within-state explanatory power.
- `separate_state_lasso` rows are byte-identical to the `separate_lasso_CA` / `separate_lasso_FL` rows by construction; it is the concatenation of the two state models, not a fifth independent model, and must not be counted as extra corroborating evidence.

## 8. Selection frequency and sign stability

Every one of the 392 rows in `FINAL_coefficient_stability.csv` reproduces from `FINAL_coefficients_by_fold.csv` (selection frequency, mean and sd of coefficients, sign consistency; max discrepancy 5.3e-14). All are based on the full 8 folds.

In the headline model (`pooled_lasso_state_interactions`, lambda.min), 14 of 76 penalized terms are selected in all 8 folds and 23 in at least half; 43 are never selected.

Most stable penalized terms in the headline model:

| Term | Selection freq | Mean coef | Sign consistency |
|---|---|---|---|
| coc_hic_psh_beds_per_10k | 1.00 | 13.556 | 1.00 |
| coc_hic_temporary_beds_per_10k | 1.00 | 8.178 | 1.00 |
| coc_log_estimated_population | 1.00 | -7.130 | 1.00 |
| coc_housing_cost_burdened_households_pct | 1.00 | 5.794 | 1.00 |
| coc_population_density_per_sq_mile | 1.00 | -5.734 | 1.00 |
| coc_hic_temporary_beds_per_10k:FL | 1.00 | -4.870 | 1.00 |
| coc_homeownership_rate_pct:FL | 1.00 | 2.587 | 1.00 |
| coc_population_growth_rate_pct | 1.00 | -1.422 | 1.00 |
| coc_real_gdp_quantity_index:FL | 1.00 | -1.350 | 1.00 |
| coc_real_gdp_quantity_index | 1.00 | 1.342 | 1.00 |
| coc_income_inequality_ratio:FL | 1.00 | -1.038 | 1.00 |
| coc_international_migration_rate_per_1000 | 1.00 | -0.955 | 1.00 |

No term selected in at least half the folds changes sign across folds.

## 9. Collinearity flags against the EDA

`EDA_FINDINGS_v2.md` section 8 reports 18 predictor pairs with |r| ≥ 0.80 (confirmed: the table holds exactly 18 rows). The headline model selects 23 terms in at least half its folds, which collapse to 16 distinct predictors once `:FL` interactions are mapped to their base variable. **3 of those 16 belong to at least one highly correlated pair**:

- `coc_population_growth_rate_pct`
- `coc_real_gdp_quantity_index`
- `coc_permits_value_per_1000_housing_units_2025_usd`

No pair has both members frequently selected.

LASSO chooses among near-collinear columns close to arbitrarily; which member survives can change with the training window. For every predictor listed above, the selected variable should be reported as a marker for its correlated cluster, not as the operative variable.

## 10. PRELIMINARY outputs

The 10 `PRELIMINARY_*` files are intact. They use a disjoint filename prefix from the 18 `FINAL_*` files, so the FINAL run could not overwrite them in place. The PRELIMINARY manifest still records the v1 development run (`DEVELOPMENT_V1`, v1 workbook, MD5 `4110465a13203019171ff2b3e4d6bb8e`, 898 rows / 47 predictors / 71 CoCs) and every PRELIMINARY file's mtime predates the FINAL run timestamp 2026-07-24T21:24:37Z. PRELIMINARY also ran without the log-target sensitivity, so no PRELIMINARY artefact was reused under a FINAL label.

## 11. Cross-file consistency

- The six model names are identical across predictions, per-fold metrics, pooled metrics, residual diagnostics, state performance, and both log-target files; the coefficient and lambda files cover exactly the four penalized specs.
- Lambda-rule labels are used consistently (`min`/`1se` for penalized models, `none` for the OLS baseline); coefficients exist only for `min`/`1se`.
- The fold → validation-year mapping is identical in fold definitions, predictions, per-fold metrics, lambda choices and smearing factors.
- Row counts reconcile: 4995 prediction rows = 555 × 7 pooled-scale series + 347×2 CA + 208×2 FL. Every scored CoC-year appears exactly once per model × rule; no missing predictions.
- Target transformations are labelled unambiguously (`pooled_all_folds` vs `pooled_all_folds_LOGTARGET`); the raw-vs-log and lambda.min-vs-1se comparison tables reproduce from the two metric files, and their difference columns are arithmetically correct.
- `FINAL_model_summary.xlsx` carries the 11 expected sheets and its `metrics_overall` sheet matches the CSV.
- `FINAL_analysis_statements.md` agrees with the manifest on row count, CoC count, MD5 and the eight validation years.

## 12. Warnings, in priority order

Each item states the property that could **not** be confirmed as written, what was observed instead, and what it constrains.

1. **Check 6.7 — not confirmed: Log-target shift constant is derived from the full column, not training rows only**
   - Observed: min(dat[[target_col]]) over all 887 rows = 4.83 > 0, so shift = 0 in every fold
   - Implication: No numerical effect in this run (shift is identically 0); a constant this small is not a leakage pathway, but it is the one preprocessing quantity read from the full column.
2. **Check 10.3 — not confirmed: Same model also has the lowest pooled MAE among unified models**
   - Observed: pooled_lasso / 1se (MAE 9.8050 vs claimed model 10.1413)
   - Implication: MAE ranks the claimed model behind three other unified variants; the 'best' claim holds on squared-error criteria only.
3. **Check 10.6 — not confirmed: Qualifier 'unified' is load-bearing: the two-state separate LASSO scores better overall and must not be called second-best without it**
   - Observed: separate_state_lasso best RMSE 13.9020 / R2 0.6745 vs unified best RMSE 14.6922 / R2 0.6364
   - Implication: The claim is only true when restricted to unified models; stated without that restriction it is false.
4. **Check 11.5 — not confirmed: The state-and-time baseline's positive pooled R2 is backed by non-negative within-state R2**
   - Observed: CA -0.1257; FL -0.0723
   - Implication: The baseline's pooled R2 comes entirely from the CA/FL level gap; within state it is worse than each state's own mean. Any reading of pooled R2 as within-state explanatory power is unsupported.
5. **Check 11.6 — not confirmed: The claimed best unified model is also the best unified model within each state**
   - Observed: CA best unified = pooled_lasso_state_interactions/min (16.7508) vs claimed 16.7508; FL best unified = pooled_lasso/1se (8.4715) vs claimed 10.3863
   - Implication: Within Florida the claimed model is the weakest of the four pooled LASSO variants; its overall win is carried by California, which supplies 63% of scored rows.
6. **Check 13.2 — not confirmed: No predictor selected in >=50% of folds by the headline model belongs to a |r|>=0.80 EDA pair**
   - Observed: 3 of 16 distinct predictors (from 23 frequently selected terms incl. :FL interactions) are members of a highly correlated pair: coc_population_growth_rate_pct, coc_real_gdp_quantity_index, coc_permits_value_per_1000_housing_units_2025_usd
   - Implication: LASSO picks one member of a correlated pair near-arbitrarily; the selected member must not be reported as the operative variable.
7. **Check 13.4 — not confirmed: No always-selected (100% of folds) predictor is a correlated-pair member**
   - Observed: coc_population_growth_rate_pct, coc_real_gdp_quantity_index
   - Implication: These carry the headline model's most stable signal yet each shares >=80% correlation with another predictor, so the attribution between cluster members is not identified.

None of these is a computational error. Each is a constraint on how the results may be worded.

## Scope of this audit

This audit recomputes exported quantities, reconciles files against each other and against the input workbook, and reviews the modeling source for leakage-critical construction. It does **not** refit any model, so it cannot independently confirm the numerical value of a fitted coefficient or a tuned lambda; those are verified for internal consistency and for structural correctness of the procedure that produced them. Data provenance upstream of `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` is outside this audit's scope and is covered by `CHANGELOG_v1_to_v2.md`.

All findings concern predictive association in a two-state, time-ordered panel. Nothing in the audited outputs supports a causal reading.
