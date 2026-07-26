# California–Florida housing metrics, 2010–2025

## Purpose and unit of observation

This folder contains a merge-ready housing panel for a project comparing factors associated with homelessness in California and Florida. The unit of observation is **one state-year**. The workbook has 32 rows: two states × 16 years (2010–2025).

The primary deliverable is `housing_metrics_CA_FL_2010_2025.xlsx`. A plain CSV with the same panel is also included. Raw source downloads are preserved in `raw_data/`, and `build_housing_metrics.R` recreates the processed files.

The housing panel is integrated into the broader team dataset by `update_team_dataset.R`. The resulting deliverables are `DSA Group 10 - Sheet1.csv` and `DSA_Group_10_updated.xlsx`. See `PROJECT_DATA_AND_CHART_AUDIT.md` for the team-wide missing-data and chart decisions.

## Sources and definitions

| Workbook column | Definition | Source | Available years in this workbook |
|---|---|---|---|
| `median_rent` | Median gross rent in nominal dollars per month | Eviction Lab v2 raw map tiles, which include Census housing covariates; Census ACS 5-year table B25064 | 2010–2024 |
| `median_home_price` | Annual median of Zillow's monthly state median sale price, nominal dollars | [Zillow Research Data](https://www.zillow.com/research/data/) state median sale-price CSV | 2010–2025 |
| `rent_as_pct_income` | Median gross rent as a percentage of household income | Census ACS 5-year table B25071 | 2019–2024 |
| `rent_burden_share` | Percentage of renter households meeting the Eviction Lab rent-burden definition | Eviction Lab v2 raw map tiles | 2010–2018 |
| `rental_vacancy_rate` | Annual rental vacancy rate, percent | U.S. Census Bureau Housing Vacancy Survey, distributed by FRED (`CARVAC`, `FLRVAC`) | 2010–2025 |
| `homeownership_rate` | Annual homeownership rate, percent | U.S. Census Bureau Housing Vacancy Survey, distributed by FRED (`CAHOWN`, `FLHOWN`) | 2010–2025 |
| `housing_units_per_capita` | Estimated total housing units divided by estimated resident population | U.S. Census Bureau Population Estimates Program, 2019 and 2025 vintages | 2010–2025 |
| `new_housing_permits` | Sum of monthly private housing units authorized by building permits | U.S. Census Bureau / HUD Building Permits Survey, distributed by FRED (`CABPPRIV`, `FLBPPRIV`) | 2010–2025 |
| `housing_supply_growth_rate` | Year-over-year percent change in estimated total housing units | Computed within Census housing-unit estimate vintages | 2011–2019 and 2021–2025 |
| `eviction_filing_rate` | Modeled eviction filings per 100 renter homes | [Eviction Lab National Eviction Map v2](https://evictionlab.org/map/) | 2010–2018 |
| `foreclosure_rate` | Reserved column; no values inserted | No comparable free state-year source spanning the project period was identified | None |

## Sources that must be reported

The final report should cite the original producer, not only the download host. The following sources were actually used by the housing integration and must appear in the data section or references:

| Producer and dataset | Variables used | Transformation used here | Reporting note |
|---|---|---|---|
| Eviction Lab, National Eviction Map v2 | `eviction_filing_rate`; 2010–2018 rent and burden covariates | State-year values read from raw and modeled map tiles | Filing rate is modeled filings per 100 renter homes, not completed evictions |
| U.S. Census Bureau, ACS 5-year tables B25064 and B25071 | `median_rent`, `rent_as_pct_income` for 2019–2024 | 2019–2020 estimates extracted from state sequence archives; 2021–2024 from table-based summary files | These are overlapping five-year estimates |
| U.S. Census Bureau, Housing Vacancy Survey | `rental_vacancy_rate`, `homeownership_rate` | Annual state series downloaded through FRED | State estimates have sampling uncertainty |
| U.S. Census Bureau/HUD, Building Permits Survey | `new_housing_permits` | Monthly authorized units downloaded through FRED and summed by calendar year | Permits are authorized units, not starts or completions |
| Zillow Research, state median sale price | `median_home_price` | Median of available monthly values within each year | Sale price is not ACS owner-occupied home value |
| U.S. Census Bureau, Population Estimates Program | `housing_units_per_capita`, `housing_supply_growth_rate` | Housing-unit and population estimates combined within Census vintage | 2020 growth is omitted at the vintage boundary |
| U.S. Bureau of Labor Statistics, CPI-U (`CPIAUCSL`) | Constant-2025-dollar variables | Mean of monthly CPI-U values by year; 2025 is the reference year | Downloaded through FRED |
| U.S. Census Bureau land-area statistic | `population_density` | Team population divided by 155,858.33 square miles for California or 53,652.17 for Florida | Constants are manually encoded; verify the exact Census table/edition before final citation |

FRED is a distributor for several series above. A complete citation should name the Census Bureau, HUD, or BLS as the producer and may also state that the series was accessed through the Federal Reserve Bank of St. Louis.

The original team spreadsheet contains homelessness, service capacity, funding, policy, economic, health, education, demographic, and climate variables whose original sources are not documented in this folder. Those columns must not be described as verified HUD, Census, BLS, or other official data until the team locates and records the actual source, definition, geography, years, and retrieval date.

## Important assumptions and choices

1. **No interpolation or fabricated values.** Unsupported state-years are blank in the Excel workbook and empty in the CSV. Yellow workbook cells indicate missing values.
2. **Home price means sale price here.** Zillow's monthly median sale-price series is annualized by taking the median of the available monthly values in each calendar year. This is not the ACS median value of all owner-occupied homes.
3. **Two rent-burden concepts are separated.** `rent_as_pct_income` is ACS B25071's median gross rent as a percentage of household income. `rent_burden_share` is Eviction Lab's renter-household burden share. They are not interchangeable and are never coalesced.
4. **Eviction filing rate is modeled.** Eviction Lab's modeled rate is used because raw court records have uneven geographic coverage. It is filings per 100 renter homes, not completed evictions.
5. **Eviction Lab housing covariates can repeat.** Several 2011–2018 rent and burden values repeat in the map tiles because covariate benchmarks were carried across years. Do not interpret a repeated value as proof that the market did not change.
6. **Housing supply crosses a documented vintage boundary.** Housing units per capita uses the Census 2019 vintage for 2010–2019 and the 2025 vintage for 2020–2025. Each annual ratio uses housing units and population from the same vintage. The 2020 growth value is blank so the growth calculation does not compare different vintages.
7. **Permits are authorized units.** They are not building structures, construction starts, or completed homes. One multifamily permit may authorize many units.
8. **Nominal dollars.** Rent and home-price values are not inflation-adjusted.
9. **2025 publication timing.** ACS 2025 estimates were not available at the July 22, 2026 retrieval date. Census/HVS, permits, Zillow, and Population Estimates series do have 2025 observations.
10. **Foreclosure is not mortgage delinquency.** Available free delinquency series were not substituted because delinquency and foreclosure are different events. ATTOM and CoreLogic publish useful foreclosure measures, but long historical state panels are generally licensed or embedded in annual reports with changing coverage.
11. **The row key is parsed from text.** `state_year` is assumed to end with a four-digit calendar year and to begin with the state name. The integration validates exactly two states, 2010–2025, and one unique row per state-year.
12. **Numeric symbols are formatting, not data.** Commas, currency signs, and percent signs in the original team CSV are removed before numeric conversion. Blank strings become `NA`; zero is preserved as zero.
13. **Population density uses fixed land area.** State land area is treated as constant over the panel. The population numerator comes from the original team sheet and still requires source verification.
14. **Estimated housing units is reconstructed.** `estimated_housing_units` equals housing units per capita multiplied by the team population. Small differences from an independently published total can arise from rounding and from the population input.
15. **Total beds is a partial capacity measure.** `total_beds_per_10k` adds only the spreadsheet's shelter and permanent supportive housing bed rates. It is not necessarily every homelessness-system bed type.
16. **Funding ratios inherit the funding definition.** The script assumes `state_homeless_funding_musd` is millions of nominal dollars and divides it by the PIT count. The funding series and its accounting scope must be verified before substantive interpretation.
17. **Affordability uses household income.** `home_price_to_income_ratio` divides Zillow median sale price by the team sheet's median household income. The numerator and denominator describe related but not identical populations.
18. **CPI adjustment is national.** Constant-dollar fields use national CPI-U and therefore remove general inflation, not state-specific housing inflation.
19. **Derived variables inherit input limitations.** A reproducible formula does not make an undocumented component source verified. The workbook identifies this as `derivation documented; verify component sources`.
20. **No causal interpretation.** Same-year associations do not establish that a housing, policy, health, or economic variable caused a change in homelessness.

## Raw files

`raw_data/` includes:

- Eviction Lab raw and modeled `.pbf` state tiles used for the 2010–2018 fields;
- ACS table-based summary `.dat` files for B25064 and B25071, 2021–2024;
- ACS 2019–2020 sequence lookup files and California/Florida sequence archives containing B25064 and B25071;
- FRED CSV exports for the six Census/HUD series;
- Zillow's state monthly median-sale-price CSV;
- Census 2019- and 2025-vintage housing-unit and population Excel files.
- the FRED CPI-U CSV used for inflation adjustment; and
- the preserved original team CSV used as the stable rebuild input.

The workbook's `Raw File Index` sheet lists the files and sizes. The `Metric Guide` sheet repeats the definitions and limitations; the `Missingness` sheet counts available and missing rows for each metric.

## Exact retrieval endpoints

Data were retrieved on July 22, 2026 from these reproducible endpoints:

- Eviction Lab tiles: `https://tiles.evictionlab.org/v2/{raw|modeled}/states-10/2/{0|1}/1.pbf`
- ACS table files: `https://www2.census.gov/programs-surveys/acs/summary_file/{YEAR}/table-based-SF/data/5YRData/acsdt5y{YEAR}-{TABLE}.dat`, where `YEAR` is 2021–2024 and `TABLE` is `b25064` or `b25071`
- ACS 2019–2020 lookup files: `https://www2.census.gov/programs-surveys/acs/summary_file/{YEAR}/documentation/user_tools/ACS_5yr_Seq_Table_Number_Lookup.txt`
- ACS 2019–2020 state sequence archives: `https://www2.census.gov/programs-surveys/acs/summary_file/{YEAR}/data/5_year_seq_by_state/{STATE}/All_Geographies_Not_Tracts_Block_Groups/{ARCHIVE}`
- FRED CSV export: `https://fred.stlouisfed.org/graph/fredgraph.csv?id={SERIES_ID}`
- Zillow median sale price: `https://files.zillowstatic.com/research/public_csvs/median_sale_price/State_median_sale_price_uc_sfrcondo_sm_month.csv`
- Census housing units: `https://www2.census.gov/programs-surveys/popest/tables/2020-2025/housing/totals/NST-EST2025-HU.xlsx`
- Census population: `https://www2.census.gov/programs-surveys/popest/tables/2020-2025/state/totals/NST-EST2025-POP.xlsx`
- Census 2010–2019 housing units: `https://www2.census.gov/programs-surveys/popest/tables/2010-2019/housing/totals/NST-EST2019-ANNHU.xlsx`
- Census 2010–2019 population: `https://www2.census.gov/programs-surveys/popest/tables/2010-2019/state/totals/nst-est2019-01.xlsx`
- FRED CPI-U: `https://fred.stlouisfed.org/graph/fredgraph.csv?id=CPIAUCSL`

## Team-panel additions

The integrated dataset retains the original nominal variables and adds constant-2025-dollar versions using the annual average of monthly U.S. CPI-U (`CPIAUCSL`). It also derives normalized measures only where the numerator and denominator are available and conceptually compatible. Examples include permits per 1,000 housing units, beds per 100 people experiencing homelessness, total beds per 10,000 residents, the home-price-to-income ratio, and unsheltered share.

The original team spreadsheet is preserved as `raw_data/DSA_Group_10_Sheet1_original.csv`. Many original non-housing columns do not have a documented source in this folder; they are retained but marked `source verification needed` in the updated workbook rather than being presented as newly verified data.

## CoC homelessness and LASSO derivative

`build_coc_lasso_panel.R` creates a separate CoC-year analysis layer in
`coc_analysis/`. It does not insert CoC counts into county rows.

- The outcome is HUD's observed PIT count by CoC for 2010–2025.
- The primary target is the next year's PIT homelessness rate per 10,000
  estimated CoC residents.
- FY2024 HUD CoC polygons are overlaid with 2024 Census tracts.
- ACS 2024 five-year tract population determines each county's population
  share assigned to each CoC.
- Annual county totals are allocated with those fixed shares. County rates,
  indices, and medians are combined with allocated-population weights.
- A weighted average of county medians is an approximation, not a directly
  observed CoC median.
- FY2024 CoC boundaries are applied retrospectively. Historical CoC mergers,
  splits, and boundary changes therefore remain a source of measurement error.
- Tracts whose point-on-surface falls outside the published polygon are
  assigned to the nearest CoC in the same state, with fallback counts and
  distances retained in the crosswalk audit.
- Historical CoCs absent from the FY2024 boundary layer retain their observed
  PIT outcome, but no estimated denominator or allocated predictors. `CA-528`
  (Del Norte County CoC, 3 PIT-year rows 2010-2012) is the only such PIT code;
  the HIC-only codes `CA-605`, `CA-610`, `CA-615`, `FL-516` are also absent
  from FY2024 but cost zero model rows because they never appear in PIT. See
  `diagnose_coc_boundaries_v2.R` and
  `outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md`.
- The core LASSO panel excludes 2021 as a target and uses prior-year
  predictors. It contains 904 complete candidate rows across 71 CoCs.

The raw inputs are HUD's `2007-2025-PIT-Counts-by-CoC.xlsb`, the FY2024 HUD
CoC boundary service, 2024 Census TIGER/Line tract files, and ACS 2024
five-year B01003 tract population obtained through Census Reporter. The
official HUD 2025 AHAR page is
`https://www.huduser.gov/portal/datasets/ahar/2025-ahar-part-1-pit-estimates-of-homelessness-in-the-us.html`.

## Expanded one-sheet LASSO input

`build_expanded_lasso_input.R` creates
`outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx`. The workbook has one
machine-readable sheet, `LASSO Model Data`, so the modeling code needs only one
input table.

- The table contains 898 CoC-year rows and 56 columns: six identifiers, one
  next-year homelessness-rate target, two baseline controls, and 47 candidate
  predictors.
- Predictor year `t` is matched to PIT target year `t + 1`; target year 2021
  remains excluded.
- The expanded factor pool combines nonredundant county-derived CoC measures,
  documented state housing and policy measures, selected provisional team
  state-year factors, and official HUD HIC service-capacity measures.
- `coc_hic_temporary_beds_per_10k` is the sum of year-round emergency shelter,
  transitional housing, and safe-haven beds divided by estimated CoC
  population and multiplied by 10,000.
- `coc_hic_psh_beds_per_10k` is year-round permanent supportive housing beds
  divided by estimated CoC population and multiplied by 10,000.
- The HIC source is `raw_data/2007-2025-HIC-Counts-by-CoC.xlsx`. Only
  predictor-year HIC values are used.
- Rows without an observed, definition-compatible HIC capacity value or any
  other selected predictor remain excluded; no missing value is interpolated,
  set to zero, or globally imputed.
- Raw target components, future target denominators, per-homeless-person
  denominators, confidence bounds, duplicate nominal/real measures, and
  mechanically redundant totals are not included as predictors.
- Header comments record each field's modeling role and source status.
  Several inherited state-year policy, funding, health, education, and
  demographic series still require source verification.

## Improved one-sheet LASSO input (v2)

`build_expanded_lasso_input_v2.R` creates
`outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` without overwriting
v1. It has one sheet, `LASSO Model Data`: 887 CoC-year rows across **70
CoCs**, six identifiers, one target, two baseline controls, and 38 candidate
predictors. Full per-variable rationale is in `CHANGELOG_v1_to_v2.md`; the
source-relevant changes are:

- The CoC geography passes through **three stages that must not be
  conflated** (reproduced by `diagnose_coc_boundaries_v2.R`; see
  `outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md`): the **FY2024 crosswalk
  has 71 CoCs**; the **boundary-matched candidate panel has 71 CoCs** (974
  rows); the **final v2 complete-case workbook has 70 CoCs** (887 rows).
  `CA-528` is dropped at stage 1 → 2 as a boundary mismatch (see the CoC
  derivative section above). `FL-518` is dropped at stage 2 → 3 as a
  **predictor-coverage exclusion, not a boundary mismatch**: it is in the
  FY2024 set (and is a split-county CoC), but the required predictor
  `coc_relative_home_price_index_2000_base` (FHFA local home-price index) has
  no usable value for it — its member counties never reach the 40%
  weighted-coverage floor. FL-518 supplies 14 candidate-panel rows, 11 of
  which were in the v1 complete panel, so requiring the FHFA index removes
  exactly those 11 rows (v1's 898 → v2's 887) and the one CoC (71 → 70).

- Every v1 variable flagged `source verification needed` was individually
  audited. Three (`state_anticamping_strictness`, `state_tanf_max_benefit_3person`,
  `state_ssi_state_supplement`) were reclassified as documented, citing the
  per-year citations already recorded in `DATA_LOG.md`. One
  (`state_labor_force_participation`) was rebuilt directly from
  `raw_data/fred_LBSSA06.csv` / `fred_LBSSA12.csv` (BLS LAUS via FRED,
  already downloaded for this project). Nine were dropped because no
  official or adequately verifiable annual state-year source could be
  confirmed within this build: `state_homeless_funding_per_capita`,
  `state_substance_use_disorder_rate`, `state_serious_mental_illness_rate`,
  `state_uninsured_rate`, `state_average_student_debt_per_borrower`,
  `state_avg_in_state_tuition`, `state_pct_age_18_24`,
  `state_pct_age_65plus`, `state_avg_household_size`.
- `state_real_median_home_price_2025_usd`, `state_home_price_to_income_ratio`,
  and `state_real_home_price_growth_pct` were dropped as redundant once
  local (CoC-level) home-price measures were added or already existed
  (`coc_annual_hpi_change_pct` already covered local price growth in v1).
- `coc_relative_home_price_index_2000_base` (new): FHFA county House Price
  Index, U.S. Federal Housing Finance Agency, rebased to a common 2000=100
  point, allocated to CoC geography with an available-case,
  population-weighted average (>=40% weighted county coverage). A true
  dollar-denominated local median home price (Zillow) and a
  home-price-to-income ratio were attempted first and rejected — see
  `CHANGELOG_v1_to_v2.md` section 2 for why.
- `coc_permits_value_per_1000_housing_units_2025_usd` (new): U.S. Census
  Bureau/HUD Building Permits Survey construction value (already in
  `county_raw_panel`), allocated to CoC by population share, normalized
  per 1,000 existing housing units, constant 2025 USD.
- `coc_real_gdp_quantity_index` (new): U.S. Bureau of Economic Analysis
  CAGDP1 real GDP chain-type quantity index, allocated to CoC the same way.
- A CoC-level HUD Continuum of Care Program (Assistance Listing 14.267)
  funding series, sourced from USAspending.gov transaction-level data, was
  built by a parallel effort and is **complete** but is **deliberately
  excluded** from the v2 primary model for four reasons (two about time
  coverage, two about geography): (1) CFDA 14.267 transaction coverage begins
  in 2013, not 2010, the panel's first predictor year; (2) requiring it would
  drop the 2010-2012 modeling years, concentrating row loss in the earliest
  years of a trend the study examines across the whole window; (3) the
  extract's recipient-location field identifies where a grantee is
  headquartered, not necessarily the CoC service area the funding supports;
  and (4) the transaction extract carries no direct county/CoC
  service-geography field to allocate on. See `CHANGELOG_v1_to_v2.md`
  section 3 and `outputs/v2_support/USASPENDING_TRANSACTION_EXTRACT.md`.

## Modeling cautions

- With only 32 state-year rows and strong within-state time trends, a random train/test split will leak temporal information. Prefer a time-based validation split or rolling-origin evaluation.
- Same-year housing variables may be partly simultaneous with homelessness counts. Lag predictors by one year when the research question is predictive or directional, and compare same-year versus lagged specifications.
- State identity and calendar year can dominate the signal. Include a simple baseline with state and year/time terms before attributing importance to individual housing metrics.
- Overlapping ACS 5-year estimates and carried Eviction Lab covariates create serial dependence. Treat conventional independent-row standard errors and feature-importance rankings cautiously.
- Do not impute the entire post-2018 eviction series from the homelessness outcome or other predictors; that would create circularity and false precision.

## Rebuilding

From the workspace root:

```r
setwd("Final Project")
source("build_housing_metrics.R")
source("update_team_dataset.R")
source("clean_analysis_data.R")
```

The scripts use R, download a file only when it is absent, and write the housing, integrated-team, and cleaned-analysis CSV/Excel outputs. Folder-local packages are used where needed.

## Team ownership check

Before modeling, each team member should be able to explain (1) the unit of observation, (2) why yellow cells are blank, (3) the distinction between sale price and property value, (4) the definition of the eviction filing rate, and (5) why a time-based validation split is safer than a random row split.
