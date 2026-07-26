# EDA findings — CA/FL homelessness LASSO input (V2)

_Generated 2026-07-24 17:03 from `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` (sheet `LASSO Model Data`)._

All statements below describe **associations only**. Nothing here 
identifies a causal effect: two states over a short, strongly 
time-ordered panel cannot support causal claims.

## 1. Data quality

- Dimensions: **887 rows x 47 columns** (6 identifiers, 2 controls, 38 numeric predictors).
- States: California, Florida.
- Predictor years: 2011-2024. Target years: 2012-2025.
- CoCs: 70. Duplicate CoC-years: **0**.
- Columns with any missing values: 0 of 47. Columns with infinities: 0.
- Target range: **4.83 to 165.09** per 10k (median 24.12).
- No target rows for target_year 2021 (COVID-disrupted PIT excluded as target, as designed).
- CoC geography: 91 rows flagged as containing a split county 
  (`coc_contains_split_county_flag`). FY2024 CoC boundaries are applied 
  retrospectively, so historical CoC mergers/splits remain a source of 
  measurement error and are kept visible, not corrected.

## 2. Target distribution and log-target sensitivity

- Raw target skewness: **1.77**; log-target skewness: 0.26.
- A log-target sensitivity model is **WARRANTED**.
  The raw target is right-skewed (skew > 1) and the log transform 
  materially reduces skewness, so a log-target LASSO run is a reasonable 
  sensitivity check alongside the primary rate model.

## 3. California vs Florida target trends

- The **unweighted** mean next-year homeless rate by state and year 
  (a simple average across CoCs, **not** population-weighted) is tabulated 
  in `tables/state_target_trends_v2.csv` alongside the CoC median and CoC count.
- The two states' unweighted CoC-mean trajectories are plotted in 
  `plots/03_ca_fl_target_trends_v2.png`; the persistent level gap between 
  California and Florida is descriptive of the divergence the study examines. Because 
  the mean is unweighted, it reflects the CoC-rate distribution rather 
  than a statewide population rate.

## 4. CoC-level target spread over time

- `plots/04_coc_target_boxplots_by_state_v2.png` shows the within-state 
  spread of CoC rates each year. Widening or narrowing boxes indicate 
  changing dispersion across CoCs, described here without causal claim.

## 5. Predictor distributions and extreme observations

- Distribution small-multiples: `plots/05_predictor_distributions_p*_v2.png`.
- `tables/extreme_observations_v2.csv` contains **406 row-variable flags** 
  (robust |z| > 5 via median/MAD). Each flag is one (row, predictor) cell, 
  **not** a distinct observation: the same row can be flagged on several 
  predictors. Those flags cover **286 distinct CoC-year rows** across **17 
  predictors**. State-level predictors in particular flag many rows at once 
  because one state-year value is repeated across all of that state's CoCs.
- These cells are **flagged, not removed or winsorized** — per project policy 
  they must be checked against source files, since real recessions and policy 
  shocks can look statistically extreme in a small panel.

## 6. Predictor trends over time by state

- `plots/06_predictor_trends_p*_v2.png` show each predictor's state-mean 
  trajectory. State-level predictors (`state_*`) move identically for all 
  CoCs within a state; CoC-level predictors (`coc_*`) are state means of 
  varying CoC values.

## 7. Predictor correlation structure

- Clustered heatmap: `plots/07_predictor_correlation_heatmap_v2.png`; full 
  matrix in `tables/predictor_correlation_matrix_v2.csv`.

## 8. Highly correlated predictor pairs

- **18** predictor pairs have |r| >= 0.80 (`tables/highly_correlated_pairs_v2.csv`).
  - state_tanf_max_benefit_3person ~ state_ssi_state_supplement: r = 0.95
  - coc_permits_per_1000_housing_units ~ coc_permits_value_per_1000_housing_units_2025_usd: r = 0.93
  - coc_poverty_all_pct ~ coc_poverty_child_pct: r = 0.92
  - state_tanf_max_benefit_3person ~ state_real_median_rent_2025_usd: r = 0.90
  - state_real_minimum_wage_2025_usd ~ state_tanf_max_benefit_3person: r = 0.90
  - state_real_minimum_wage_2025_usd ~ state_real_median_rent_2025_usd: r = 0.89
  - coc_domestic_migration_rate_per_1000 ~ coc_population_growth_rate_pct: r = 0.89
  - state_ssi_state_supplement ~ state_real_median_rent_2025_usd: r = 0.88
  LASSO tolerates collinearity but selection among correlated predictors 
  is unstable; interpret any single selected member cautiously.

## 9. Constant / near-zero-variance predictors

- Constant predictors: **0**; near-zero-variance predictors: **0** 
  (`tables/constant_and_nzv_predictors_v2.csv`).
  These are reported for review; they are **not dropped** by this EDA.

## 10. Target vs key predictors

- `plots/10_target_vs_key_predictors_v2.png` (no fitted lines, per project 
  policy) and Spearman associations in 
  `tables/curated_target_associations_v2.csv`.
- Strongest curated monotone associations with the target (Spearman rho):
  - coc_hic_temporary_beds_per_10k: rho = 0.67 (n=887)
  - state_real_median_rent_2025_usd: rho = 0.44 (n=887)
  - coc_permits_per_1000_housing_units: rho = -0.44 (n=887)
  - coc_domestic_migration_rate_per_1000: rho = -0.41 (n=887)
  - state_rental_vacancy_rate: rho = -0.39 (n=887)
  - coc_hic_psh_beds_per_10k: rho = 0.32 (n=887)
  These are marginal associations only, unadjusted for state, time, or 
  other predictors.

## 11. Target-leakage / future-information check

- Full results: `tables/leakage_check_v2.csv` (17 checks; 0 FAIL, 0 REVIEW).
- Lag structure: predictor_year is matched to the following target year, so 
  same-year simultaneity between predictors and the outcome is structurally 
  reduced; the check confirms no row violates predictor_year < target_year 
  (unless flagged FAIL above).
- Population / rate-denominator predictors are flagged NOTE, not removed: 
  they use the predictor-year CoC population while the target uses the 
  next-year population, so mechanical overlap is limited but worth monitoring.

## What is ready now, and what waits for v2

- This is the **final v2 EDA**. All twelve deliverables are populated 
  from `CA_FL_LASSO_MODEL_INPUT_v2.xlsx`.

### Standing data-quality reminders kept visible

- **2021 PIT**: the COVID-disrupted 2021 count is excluded as a modeling 
  target; changes touching 2021 remain unreliable. Do not read 2021-adjacent 
  movements as real market change.
- **CoC geography**: FY2024 CoC boundaries are applied retrospectively. 
  Historical CoC mergers/splits are a measurement-error source; the 
  split-county flag is retained so this stays visible.
- **No causal claims**: every association above is unadjusted and descriptive.

