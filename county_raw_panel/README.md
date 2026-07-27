# California–Florida raw county-year panel, 2010–2025

## Deliverables

- `county_year_raw_panel_CA_FL_2010_2025.xlsx`: primary multi-sheet workbook.
- `county_year_raw_panel_CA_FL_2010_2025.csv`: machine-readable compiled panel.
- `variable_dictionary.csv`: definitions, units, categories, and candidate roles.
- `source_log.csv`: producer, access path, exact URL or pattern, retrieval date, and limitations.
- `assumptions_log.csv`: explicit data and modeling assumptions.
- `requested_variable_status.csv`: disposition of all 43 requested concepts, including exact matches, derived fields, non-equivalent additions, and unresolved gaps.
- `coverage_summary.csv`: nonmissing counts and observed year range for every variable.
- `validation_checks.csv`: reproducible structural and domain checks.
- `raw_file_index.csv`: file sizes, timestamps, and MD5 hashes.
- `raw_downloads/`: preserved source files and API responses.
- `../scripts/build_county_raw_panel.R`: reproducible acquisition and workbook build.

## Scope

The compiled panel has 2,000 rows and 91 columns:

- 58 California counties;
- 67 Florida counties;
- 16 years, 2010 through 2025 inclusive;
- one unique row per county-year; and
- 83 documented data, uncertainty, coverage, policy, and derived fields.

The categories now include demographics, housing supply, housing market,
housing affordability, eviction, income and poverty, labor market, economic
output/income, education, and policy/safety-net fields, plus uncertainty and
coverage fields. “Coefficient” was interpreted as **candidate covariate**. No
regression coefficients have been estimated because a modeling target has not
yet been selected.

The request audit records 19 direct, derived, already-present, state-level, or
carefully labeled non-equivalent additions; one reserved blank field; and 23
concepts not added because a comparable county-year source or defensible
geographic/aggregation rule was not available. See
`requested_variable_status.csv` before selecting variables.

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
8. Federal Housing Finance Agency annual county House Price Index;
9. Zillow Research monthly county median sale price and Zillow Observed Rent
   Index;
10. Princeton University Eviction Lab county estimates;
11. U.S. Census Bureau 2024 County Gazetteer land area;
12. selected Census ACS 5-year county indicators distributed through FRED;
13. U.S. Department of Labor state minimum wage distributed through FRED; and
14. documented CMS/KFF ACA Medicaid-expansion implementation dates.

Exact URLs and database-level limitations are in `source_log.csv` and the
workbook’s **Source Log** sheet. Every retained download is indexed and hashed.

## Raw-data conventions

- Missing, suppressed, and not-yet-published values remain blank.
- No value was interpolated, forward-filled, winsorized, or converted to zero.
- No dollar value was inflation-adjusted.
- Published confidence intervals and BLS footnotes are retained.
- Constructed measures are limited to documented arithmetic operations:
  permit-category sums, per-capita/per-1,000 rates, population density,
  year-over-year growth rates, Eviction Lab rates from published numerators and
  denominators, annual means of available monthly Zillow values, and a
  deterministic state-year Medicaid-expansion flag.
- The annual Zillow sale-price measure is the mean of monthly county median sale
  prices, not a median over all annual transactions. The month count is
  retained.
- ZORI is a typical observed market-rent index, not ACS median gross rent.
- State minimum wage and Medicaid expansion are repeated for every county in a
  state-year and contain no within-state county variation.
- The compiled sheet performs key-based joins and reshaping for graphability;
  each source-specific raw table is also included in the workbook.

## Important coverage limitations

- SAIPE and BEA county releases currently end in 2024, so their 2025 cells are
  blank by design.
- FHFA county HPI is developmental and unavailable for some small counties.
- BLS annual labor measures now cover all 2,000 county-years. The 2025 annual
  estimate remains an 11-month average excluding October because BLS did not
  publish October data after the federal shutdown.
- Census population and housing estimates cross a documented vintage boundary
  between 2019 and 2020.
- Population and housing-supply growth are blank for 2010 and 2020 by design.
- Eviction Lab county estimates end in 2018 and combine observed and modeled
  data. Uncertainty bounds and source flags are retained; do not splice them to
  the methodologically different post-2020 tracking system.
- ACS-derived homeownership, overall housing-cost burden, income-quintile
  ratio, and adult high-school attainment end in 2024. Adjacent ACS 5-year
  estimates overlap substantially.
- Zillow county coverage is incomplete: annual median sale-price averages cover
  1,405 county-years, while annual ZORI averages cover 806 county-years.
- The Census Data API began requiring an API key on July 9, 2026. Requested
  ACS concepts not available from verified key-free distributions were left
  unfilled rather than copied from undocumented mirrors.
- `foreclosure_rate_per_100_mortgages` is intentionally blank because no free,
  comparable county-year series for 2010–2025 was verified. Mortgage
  delinquency was not substituted.
- No county homelessness outcome is included. HUD PIT counts use
  Continuum-of-Care geography, so adding them requires a documented geographic
  crosswalk or allocation rule rather than silently treating CoCs as counties.

## Validation

All 19 current checks pass, including row and county counts, full year range,
unique county-year keys, nonnegative population/housing values, valid poverty,
unemployment, homeownership, and eviction-rate domains, complete 2010–2025
labor coverage, complete land-area coverage, suppression of growth across the
Census vintage boundary, retention of all 125 county rows in 2025, and
continued blankness of the reserved foreclosure field.

Rebuild from the workspace root with:

```r
setwd("Final Project")
source("scripts/build_county_raw_panel.R")
```

The next analytical step should be a separate cleaned derivative. Define the
outcome and prediction date first, then select a compact theory-driven feature
set, normalize raw totals where appropriate, lag predictors, and use
time-based validation rather than a random row split.
