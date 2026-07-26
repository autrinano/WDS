# EDA findings — CA/FL homelessness LASSO input (V1)

_Generated 2026-07-24 16:37 from `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx` (sheet `LASSO Model Data`)._

> **DEVELOPMENT OUTPUT (V1) — NOT FINAL.** These results were produced 
> against the interim v1 workbook while the v2 model input is being 
> built by another session. Re-run against 
> `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` to produce the final `outputs/eda_v2/`.

All statements below describe **associations only**. Nothing here 
identifies a causal effect: two states over a short, strongly 
time-ordered panel cannot support causal claims.

## 1. Data quality

- Dimensions: **898 rows x 56 columns** (6 identifiers, 2 controls, 47 numeric predictors).
- States: California, Florida.
- Predictor years: 2011-2024. Target years: 2012-2025.
- CoCs: 71. Duplicate CoC-years: **0**.
- Columns with any missing values: 0 of 56. Columns with infinities: 0.
- Target range: **4.83 to 165.09** per 10k (median 24.39).
- No target rows for target_year 2021 (COVID-disrupted PIT excluded as target, as designed).
- CoC geography: 102 rows flagged as containing a split county 
  (`coc_contains_split_county_flag`). FY2024 CoC boundaries are applied 
  retrospectively, so historical CoC mergers/splits remain a source of 
  measurement error and are kept visible, not corrected.

## 2. Target distribution and log-target sensitivity

- Raw target skewness: **1.74**; log-target skewness: 0.24.
- A log-target sensitivity model is **WARRANTED**.
  The raw target is right-skewed (skew > 1) and the log transform 
  materially reduces skewness, so a log-target LASSO run is a reasonable 
  sensitivity check alongside the primary rate model.

## 3. California vs Florida target trends

- The **unweighted** mean next-year homeless rate by state and year 
  (a simple average across CoCs, **not** population-weighted) is tabulated 
  in `tables/state_target_trends_v1.csv` alongside the CoC median and CoC count.
- The two states' unweighted CoC-mean trajectories are plotted in 
  `plots/03_ca_fl_target_trends_v1.png`; the persistent level gap between 
  California and Florida is descriptive of the divergence the study examines. Because 
  the mean is unweighted, it reflects the CoC-rate distribution rather 
  than a statewide population rate.

## 4. CoC-level target spread over time

- `plots/04_coc_target_boxplots_by_state_v1.png` shows the within-state 
  spread of CoC rates each year. Widening or narrowing boxes indicate 
  changing dispersion across CoCs, described here without causal claim.

## 5. Predictor distributions and extreme observations

- Distribution small-multiples: `plots/05_predictor_distributions_p*_v1.png`.
- `tables/extreme_observations_v1.csv` contains **614 row-variable flags** 
  (robust |z| > 5 via median/MAD). Each flag is one (row, predictor) cell, 
  **not** a distinct observation: the same row can be flagged on several 
  predictors. Those flags cover **455 distinct CoC-year rows** across **17 
  predictors**. State-level predictors in particular flag many rows at once 
  because one state-year value is repeated across all of that state's CoCs.
- These cells are **flagged, not removed or winsorized** — per project policy 
  they must be checked against source files, since real recessions and policy 
  shocks can look statistically extreme in a small panel.

## 6. Predictor trends over time by state

- `plots/06_predictor_trends_p*_v1.png` show each predictor's state-mean 
  trajectory. State-level predictors (`state_*`) move identically for all 
  CoCs within a state; CoC-level predictors (`coc_*`) are state means of 
  varying CoC values.

## 7. Predictor correlation structure

- Clustered heatmap: `plots/07_predictor_correlation_heatmap_v1.png`; full 
  matrix in `tables/predictor_correlation_matrix_v1.csv`.

## 8. Highly correlated predictor pairs

- **66** predictor pairs have |r| >= 0.80 (`tables/highly_correlated_pairs_v1.csv`).
  - state_real_median_home_price_2025_usd ~ state_home_price_to_income_ratio: r = 0.99
  - state_serious_mental_illness_rate ~ state_pct_age_65plus: r = 0.98
  - state_avg_in_state_tuition ~ state_real_median_home_price_2025_usd: r = 0.98
  - state_labor_force_participation ~ state_serious_mental_illness_rate: r = -0.97
  - state_avg_in_state_tuition ~ state_home_price_to_income_ratio: r = 0.96
  - state_average_student_debt_per_borrower ~ state_pct_age_18_24: r = -0.96
  - state_avg_in_state_tuition ~ state_real_median_rent_2025_usd: r = 0.96
  - state_pct_age_65plus ~ state_avg_household_size: r = -0.95
  LASSO tolerates collinearity but selection among correlated predictors 
  is unstable; interpret any single selected member cautiously.

## 9. Constant / near-zero-variance predictors

- Constant predictors: **0**; near-zero-variance predictors: **0** 
  (`tables/constant_and_nzv_predictors_v1.csv`).
  These are reported for review; they are **not dropped** by this EDA.

## 10. Target vs key predictors

- `plots/10_target_vs_key_predictors_v1.png` (no fitted lines, per project 
  policy) and Spearman associations in 
  `tables/curated_target_associations_v1.csv`.
- Strongest curated monotone associations with the target (Spearman rho):
  - coc_hic_temporary_beds_per_10k: rho = 0.64 (n=898)
  - coc_permits_per_1000_housing_units: rho = -0.45 (n=898)
  - state_real_median_rent_2025_usd: rho = 0.42 (n=898)
  - coc_domestic_migration_rate_per_1000: rho = -0.41 (n=898)
  - state_rental_vacancy_rate: rho = -0.37 (n=898)
  - coc_hic_psh_beds_per_10k: rho = 0.30 (n=898)
  These are marginal associations only, unadjusted for state, time, or 
  other predictors.

## 11. Target-leakage / future-information check

- Full results: `tables/leakage_check_v1.csv` (16 checks; 0 FAIL, 0 REVIEW).
- Lag structure: predictor_year is matched to the following target year, so 
  same-year simultaneity between predictors and the outcome is structurally 
  reduced; the check confirms no row violates predictor_year < target_year 
  (unless flagged FAIL above).
- Population / rate-denominator predictors are flagged NOTE, not removed: 
  they use the predictor-year CoC population while the target uses the 
  next-year population, so mechanical overlap is limited but worth monitoring.

## What is ready now, and what waits for v2

- This run used the interim **v1** workbook. All plots and tables above 
  are reproducible and structurally complete, but the **numbers are 
  provisional**. Treat them as a pipeline check, not final EDA.
- The identical script produces `outputs/eda_v2/` once 
  `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` exists:
  `Rscript eda_lasso_input.R --input outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`.
- Waiting on v2: final target range, final predictor pool (v2 may add, 
  drop, or rename predictors), and therefore the final correlation, NZV, 
  extreme-observation, and leakage tables.

### Standing data-quality reminders kept visible

- **2021 PIT**: the COVID-disrupted 2021 count is excluded as a modeling 
  target; changes touching 2021 remain unreliable. Do not read 2021-adjacent 
  movements as real market change.
- **CoC geography**: FY2024 CoC boundaries are applied retrospectively. 
  Historical CoC mergers/splits are a measurement-error source; the 
  split-county flag is retained so this stays visible.
- **No causal claims**: every association above is unadjusted and descriptive.

