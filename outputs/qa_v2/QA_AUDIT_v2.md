# LASSO Model Input v2 - Independent QA Audit

- **Run date:** 2026-07-24 17:03:51
- **File validated:** `./outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`
- **v2 available:** yes
- **Rows x Columns:** 887 x 47
- **Usable complete-case rows:** 887
- **Result tally:** 17 PASS / 1 WARNING / 0 FAIL
- **Overall verdict:** **PASS WITH WARNINGS - v2 usable; review flagged items**

> This review is read-only. No dataset, build script, or central document was
> modified. Problems are reported to the dataset owner for repair; the reviewer
> does not fix the data.

## Check results

| # | Check | Category | Status | Evidence |
|---|-------|----------|--------|----------|
| 1 | worksheet_single_named | structure | **PASS** | Exactly one sheet named 'LASSO Model Data'. |
| 2 | unique_coc_year | identity | **PASS** | All 887 coc_number x predictor_year keys unique. |
| 3 | states_ca_fl_only | geography | **PASS** | Only California and Florida present, both represented. |
| 4 | year_coverage_2021 | coverage | **PASS** | Coverage consistent; disrupted 2021 excluded as target while retained as a predictor year. predictor_year 2011-2024; target_year 2012-2025; 2021-as-target rows=0; 2021-as-predictor rows=70; 2020-as-predictor rows=0; offset(t+1) holds=TRUE. |
| 5 | modeling_numeric | types | **PASS** | All 41 modeling columns (target/controls/predictors) numeric. |
| 6 | no_missing_inf_nan | completeness | **PASS** | No NA/NaN/Inf across 41 numeric modeling columns x 887 rows. |
| 7 | no_duplicate_columns | structure | **PASS** | No duplicated column names and no columns with identical content. |
| 8 | no_constant_nzv_predictors | variance | **PASS** | All 38 numeric predictors have adequate variation. |
| 9 | target_plausible | target | **PASS** | range [4.83, 165.09] per 10k; median 24.12; n_bad=0; out-of-range=0. |
| 10 | role_prefixes | documentation | **PASS** | Every non-identifier column carries a target_/control_/coc_/state_ role prefix. |
| 11 | header_comments | documentation | **PASS** | 47 header comments found (>= 47 columns); all carry a ROLE: tag. |
| 12 | no_leakage | leakage | **PASS** | No prohibited target/future-information field names and no predictor near-perfectly correlated with the target. |
| 13 | no_identifier_predictors | leakage | **PASS** | No identifier-like fields (fips/geoid/id/lat/lon/name/tract) among predictors. |
| 14 | min_usable_obs | sample | **PASS** | 887 usable complete-case observations (>= 850 required). |
| 15 | improvements_over_v1 | versioning | **WARN** | Improvement count outside the expected 5-10 band. vs v1: +4 columns (coc_permits_value_per_1000_housing_units_2025_usd, coc_real_gdp_quantity_index, coc_relative_home_price_index_2000_base, state_labor_force_participation_pct); -13 columns (state_homeless_funding_per_capita, state_labor_force_participation, state_substance_use_disorder_rate, state_serious_mental_illness_rate, state_uninsured_rate, state_average_student_debt_per_borrower, state_avg_in_state_tuition, state_pct_age_18_24); row delta -11 (v1=898, v2=887); estimated distinct improvements=18. |
| 16 | v1_v2_changes_documented | versioning | **PASS** | Change docs found (DECISION_LOG.md, DATA_SOURCES_AND_ASSUMPTIONS.md, DATA_LOG.md, CHANGELOG_v1_to_v2.md) and every added/removed column is named there. |
| 17 | sources_documented | documentation | **PASS** | 38 header comments carry SOURCE notes; DATA_SOURCES_AND_ASSUMPTIONS.md and variable_dictionary.csv present. |
| 18 | geo_mismatch_reported | geography | **PASS** | Coverage + FY2024 crosswalk present; 91 rows flagged as split-county (coc_contains_split_county_flag) so mismatches are traceable. |

## How to reproduce

```bash
Rscript validate_lasso_input_v2.R
```

Outputs are written to `outputs/qa_v2/`:

- `validation_results.csv` - machine-readable check table.
- `QA_AUDIT_v2.md` - this audit.

