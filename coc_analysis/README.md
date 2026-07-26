# California–Florida CoC homelessness and LASSO candidate panel

## Purpose

This folder adds an observed homelessness outcome to the county-factor work
without pretending that HUD Continuum-of-Care (CoC) counts are county counts.
The primary modeling target is:

`target_homeless_rate_per_10k`

This is the **next year's** HUD Point-in-Time (PIT) homelessness count divided
by the next year's estimated CoC population, multiplied by 10,000. Predictors
come from the preceding year.

## Main files

- `coc_lasso_analysis_CA_FL_2010_2025.xlsx`: multi-sheet review workbook.
  Its first sheet summarizes the target, timing, geography, sample sizes, and
  principal limitation.
- `coc_year_homelessness_outcomes_CA_FL_2010_2025.csv`: observed HUD PIT
  outcomes and the estimated rate denominator.
- `coc_year_allocated_predictors_CA_FL_2010_2025.csv`: county predictors
  allocated to FY2024 CoC geography.
- `lasso_next_year_candidate_panel.csv`: predictor-year rows matched to the
  next year's target, with the disrupted 2021 target excluded.
- `lasso_core_complete_panel.csv`: theory-driven normalized predictors with
  complete model fields; intended as the first LASSO specification.
- `county_to_coc_population_crosswalk_FY2024.csv`: reproducible allocation
  shares and geography-quality fields.
- `validation_checks.csv`: structural and identity checks.
- `coverage_summary.csv`: variable coverage for each derived dataset.
- `variable_dictionary.csv` and `source_notes.csv`: definitions and provenance.
- `raw_file_index.csv`: source-file sizes, timestamps, and MD5 hashes.
- `../build_coc_lasso_panel.R`: reproducible build.
- `../build_expanded_lasso_input_v2.R`: builds an improved one-sheet LASSO
  input (`../outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`, 887
  rows across 70 CoCs, 38 predictors) on top of this folder's `lasso_next_year_candidate_panel.csv`.
  It audits every inherited state-year predictor, adds three new local
  (CoC-level) predictors, and does not overwrite the original v1 workbook.
  See `../CHANGELOG_v1_to_v2.md` for the full rationale.

## Geography method

HUD publishes PIT counts by CoC, not county. FY2024 HUD CoC boundaries are
overlaid with 2024 Census tracts. Each tract is assigned to the CoC containing
its point-on-surface. Tracts falling just outside the published polygon are
assigned to the nearest CoC in the same state and retain a fallback count and
maximum-distance audit field.

ACS 2024 five-year tract population is summed by county and CoC. The resulting
within-county shares are used to allocate annual county totals and population
to CoCs. County rates and index measures are aggregated using allocated
population weights. A weighted average of county medians is not itself a true
CoC median; such variables remain approximations.

This is a defensible exploratory bridge, not an observed historical
county-to-CoC crosswalk. FY2024 boundaries are applied retrospectively, while
CoC boundaries and identifiers changed during 2010–2025. Historical CoCs that
do not exist in the FY2024 boundary file retain their observed PIT counts but
have no estimated denominator or allocated predictors.

## Modeling rules

1. Predict the rate, not the raw total. Otherwise LASSO mostly learns region
   size.
2. Use predictors from year `t` to predict the PIT rate in year `t + 1`.
3. Do not use PIT components, the PIT warning flag, target-derived ratios, or
   future-year population as predictors.
4. Exclude 2021 as a target because COVID disrupted unsheltered enumeration.
5. Use rolling-origin or forward-chaining validation. Never randomly split
   county/CoC-year rows.
6. Fit scaling, missing-data handling, and feature selection on each training
   window only.
7. Keep state and time controls in the model; consider leaving them
   unpenalized in `glmnet`.
8. Report sensitivity checks for raw counts with a population offset/control,
   stable CoCs only, unsheltered outcomes, and split-county exclusions.

## Rebuild

From the workspace root:

```r
source("build_coc_lasso_panel.R")
```

The first build uses LibreOffice once to convert HUD's XLSB workbook and saves
a selected machine-readable cache. Later builds read that cache directly.

The core panel includes unpenalized-control candidates (`state_florida` and
`time_index`) plus normalized supply, migration, poverty, real-income,
homeownership, housing-burden, inequality, HPI-growth, real-GDP, minimum-wage,
and Medicaid-expansion predictors. The broader candidate panel remains
available for sensitivity models and training-fold-only preprocessing.

## Interpretation

PIT is a one-night estimate, not the number of people experiencing homelessness
during an entire year. The panel supports predictive and associational
analysis; it does not identify causal effects.

## Three geographic stages and exclusions

The CoC geography passes through three stages that must not be conflated
(reproduced by `../diagnose_coc_boundaries_v2.R`; see
`../outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md` and
`excluded_model_rows_by_reason.csv`):

1. **FY2024 crosswalk — 71 CoCs.** The reference geography in
   `county_to_coc_population_crosswalk_FY2024.csv`.
2. **Boundary-matched candidate panel — 71 CoCs (974 rows).**
   `lasso_next_year_candidate_panel.csv`.
3. **Final v2 complete-case workbook — 70 CoCs (887 rows).**
   `../outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`.

Rows are lost at two structurally different transitions:

- **Boundary mismatch (stage 1 → 2).** Of the 72 distinct historical CoC
  codes observed in HUD's raw PIT history for California and Florida,
  2010-2025, 71 have an FY2024-boundary population denominator. Only
  `CA-528` (Del Norte County CoC) does not; it retains its 3 observed
  PIT-year rows (2010-2012, per the project convention above) but has no
  estimated population or allocated predictors, so it cannot enter a
  modeling panel. The HIC-only codes `CA-605`, `CA-610`, `CA-615`, and
  `FL-516` are also absent from FY2024 but cost zero model rows because
  they never appear in PIT.
- **Predictor-coverage exclusion (stage 2 → 3).** `FL-518` is fully
  boundary-matched (it is in the FY2024 set and is a split-county CoC) but
  is dropped from the final v2 workbook because the required predictor
  `coc_relative_home_price_index_2000_base` (FHFA local home-price index)
  has no usable value for it — its member counties never reach the 40%
  weighted-coverage floor. It supplies 14 candidate-panel rows, 11 of which
  were in the v1 complete panel, so requiring the FHFA index removes those
  11 rows (898 → 887) and takes the workbook from 71 to 70 CoCs. This is a
  predictor-coverage exclusion, **not** a boundary mismatch.

See `../CHANGELOG_v1_to_v2.md` sections 2 and 5.
