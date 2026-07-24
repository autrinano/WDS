# California–Florida raw county-year panel, 2010–2025

## Deliverables

- `county_year_raw_panel_CA_FL_2010_2025.xlsx`: primary multi-sheet workbook.
- `county_year_raw_panel_CA_FL_2010_2025.csv`: machine-readable compiled panel.
- `variable_dictionary.csv`: definitions, units, categories, and candidate roles.
- `source_log.csv`: producer, access path, exact URL or pattern, retrieval date, and limitations.
- `assumptions_log.csv`: explicit data and modeling assumptions.
- `coverage_summary.csv`: nonmissing counts and observed year range for every variable.
- `validation_checks.csv`: reproducible structural and domain checks.
- `raw_file_index.csv`: file sizes, timestamps, and MD5 hashes.
- `raw_downloads/`: preserved source files and API responses.
- `../build_county_raw_panel.R`: reproducible acquisition and workbook build.

## Scope

The compiled panel has 2,000 rows and 62 columns:

- 58 California counties;
- 67 Florida counties;
- 16 years, 2010 through 2025 inclusive;
- one unique row per county-year; and
- 54 documented candidate variables in six substantive categories.

The categories are demographics, housing supply, housing market, income and
poverty, labor market, and economic output/income, plus uncertainty and
coverage fields. “Coefficient” was interpreted as **candidate covariate**. No
regression coefficients have been estimated because a modeling target has not
yet been selected.

## Sources

The panel uses:

1. U.S. Census Bureau Population Estimates Program county population and
   migration components;
2. U.S. Census Bureau county housing-unit estimates;
3. U.S. Census Bureau/HUD Building Permits Survey;
4. U.S. Census Bureau Small Area Income and Poverty Estimates;
5. U.S. Bureau of Labor Statistics Local Area Unemployment Statistics, with
   some annual series accessed through FRED;
6. U.S. Bureau of Economic Analysis CAINC1 county personal income;
7. U.S. Bureau of Economic Analysis CAGDP1 county GDP; and
8. Federal Housing Finance Agency annual county House Price Index.

Exact URLs and database-level limitations are in `source_log.csv` and the
workbook’s **Source Log** sheet. Every retained download is indexed and hashed.

## Raw-data conventions

- Missing, suppressed, and not-yet-published values remain blank.
- No value was interpolated, forward-filled, winsorized, or converted to zero.
- No dollar value was inflation-adjusted.
- Published confidence intervals and BLS footnotes are retained.
- The only constructed measures are the documented mechanical sums of the four
  Building Permits Survey structure-size categories.
- The compiled sheet performs key-based joins and reshaping for graphability;
  each source-specific raw table is also included in the workbook.

## Important coverage limitations

- SAIPE and BEA county releases currently end in 2024, so their 2025 cells are
  blank by design.
- FHFA county HPI is developmental and unavailable for some small counties.
- BLS labor measures are complete for all 125 counties in 2010–2019. The
  current cache covers 60 counties in 2020–2025. The anonymous BLS API reached
  its daily limit, and the corrected 12-series FRED batch retrieval was then
  blocked by the workspace’s external-access credit limit. Do not use
  2020–2025 labor fields for cross-county comparisons until the other 65
  counties are retrieved.
- Census population and housing estimates cross a documented vintage boundary
  between 2019 and 2020.
- No county homelessness outcome is included. HUD PIT counts use
  Continuum-of-Care geography, so adding them requires a documented geographic
  crosswalk or allocation rule rather than silently treating CoCs as counties.

## Validation

All 12 current checks pass, including row and county counts, full year range,
unique county-year keys, nonnegative population/housing values, valid poverty
and unemployment-rate domains, complete 2010–2019 labor coverage, and retention
of all 125 county rows in 2025.

Rebuild from the workspace root with:

```r
setwd("Final Project")
source("build_county_raw_panel.R")
```

The next analytical step should be a separate cleaned derivative. Define the
outcome and prediction date first, then select a compact theory-driven feature
set, normalize raw totals where appropriate, lag predictors, and use
time-based validation rather than a random row split.
