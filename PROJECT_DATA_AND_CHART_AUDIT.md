# Team data and chart audit

## Goal of the study

The study seeks to explain why homelessness rates diverged between California and Florida from 2010 through 2025. The working mechanisms are differences in housing affordability, rental-market tightness, housing stock and new supply, economic conditions, policy, and homelessness-service capacity.

This is preliminary EDA. It establishes the divergence and identifies candidate explanations for later time-aware modeling. The broad directional patterns are expected to remain stable as the data are refined, but exact values and associations may change. None of the preliminary charts establishes causation.

## Scope

This audit covers the California–Florida state-year panel for 2010–2025, the integrated team spreadsheet, and the project chart suite. The unit of observation is one state-year, giving 32 rows. The current team dataset has 63 variables: 43 original or standardized fields, 4 integrated housing fields not present in the original sheet, and 16 added analysis variables. The all-missing `foreclosure_rate` field is retained so the requested metric and its unresolved coverage gap remain explicit.

## What changed in the data

`update_team_dataset.R` rebuilds the integrated dataset from a preserved copy of the original team CSV. It replaces stale housing fields with the verified values in `housing_metrics_CA_FL_2010_2025.csv`, recomputes deterministic fields, joins annual CPI-U, and adds analysis-ready variables.

The 16 added variables are:

| Variable | Purpose |
|---|---|
| `cpi_u` | Annual average U.S. CPI-U used for inflation adjustment |
| `unsheltered_share_pct` | Unsheltered PIT count as a percentage of the total |
| `homeless_rate_change_per_10k` | Year-over-year change in the homelessness rate |
| `pit_count_caution_flag` | Marks the COVID-disrupted 2021 PIT count |
| `total_beds_per_10k` | Shelter plus permanent supportive housing beds per 10,000 residents |
| `beds_per_100_homeless` | Total recorded beds per 100 people in the PIT count |
| `funding_per_homeless_person` | Recorded state funding divided by the PIT count |
| `estimated_housing_units` | Housing-unit estimate implied by the documented population ratio |
| `permits_per_1000_housing_units` | Authorized units normalized by the housing stock |
| `home_price_to_income_ratio` | Median sale price divided by median household income |
| `real_median_rent_2025_usd` | Median rent in constant 2025 dollars |
| `real_median_home_price_2025_usd` | Median sale price in constant 2025 dollars |
| `real_personal_income_per_capita_2025_usd` | Per-capita personal income in constant 2025 dollars |
| `real_median_household_income_2025_usd` | Median household income in constant 2025 dollars |
| `real_minimum_wage_2025_usd` | Minimum wage in constant 2025 dollars |
| `real_home_price_growth_pct` | Annual growth in the inflation-adjusted median sale price |

Housing units per capita is now available for every state-year. Population density is recomputed for every row using Census land-area constants. Population growth is recomputed from the population series; it remains unavailable only for each state's first panel year because no 2009 value is present.

## Missing-data policy

Missing values have different meanings, so there is no single appropriate imputation method.

1. **Correct avoidable gaps from verified sources.** Stale housing fields were replaced from the documented housing panel.
2. **Use deterministic derivations where possible.** Rates and real-dollar fields are calculated only from observed inputs. This is not statistical imputation.
3. **Keep structurally unavailable values missing.** Examples include 2010 growth without a prior year, 2020 housing-supply growth across a Census vintage boundary, post-2018 eviction filing rates, and ACS estimates not yet published for 2025.
4. **Do not fill missing values with zero.** Zero is a substantive measurement, not a missing-data code.
5. **Do not outcome-impute predictors.** Predicting eviction or housing values from homelessness would create outcome leakage and false precision.
6. **Treat 2021 PIT data separately.** COVID disrupted the count. PIT-denominator ratios are suppressed in 2021, and changes in the homelessness rate involving 2021 are suppressed for 2021 and 2022. Independent measures, such as home-price growth, are not suppressed solely because of the PIT disruption.

For modeling, start with variables that have strong coverage and a clear source. Report the exact analysis sample for every model. If a sensitivity analysis uses imputation, fit it inside each training fold, add missingness indicators when appropriate, and compare it with a complete-case result. With only 32 rows, any model-based imputation should be treated as exploratory.

## Assumptions to disclose in the report

The project report should state the following assumptions rather than leaving them implicit:

- The analysis uses state-year observations and treats California and Florida as comparable geographic units despite their different population sizes and policy environments.
- The annual PIT count is a one-night enumeration and is not a complete count of every person who experienced homelessness during a year.
- The 2021 PIT observation is disrupted by COVID. PIT-denominator ratios are not calculated for 2021, and homelessness changes involving 2021 are not calculated.
- Zillow median sale price is used as the home-price measure. It is not the ACS value of all owner-occupied housing.
- ACS median rent-to-income and Eviction Lab renter burden share are distinct measures and are analyzed in separate panels.
- Eviction filing rate is a modeled filing measure per 100 renter homes and is not a completed-eviction rate.
- Housing units per capita combines two Census estimate vintages. Ratios stay within vintage, and 2020 supply growth is left missing rather than crossing the boundary.
- Building permits measure authorized units and do not guarantee that housing was started or completed.
- Constant-dollar variables use the annual national CPI-U average with 2025 as the reference year.
- State land area is fixed; population density changes only through the population numerator.
- Total beds includes the two bed categories present in the team sheet, not necessarily the entire homelessness response system.
- Original team variables without a recorded source remain provisional even when a derived formula based on them is documented.
- Charts and models show descriptive associations. With two states, 16 years, serial dependence, and shared trends, they do not identify causal effects.

## Current cleaning audit

The July 23, 2026 validation found:

- 32 rows and 63 columns;
- one unique row for every California and Florida year from 2010 through 2025;
- no duplicated rows or duplicated state-years;
- no infinite numeric values;
- no mismatch between total homelessness and sheltered plus unsheltered counts;
- complete housing-units-per-capita and population-density fields;
- 32 missing foreclosure observations, 14 missing eviction observations, 2 missing median-rent observations, 20 missing ACS rent-to-income observations, and 14 missing Eviction Lab rent-burden-share observations; and
- remaining missing derived values that correctly inherit an unavailable input or the 2021 PIT suppression.

These checks establish structural consistency, not source accuracy. Source verification remains necessary.

## Recommended cleaning workflow

1. **Freeze the raw layer.** Never edit files in `raw_data/`. Rebuild the processed CSV and workbook from scripts.
2. **Standardize identifiers.** Trim whitespace, use exactly `California` and `Florida`, parse year as an integer, and require a unique state-year key.
3. **Standardize missing values.** Convert empty strings and explicit missing codes to `NA`. Do not convert missing values to zero.
4. **Standardize types and units.** Store counts and dollars as numeric values without display symbols; keep rates in clearly documented percent or per-capita units.
5. **Check domains.** Require nonnegative counts and prices, percentage shares between 0 and 100 when appropriate, positive population and housing stock, and binary policy flags in `{0,1}`.
6. **Check identities and denominators.** Confirm total homelessness equals sheltered plus unsheltered counts and recalculate normalized variables from their documented components.
7. **Investigate outliers against raw sources.** Flag unusual year-to-year movements, but do not automatically delete or winsorize them. Recessions, policy changes, and the pandemic may create real extremes.
8. **Avoid redundant predictors.** Choose nominal or real dollars, totals or normalized rates, and totals or components based on the research question. Do not include deterministic versions together in the same model.
9. **Create analysis-specific datasets.** Maintain one broad descriptive panel and a smaller modeling panel containing only variables with defensible coverage and provenance.
10. **Prevent preprocessing leakage.** Estimate scaling or imputation parameters using training years only, then apply those fixed parameters to later validation/test years.

## Missing-value treatment by variable

| Variables or gap | Recommended primary treatment | Optional sensitivity analysis |
|---|---|---|
| `foreclosure_rate` (32 missing) | Exclude from charts and models; report that no comparable open series was verified | Add only after obtaining a consistent ATTOM/CoreLogic or official series |
| `eviction_filing_rate` after 2018 | Use 2010–2018 only for eviction-specific descriptive analysis; omit from full-period models | Fit a separate early-period model; do not impute from homelessness |
| `median_rent` and derived fields | Use observed values through 2024; exclude 2025 from rent-specific analysis | Add 2025 only when an official consistent estimate is available |
| `rent_as_pct_income` | Use the separate 2019–2024 ACS B25071 panel | Do not combine with Eviction Lab burden share |
| `rent_burden_share` | Use the separate 2010–2018 Eviction Lab panel | Do not combine with ACS B25071 |
| 2025 ACS-derived income/demographic gaps | Keep missing until an official estimate is available | Restrict analysis to 2010–2024 or the latest common year |
| First-year growth values | Leave missing because there is no prior panel year | Obtain 2009 source data and recompute if the project needs 2010 growth |
| 2020 housing-supply growth | Leave missing because it crosses Census vintages | Rebuild the full series from one consistent vintage if available |
| 2021 PIT-denominator ratios and 2021–2022 homelessness changes | Keep suppressed and use the caution flag | Present a separately labeled analysis only if a verified alternative 2021 count is found |
| Small isolated predictor gaps in a future model | Prefer a coverage-based feature subset because the sample has only 32 rows | Median or time-aware imputation fitted inside each training fold, with a missingness indicator and comparison to complete cases |

Do not use simple global mean imputation: it erases state differences and time trends. Do not use forward filling for policy, eviction, price, or outcome fields unless the variable definition explicitly means a policy remains in force. Do not use the homelessness outcome to impute a predictor.

## Recommended analysis panel

For the main full-period analysis, prioritize well-sourced variables with near-complete coverage, such as the homelessness rate, real median home price, rental vacancy, homeownership, housing units per capita, permits per 1,000 housing units, and total beds per 10,000 residents after their component sources are verified. Use state and time terms and a time-based validation design.

Treat eviction, foreclosure, and incomplete ACS variables as secondary analyses rather than forcing them into the main model. Because there are only 32 rows, a compact, theory-driven predictor set is more defensible than aggressive imputation followed by a high-dimensional model.

## Highest-priority remaining data work

- Verify and document the original source for every non-housing variable labeled `source verification needed` in the workbook dictionary.
- Seek updated eviction filing data directly from state court systems or Eviction Lab before extending the series beyond 2018. Do not splice incompatible definitions without an overlap check.
- Add 2025 rent and burden observations only when a consistent official estimate becomes available.
- Add foreclosure data only if the team obtains a comparable state-year measure from a source such as ATTOM or CoreLogic. Mortgage delinquency is not a valid silent substitute.
- Refresh 2025 ACS-based demographic and income fields when an official release becomes available.

## Problems in the original chart suite

The earlier suite generated a scatterplot of nearly every numeric variable against the homelessness rate, several two-state boxplots, and one 43-variable raw correlation heatmap. That approach created five problems:

- California–Florida level differences and common time trends could look like substantive relationships.
- Raw totals were often compared across states with very different populations.
- Fitted lines encouraged causal interpretations from 32 observational, time-ordered rows.
- Boxplots discarded the most important structure: change over time.
- The full correlation heatmap was unreadable and included mechanical relationships between a total and its component counts.

The original chart archive and duplicate root-level PNG files were removed after the updated suite was verified. `charts/chart_manifest.csv` is the current source of truth.

## Current chart design

`generate_project_chart_suite.R` produces 73 PNG charts and a manifest in `charts/`: 22 curated or goal-aligned charts and 51 factor-by-factor scatterplots. The charts are organized into:

- outcomes and homelessness composition;
- housing cost, affordability, vacancy, stock, permits, and supply growth;
- service capacity, funding, and real-income comparisons;
- within-state, lagged, and first-difference relationships; and
- missing-data and category-completeness diagnostics;
- a study-wide screen of every eligible factor and a factor-category summary; and
- state-faceted scatterplots of each eligible factor against `homeless_rate_per_10k`.

The new charts use rates or normalized measures when state size matters, retain time on the horizontal axis when it is analytically important, show the 2021 disruption, and avoid treating the disrupted count as continuous evidence. The all-factor screen summarizes all 51 eligible numeric factors using both within-state levels and annual changes, while the category summary prevents the narrative from depending on a single variable. Scatterplots facet California and Florida, encode year by color, exclude 2021, show the usable observation count, and omit fitted regression lines. All relationship charts remain descriptive and should not be described as causal effects.

Scatterplots exclude the target itself, raw homelessness totals and components, the change version of the homelessness outcome, the PIT warning flag, ratios with homelessness in the denominator, the temporary plotting copy of the target, and the all-missing foreclosure field. Exact exclusions and reasons are stored in `charts/scatterplot_exclusions.csv`.

## Study-wide and mechanism-level preliminary EDA charts

The recommended study-wide narrative uses:

1. homelessness rate over time, to establish the divergence being explained;
2. the all-factor association screen, to compare all 51 eligible factors using within-state and annual-change correlations;
3. the category association summary, to compare broad groups of candidate explanations;
4. the selected within-state heatmap, to reveal conceptual clustering and collinearity;
5. the missing-data heatmap, to show which comparisons the evidence can support;
6. category completeness, to compare coverage across the explanatory system; and
7. representative state boxplots, to summarize between-state distributions while acknowledging that time order is hidden.

Four mechanism follow-ups show affordability, rental vacancy, normalized permitting, and bed capacity. The 51 individual-variable scatterplots form a diagnostic appendix for nonlinearity, outliers, state-specific patterns, and coverage. The ordered paths and design reasons for the 11 presentation charts are stored in `charts/key_chart_manifest.csv`. `charts/KEY_CHARTS.md` provides a presentation-ready guide and interpretation boundaries.

The charts estimate associations, not the impact of each variable holding all others constant. Relative contribution is a later modeling question requiring a small theory-guided feature set, state and time controls, lag checks, and time-based validation.

## Reproducible build order

Run from the workspace root:

```r
setwd("Final Project")
source("build_housing_metrics.R")
source("update_team_dataset.R")
source("generate_project_chart_suite.R")
```

The current primary deliverables are `DSA_Group_10_updated.xlsx`, `DSA Group 10 - Sheet1.csv`, `charts/chart_manifest.csv`, and the chart files listed in that manifest.

## Cleaning outputs produced

`clean_analysis_data.R` creates the following reproducible products in `cleaned_data/`:

- `analysis_panel_clean_full.csv`: broad 32-row cleaned panel with structural missingness preserved, foreclosure removed, and availability flags added;
- `analysis_panel_core.csv`: 30 non-2021 rows with complete candidate variables for the main analysis;
- `analysis_panel_rent_cost.csv`: 28 complete non-2021 rent-cost observations;
- `analysis_panel_rent_income.csv`: 10 complete non-2021 ACS B25071 observations;
- `analysis_panel_rent_burden.csv`: 18 complete Eviction Lab rent-burden observations;
- `analysis_panel_eviction_2010_2018.csv`: 18 complete eviction-period observations;
- `cleaning_audit.csv` and `validation_checks.csv`; and
- `cleaned_analysis_datasets.xlsx`, which packages all panels and checks into one workbook.

No statistical imputation was used. Missing values were treated through verified source replacement, definition separation, explicit usability flags, removal of an all-missing analytical field, and purpose-specific complete panels.
