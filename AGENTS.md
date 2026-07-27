# California–Florida Homelessness Factors Project

## Repository housekeeping (2026-07-27)

All project R scripts were moved from the repository root into `scripts/`
(paths below and in the rebuild instructions were updated accordingly; no
script logic changed, since every script resolves data/library paths from
the working directory, not from its own file location). The HW9 course
draft (`HW9_group.Rmd`, `HW9_group.html`) was moved to
`archive/coursework/` since it predates and is superseded by this project's
current reports. Untracked, gitignored build artifacts (`.DS_Store`,
`Rplots.pdf`, an Excel `~$` lock file, and the local `_r_libs/` package
cache) were deleted; `_r_libs/` will be recreated automatically the next
time a script installs its required packages.

`outputs/eda_v1/` (plots, tables, findings) was deleted: it was an interim
EDA run against the superseded v1 LASSO input, explicitly self-documented
in `scripts/eda_lasso_input.R` as a development-only output distinct from
the final `outputs/eda_v2/` deliverable, and not read by any other script
or audit check. By contrast, `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx`
(the v1 input itself) and `outputs/lasso_models/PRELIMINARY_*` were
deliberately kept: four current scripts still read the v1 workbook for
audit/reconciliation, and `outputs/lasso_audit/AUDIT_REPORT.md` (Check 14)
certifies that the PRELIMINARY files remain intact alongside FINAL as
proof the final run never overwrote or reused them. Do not delete either
without also revising that audit report.

## Project overview

The goal of the study is to explain why homelessness rates diverged between California and Florida from 2010 through 2025. The analysis examines whether differences in housing affordability, rental-market tightness, housing stock and new supply, economic conditions, policy, and homelessness-service capacity are associated with the different state trajectories.

The current work is preliminary exploratory data analysis. Its purpose is to establish the outcome divergence and identify plausible explanatory patterns for later modeling, not to make causal claims. The broad directional trends are expected to remain the same as sources and variables are refined, although exact values, sample sizes, and estimated relationships may change.

The unit of observation is one state-year. The processed panel contains 32 rows: California and Florida for each year from 2010 through 2025. `state_year` is the merge key used to align these housing variables with the team's homelessness, policy, funding, and demographic data.

## Main files

- `DSA_Group_10_updated.xlsx`: current team workbook, with the integrated 63-variable panel, variable dictionary, missingness table, and source notes.
- `DSA Group 10 - Sheet1.csv`: current machine-readable team panel (32 state-years × 63 variables).
- `scripts/clean_analysis_data.R`: validates the integrated data and builds cleaned, purpose-specific analysis panels without statistical imputation.
- `cleaned_data/cleaned_analysis_datasets.xlsx`: cleaned workbook with core, rent, eviction, audit, and validation sheets.
- `cleaned_data/`: CSV versions of the cleaned panels, cleaning audit, and validation results.
- `scripts/update_team_dataset.R`: integrates the verified housing panel, corrects deterministic fields, adds derived variables, and rebuilds the team workbook.
- `scripts/generate_project_chart_suite.R`: produces the curated chart suite and chart manifest.
- `PROJECT_DATA_AND_CHART_AUDIT.md`: audit of the original charts, missing-data decisions, new variables, and redesign.
- `charts/`: current 73-chart suite, including 22 curated/goal-aligned charts and 51 state-faceted factor scatterplots.
- `charts/chart_manifest.csv`: authoritative list of current chart files.
- `charts/scatterplot_inventory.csv`: variables included in the factor scatterplots and their usable sample sizes.
- `charts/scatterplot_exclusions.csv`: variables excluded from factor scatterplots and the reason for each exclusion.
- `charts/KEY_CHARTS.md`: goal-aligned guide to seven study-wide charts, four mechanism follow-ups, and the individual-variable appendix.
- `charts/key_chart_manifest.csv`: reproducible ordered list of those 11 charts.
- `housing_metrics_CA_FL_2010_2025.xlsx`: formatted Excel deliverable with the panel, metric guide, missingness summary, and raw-file index.
- `housing_metrics_CA_FL_2010_2025.csv`: machine-readable version of the processed panel.
- `scripts/build_housing_metrics.R`: reproducible R pipeline that downloads, cleans, combines, validates, and exports the housing data.
- `DATA_SOURCES_AND_ASSUMPTIONS.md`: authoritative definitions, source URLs, coverage, and limitations.
- `DECISION_LOG.md`: record of important data and modeling decisions.
- `raw_data/`: unmodified source downloads used by the R pipeline.
- `_r_libs/`: folder-local R packages used to build the workbook.
- `scripts/build_coc_lasso_panel.R`: builds the CoC-year homelessness outcome,
  county-to-CoC allocation crosswalk, and next-year LASSO candidate panels.
- `coc_analysis/coc_lasso_analysis_CA_FL_2010_2025.xlsx`: CoC outcome and
  modeling workbook with validation, coverage, dictionary, and source sheets.
- `coc_analysis/lasso_core_complete_panel.csv`: first complete-case,
  theory-driven panel for predicting the next year's homelessness rate.
- `coc_analysis/README.md`: authoritative CoC allocation and modeling notes.
- `scripts/build_expanded_lasso_input.R`: combines the curated CoC, county-derived,
  state-year, and official HUD HIC predictors into one leakage-safe model table.
- `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx`: primary one-sheet LASSO
  input (898 CoC-years, six identifiers, one target, two baseline controls,
  and 47 candidate predictors).
- `scripts/build_expanded_lasso_input_v2.R`: audits every inherited/provisional
  predictor from `scripts/build_expanded_lasso_input.R`, drops variables that could
  not be verified to an official or fully documented source, and adds
  three new local (CoC-level) predictors. Does not overwrite v1.
- `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`: improved one-sheet
  LASSO input (887 CoC-years across 70 CoCs, six identifiers, one target, two
  baseline controls, and 38 candidate predictors). No *definitive* model had
  been fitted on this v2 workbook at the time of its construction; a
  preliminary pipeline-development LASSO run was fitted on v1 during earlier
  development work (so it is not the case that no LASSO was ever fitted on v1).
- `CHANGELOG_v1_to_v2.md`: per-variable audit disposition, the local
  housing-affordability sources investigated and rejected, the CoC
  boundary-matching diagnostic, and the full v1-to-v2 rationale.

The integrated team dataset adds 16 documented variables, including inflation-adjusted dollar measures, homelessness composition and change measures, normalized permit and bed-capacity measures, housing affordability ratios, and a 2021 PIT data-quality flag.

## Housing metrics

The panel includes:

- median gross rent;
- median home sale price;
- median rent as a percentage of household income;
- rental vacancy rate;
- homeownership rate;
- housing units per capita;
- new housing units authorized by building permits;
- annual housing-supply growth rate;
- eviction filing rate; and
- a reserved foreclosure-rate column.

The foreclosure-rate column is currently blank because no free, comparable state-year series covering 2010–2025 has been verified. Do not substitute mortgage delinquency for foreclosure without changing the variable name and documenting the decision.

## Data conventions and limitations

- Never fabricate, silently interpolate, or replace missing observations with zero.
- Yellow Excel cells represent unavailable values, not zero values.
- Dollar variables are nominal unless a new inflation-adjusted variable is explicitly created.
- `median_home_price` is Zillow's median sale-price measure, not the ACS value of all owner-occupied homes.
- `rent_as_pct_income` is ACS B25071's median percentage and is available for 2019–2024.
- `rent_burden_share` is a separate Eviction Lab renter-household share for 2010–2018. Never coalesce it with `rent_as_pct_income`.
- `eviction_filing_rate` is Eviction Lab's modeled number of filings per 100 renter homes and is available through 2018.
- Housing units per capita is complete for 2010–2025. It uses Census 2019-vintage estimates through 2019 and 2025-vintage estimates beginning in 2020.
- Keep 2020 housing-supply growth missing because calculating it would cross the Census vintage boundary. The 2010 growth value is also missing because there is no prior year in the panel.
- Several Eviction Lab rent and burden covariates repeat across years because benchmark values were carried forward. Do not describe this as evidence of no market change.
- The 2021 PIT count is not directly comparable with surrounding years because COVID disrupted enumeration. Derived ratios using the PIT denominator are suppressed for 2021, and changes involving 2021 are suppressed for both 2021 and 2022.
- The primary LASSO input predicts next-year CoC homelessness per 10,000
  estimated residents. Modeling code should read only `LASSO Model Data`,
  exclude the six identifier columns from the design matrix, and use the two
  `control_` columns as unpenalized controls.
- HIC temporary-bed and PSH-bed rates use official predictor-year HUD CoC
  counts divided by the estimated CoC population. Do not replace unmatched HIC
  values with zero.
- Original non-housing variables inherited from the team spreadsheet remain in the deliverable, but many lack source documentation in this folder. The workbook dictionary identifies them as `source verification needed`.
- A reproducible derivation does not verify an undocumented component input. Treat `derivation documented; verify component sources` as provisional until every component source is recorded.
- The v2 LASSO input (`CA_FL_LASSO_MODEL_INPUT_v2.xlsx`) resolves this for the CoC-level model: every `source verification needed` state variable was individually audited and either reclassified as documented (citing `DATA_LOG.md`), rebuilt from a verified official series, or dropped. See `CHANGELOG_v1_to_v2.md` for the per-variable disposition. Do not re-introduce a dropped variable into a future model input without a newly verified source.
- A CoC-level HUD funding predictor (transaction-level USAspending CFDA 14.267 extract, built by a parallel effort) is complete but intentionally excluded from v2: coverage starts in 2013, not 2010, and recipient location is not equivalent to CoC service geography. See `CHANGELOG_v1_to_v2.md` section 3.
- HUD PIT counts are observed at CoC geography, not county geography. The CoC
  derivative uses FY2024 boundaries and ACS 2024 tract-population shares to
  allocate county predictors. Treat its historical denominators and subcounty
  predictors as documented estimates, not directly observed CoC values.

## Instructions for future work

1. Use R for project data-acquisition and processing scripts.
2. Preserve files in `raw_data/`; do not manually edit source downloads.
3. Make transformations reproducible in `scripts/build_housing_metrics.R` rather than editing only the Excel workbook.
4. When adding or changing a metric, update all of the following:
   - `DATA_SOURCES_AND_ASSUMPTIONS.md`;
   - the workbook's `Metric Guide` and `Missingness` sheets through the R script;
   - `DECISION_LOG.md`; and
   - this file if the project conventions change.
5. Retain one row per state-year and verify that `state` plus `year` remains unique.
6. Cite the original data producer even when a series is downloaded through FRED or another distributor.
7. Do not mix definitions, denominators, geographic levels, or data vintages without a clearly documented reason.
8. Do not use `pit_count_caution_flag` as a substantive predictor; it is an analysis warning.
9. Clean in layers: preserve raw files, standardize identifiers/types/units, validate domains and identities, then create analysis-specific data.
10. Do not automatically delete or winsorize outliers. Check them against source files and document the resolution.
11. Fit imputation, scaling, or other learned preprocessing using training years only.

## Rebuilding and validation

Run from the workspace root:

```r
setwd("Final Project")
source("scripts/build_housing_metrics.R")
source("scripts/update_team_dataset.R")
source("scripts/clean_analysis_data.R")
source("scripts/generate_project_chart_suite.R")
source("scripts/build_coc_lasso_panel.R")
```

After rebuilding, confirm:

- 32 processed rows and no duplicated state-years;
- years span 2010–2025 for both states;
- housing units per capita has 32 available observations;
- 2010 and 2020 housing-supply growth remain missing by design;
- the Excel workbook reopens with four sheets; and
- newly downloaded raw files appear in the workbook's raw-file index.
- the team panel has 32 rows, 63 columns, and no duplicated state-years;
- `housing_units_per_capita` and `population_density` have 32 available observations;
- the updated workbook has four sheets: `Data`, `Variable Dictionary`, `Missingness`, and `Source Notes`; and
- `charts/chart_manifest.csv` lists 73 current PNG charts and every listed file exists.
- `charts/scatterplot_inventory.csv` lists 51 eligible factor scatterplots.
- `charts/key_chart_manifest.csv` lists seven study-wide and four mechanism follow-up charts.
- no legacy chart archive or duplicate root-level chart PNG remains.
- every check in `cleaned_data/validation_checks.csv` passes;
- `cleaned_data/analysis_panel_core.csv` has 30 non-2021 rows and no missing values; and
- the rent-to-income, rent-burden, and eviction panels keep their definitions and coverage periods separate.
- all checks in `coc_analysis/validation_checks.csv` pass;
- the CoC workbook contains ten sheets, including a README overview; and
- the core LASSO panel contains no missing target or core-predictor fields and
  excludes 2021 as a target.
- `scripts/build_expanded_lasso_input_v2.R` reports that all of its own validation
  checks passed, including at least 850 modeling rows and zero non-finite
  (NA/NaN/Inf) values across the target, controls, and predictors.

## Modeling guidance

The panel is small and strongly ordered in time. Avoid random row-level train/test splits because they leak temporal structure. Prefer time-based or rolling-origin validation, compare same-year and lagged predictors, establish a simple state-and-time baseline, and treat feature-importance rankings cautiously. Do not infer causal effects from same-year associations alone.

For the CoC model, predict `target_homeless_rate_per_10k` using prior-year
predictors. Keep state and time controls in the baseline, use rolling-origin
validation, fit scaling and any imputation inside each training window, and
report sensitivity checks for split counties and stable CoCs.

## Team ownership

Each team member should be able to explain the unit of observation, the meaning and denominator of every metric they use, the reason for major missing-data gaps, the Census vintage boundary, and the validation strategy selected for modeling.
