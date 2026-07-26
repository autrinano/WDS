# CA–FL LASSO model input: v1 → v2 changelog

Scope: this changelog covers the differences between
`outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx` (v1, 898 rows, 56
columns) and `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` (v2, 887
rows, 47 columns), built by `build_expanded_lasso_input_v2.R`. v1 is
unchanged and is not overwritten. A **preliminary pipeline-development LASSO
run was fitted on v1** during earlier development work (so it is not true
that no LASSO was ever fitted on v1); **no definitive model had been fitted
on v2** at the time of dataset construction. This changelog is a
dataset-construction and validation deliverable for v2.

## Row-count waterfall

Rows and CoCs thin out across three geographic stages that must **not** be
conflated. The stage counts below are reproduced by
`diagnose_coc_boundaries_v2.R` and recorded in
`outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md` and
`excluded_model_rows_by_reason.csv`.

| Stage | CoCs | Rows |
|---|---:|---:|
| Observed HUD PIT CoC-year rows, 2010-2025 (72 distinct historical PIT codes) | — | 1,115 |
| ...with an FY2024-boundary population denominator | 71 | 1,112 (excludes `CA-528`, a boundary mismatch — see section 5) |
| **Boundary-matched candidate panel** (predictor-year rows matched to next-year target, 2021 target excluded) | **71** | **974** (`coc_analysis/lasso_next_year_candidate_panel.csv`, unchanged from v1) |
| v1 final complete-case workbook (47 predictors + 2 controls, all state-sheet variables required) | 71 | 898 |
| **v2 final complete-case workbook** (audited predictor set, all numeric values finite) | **70** | **887** |

The gap between the 71-CoC candidate panel and the **70-CoC** final v2
workbook is a single predictor's coverage, not a boundary change. Of the two
new predictors that need a fresh CoC-level aggregation,
`coc_real_gdp_quantity_index` inherits the existing real-GDP coverage and adds
no new gap; `coc_relative_home_price_index_2000_base` (FHFA county HPI) is
missing for exactly one boundary-matched CoC, **`FL-518`**, whose member
counties never reach the >=40% weighted-coverage floor in any year (16
CoC-years for FL-518, 14 of them in the candidate panel). Requiring the FHFA
index as a complete-case field therefore removes **only FL-518**: it supplies
14 candidate-panel rows, of which **11 were present in the v1 complete
panel**, so v2 loses exactly those 11 rows (898 → 887) and one CoC (71 → 70).
This is a **predictor-coverage exclusion, not a boundary mismatch** — FL-518
is in the FY2024 boundary set (it is even a split-county CoC). v2 remains
comfortably above the 850-row floor. See section 5.

## 1. Audit of inherited/provisional state-year variables

v1 pulled 18 state-year variables from `DSA Group 10 - Sheet1.csv` (the
original team spreadsheet), of which 13 were marked `source verification
needed` in the v1 workbook. Each was checked individually:

| Variable | v2 disposition | Reason |
|---|---|---|
| `state_anticamping_strictness` | **Kept, reclassified** | Not "unverified" — it is a fully documented *constructed* ordinal policy index with per-year legal/legislative citations in `DATA_LOG.md` methodology section 8 (*Martin v. Boise*, *Grants Pass v. Johnson*, CA Executive Order N-1-24, FL HB 1365). Header comment now says so instead of "source verification needed." |
| `state_tanf_max_benefit_3person` | **Kept, reclassified** | Documented in `DATA_LOG.md` section 6 with per-year citations (CBPP, LAO, LA County DPSS, Urban Institute Welfare Rules Database). |
| `state_ssi_state_supplement` | **Kept, reclassified** | Documented in `DATA_LOG.md` section 7 with per-year citations (LAO SSI/SSP reports, SSA). |
| `state_labor_force_participation` | **Kept, rebuilt** | Previously had no recorded source. v2 rebuilds `state_labor_force_participation_pct` directly from `raw_data/fred_LBSSA06.csv` / `fred_LBSSA12.csv` (BLS LAUS via FRED), annualized as the mean of monthly values — an official series already downloaded for this project. |
| `state_homeless_funding_per_capita` | **Dropped** | `DATA_LOG.md` section 9 self-flags this as its "LOWEST-CONFIDENCE FACTOR": all Florida values 2010-2022 and California 2014-17 are "order-of-magnitude estimates," and the scope choice alone swings the number 4-5x. Not adequately verifiable. A verified transaction-level CoC Program funding extract was built as a candidate replacement but is excluded from the primary model — see "CoC-level HUD funding" below. |
| `state_substance_use_disorder_rate` | **Dropped** | Investigated as part of this build (the user asked specifically about "drug use" data). SAMHSA NSDUH state estimates are released as overlapping ~2-year small-area-estimation periods (e.g. 2015-2016, 2018-2019, 2021-2022), not annual observations, and are not distributed as a single consolidated machine-readable multi-period file. Building a full, non-fabricated 2010-2024 state series would require manually transcribing values from ~9 separate SAMHSA report releases per state, which could not be verified to this project's standard within this build. Excluded rather than guessed; SAMHSA's state-release index (`samhsa.gov/data/data-we-collect/nsduh-national-survey-drug-use-and-health/state-releases`) is the pointer for future work. |
| `state_serious_mental_illness_rate` | **Dropped** | Same NSDUH limitation as above (same report series). |
| `state_uninsured_rate` | **Dropped** | Census SAHIE publishes an annual state uninsured rate, but a working bulk-CSV endpoint could not be confirmed within this build (guessed URL patterns 404'd) and the Census API requires a key not available in this environment. Excluded rather than guessed. |
| `state_average_student_debt_per_borrower` | **Dropped** | No official annual state-level series with an unambiguous, matching definition was identified. |
| `state_avg_in_state_tuition` | **Dropped** | College Board *Trends in College Pricing* publishes state tuition figures, but only as per-year report tables/PDFs, not a consolidated machine-readable historical series; NCES IPEDS coverage would require per-edition table lookups. Could not be verified to this project's standard within this build. |
| `state_pct_age_18_24` | **Dropped** | Census PEP publishes annual state age-group estimates, but the specific bulk-file URLs for the 2010-2019 vintage could not be confirmed within this build (guessed patterns 404'd). Excluded rather than guessed. |
| `state_pct_age_65plus` | **Dropped** | Same as above. |
| `state_avg_household_size` | **Dropped** | No bulk-downloadable (non-API-key) official source was confirmed within this build. |

Three additional v1 variables that **were** already documented/verified are
also dropped in v2, **not for audit failure but for redundancy** now that
local (CoC-level) home-price measures exist:

| Variable | Reason for removal |
|---|---|
| `state_real_median_home_price_2025_usd` | Superseded by the new local `coc_relative_home_price_index_2000_base`. |
| `state_home_price_to_income_ratio` | State-level version of a concept now covered locally (see below); a local dollar-based ratio was attempted but could not be built without breaking the row-count floor (see section 2). |
| `state_real_home_price_growth_pct` | Redundant with the *already-existing* v1 field `coc_annual_hpi_change_pct`, which is the CoC-level (local) version of the same concept and was left unchanged. |

`state_real_median_rent_2025_usd` and `state_rental_vacancy_rate` are
**kept unchanged** — no full-panel local (county/CoC) replacement for
either was found (see section 2), so the existing verified state-level
series remains the best available measure.

`state_real_minimum_wage_2025_usd` and `state_medicaid_expansion` were
**never** in the "verification needed" group — they come from the
CoC/county pipeline (`build_coc_lasso_panel.R`), sourced from U.S. DOL via
FRED and CMS/KFF respectively (see `county_raw_panel/source_log.csv`), and
are unchanged in v2.

## 2. Local housing-affordability and rental-market predictors

The brief asked to improve local (CoC/county) affordability measures
beyond the existing state-level ones — median rent, rent-to-income, median
home price, home-price-to-income, rental vacancy, renter cost burden,
supply, and permitting.

**What was already local in v1 and is unchanged:** `coc_housing_units_per_1000_residents`,
`coc_permits_per_1000_housing_units`, `coc_multifamily_permit_share_pct`,
`coc_housing_supply_growth_rate_pct`, `coc_housing_cost_burdened_households_pct`
(combined owner+renter burden — not renter-only, as already documented),
`coc_annual_hpi_change_pct` (local home-price growth), `coc_homeownership_rate_pct`.

**What was investigated and could not be added, with reasons:**
- **County-level median gross rent and rent-to-income (ACS B25064/B25071):**
  the already-downloaded national table-based ACS files
  (`raw_data/acs5_2021_b25064.dat` through `acs5_2024_b25064.dat`) do
  contain county-level records and could supply 2021-2024, but there is no
  equivalent already-downloaded county-level source for 2010-2020 (the ACS
  sequence-format files for 2019-2020 lack the geography lookup file
  needed to resolve county FIPS codes, and no bundled 2010-2018 county rent
  covariate exists — the Eviction Lab county file used elsewhere in this
  project carries eviction fields only, not rent). Requiring this for the
  full 2010-2024 panel would cut the row count to roughly 25% of the
  current panel. Not added.
- **Renter-only cost burden and county rental vacancy:** no full-panel,
  county-level official source was identified; Census also cautions
  against small-area ACS rental-vacancy estimates. Not added. This is a
  genuine, documented gap, not a fabricated fix.
- **County median home price (Zillow, dollars) and a local
  home-price-to-income ratio:** tried first, since a literal dollar
  median-price figure is the most directly interpretable "local
  affordability" measure. Built from `county_raw_panel/raw_downloads/zillow_county_median_sale_price_monthly.csv`
  and Census SAIPE county income, allocated to CoC with the FY2024
  population-share crosswalk. The project's standard CoC aggregation
  (>=90% weighted-population coverage) makes this field 100% missing at
  the CoC level. An available-case, population-weighted average (>=40%
  weighted coverage — looser than the project default, justified because
  Zillow's non-publication is structural for small counties, not random)
  still leaves 96 of 974 CoC-years missing, almost entirely concentrated in
  8 small/rural CoCs that **never** have a published Zillow value in
  **any** contributing county for **any** year: `CA-516`, `CA-523`,
  `CA-530`, `FL-506`, `FL-508`, `FL-515`, `FL-517`, `FL-518`. That is not a
  coverage-threshold problem that a looser threshold can fix — there is
  simply no source data. Requiring it drops the final panel to 814 rows,
  below the 850-row floor. **Rejected rather than forced or backfilled.**

**What was added instead:**
- `coc_relative_home_price_index_2000_base` — FHFA county House Price
  Index (already in `county_raw_panel`, documented there as "Federal
  Housing Finance Agency / Housing market"), rebased to a common 2000=100
  point so it is comparable across CoCs, allocated to CoC with the same
  available-case, >=40%-coverage method. Only 14 of 974 CoC-years are
  missing (vs. 96 for the Zillow dollar price), and it covers 7 of the 8
  Zillow-dark CoCs (only `FL-518` remains uncovered). Because the FHFA index
  is a *required* v2 predictor, `FL-518` — the one CoC it cannot cover — is
  the single CoC dropped from the final complete-case v2 workbook (71-CoC
  candidate panel → 70-CoC v2). That is a predictor-coverage exclusion, not a
  boundary mismatch: `FL-518` is present in the FY2024 boundary set. See
  section 5 for the full stage accounting. It is a
  repeat-sales, quality-adjusted price **index**, not a dollar figure — it
  cannot be turned into an income ratio, but it directly complements the
  existing `coc_annual_hpi_change_pct` (growth) with a comparable
  cross-sectional price **level**, which v1 did not have at CoC
  granularity.
- `coc_permits_value_per_1000_housing_units_2025_usd` — dollar value of
  newly authorized construction (Census/HUD Building Permits Survey,
  already in `county_raw_panel`, 100% county coverage), allocated to CoC
  by population share and normalized per 1,000 existing housing units, in
  constant 2025 dollars. Distinct from the existing unit-*count* permit
  measures: it captures the dollar intensity / quality mix of new
  construction that a raw unit count cannot.

## 3. CoC-level HUD funding: extract complete, excluded from the primary model

A parallel effort built a verified, transaction-level HUD CoC Program
(Assistance Listing 14.267) funding series via the USAspending.gov API,
to replace the dropped `state_homeless_funding_per_capita`. That
transaction-level extraction is **complete**
(`outputs/v2_support/usaspending_cfda_14_267_transactions_CA_FL_2010_2025.csv`,
reconciled against the preliminary award-level extract in
`outputs/v2_support/usaspending_award_vs_transaction_annual_totals.csv`
and against `raw_data/fetch_usaspending_coc_awards.R` /
`raw_data/usaspending_coc_program_awards_CA_FL_2010_2025.csv`), but the
resulting predictor is **deliberately excluded from this v2 primary
model**, not because of any data-completeness gap. Four reasons, two about
time coverage and two about geography:

1. **CFDA 14.267 transaction coverage begins in 2013.** No 14.267
   transactions exist for 2010-2012 (both the award-level and
   transaction-level extracts are empty before 2013).
2. **Requiring it would remove the early modeling years.** The v2 panel
   spans predictor years 2010-2024; a funding predictor with no data before
   2013 would either be missing for the 2010-2012 predictor years (violating
   the zero-missing-values requirement) or force those years out of the
   panel — concentrating row loss in the earliest years, a specifically
   undesirable failure mode given the study examines a trend that plays out
   over the whole 2010-2025 window.
3. **Recipient location identifies the grantee, not necessarily the CoC
   service area.** The extract's `recipient_state`/`recipient_location`
   fields describe where the *grantee organization* is headquartered, not
   where the funded services are delivered or which CoC's Continuum they
   serve. A multi-county or state-level grantee's recipient address does not
   reliably identify a single CoC (some `award_id` values even carry a
   non-CA/FL CoC prefix for a CA/FL-located recipient), so allocating amounts
   to CoCs by recipient location would systematically mismeasure which CoC
   the funding supports.
4. **The transaction extract carries no direct county/CoC service
   geography.** There is no place-of-performance county or CoC field to
   allocate on; recipient location is the only geography available. Without
   an independent service-geography crosswalk there is no valid way to place
   a transaction in the CoC whose Continuum it funds — a validity problem, not
   one a larger sample or a different aggregation threshold fixes.

Both extract files and `fetch_usaspending_coc_awards.R` are preserved
untouched. Using this series would require either restricting the study
to CoC-years from 2013 onward or resolving the recipient-location-to-CoC
mapping with an independent geography crosswalk (e.g., project
place-of-performance data if available) — both are recommended follow-up
work, not included here.

## 4. Other new-predictor candidates investigated and rejected

- **HUD HIC Rapid Re-Housing (RRH) beds per 10k residents:** HUD's HIC
  workbook has no standalone RRH column for 2010-2012, folds RRH into the
  combined shelter total for 2013 (the same problem already flagged in
  `DATA_LOG.md` methodology note 4), and reports a mixed "RRH & DEM"
  (Rapid Re-Housing plus Demonstration program) category starting in 2014.
  There is no way to isolate a clean, comparably-defined RRH bed count
  across the full 2010-2024 panel without truncating most of the panel or
  coalescing incompatible definitions. Not added.
- **BEA real GDP quantity index** was reconsidered and **added** as
  `coc_real_gdp_quantity_index` — initially set aside as potentially
  redundant with the existing `coc_real_gdp_per_capita_2017_usd`, but it
  measures real economic growth *momentum* (a chain-type quantity index),
  a genuinely different concept from a per-capita dollar *level*, and it
  introduces no additional missingness beyond what the existing per-capita
  measure already requires (same BEA source, same coverage pattern).

## 5. Geographic stages, boundary matching, and excluded rows

This build uses the same FY2024 HUD CoC boundary set as v1
(`build_coc_lasso_panel.R`); no boundary methodology changed. The
boundary-reconciliation effort noted as "underway in parallel" in earlier
drafts is now complete: `diagnose_coc_boundaries_v2.R` regenerates
`outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md`,
`coc_boundary_diagnostics_by_year.csv`,
`historical_coc_codes_not_in_FY2024.csv`, and
`excluded_model_rows_by_reason.csv`. Its findings are reconciled here.

### Three geographic stages (do not conflate)

| Stage | CoCs | Rows |
|---|---:|---:|
| (1) FY2024 crosswalk | **71** | — |
| (2) Boundary-matched candidate panel | **71** | **974** |
| (3) Final v2 complete-case workbook | **70** | **887** |

Rows are lost at two structurally different transitions, and the three
exclusion categories are enumerated in `excluded_model_rows_by_reason.csv`:

- **Boundary mismatch (stage 1 → 2).** Of the 1,115 observed HUD PIT
  CoC-year rows for CA+FL 2010-2025 (72 distinct historical PIT codes), 71
  codes have an FY2024-boundary population denominator. **`CA-528`** (Del
  Norte County CoC) is the **only** historical PIT code with no FY2024
  match; it has exactly **3** observed PIT-year rows (2010, 2011, 2012). It
  retains its observed PIT count per project convention but has no estimated
  denominator or allocated predictors, so it cannot enter the candidate
  panel. Local evidence (FY2024 assigns Del Norte County, FIPS 06015, to
  CA-516, whose name lists "Del Norte") indicates CA-528 folded into CA-516.
- **HIC-only unmatched identifiers (zero lost rows).** The HIC predictor
  source additionally contains four historical codes absent from FY2024 —
  **`CA-605`, `CA-610`, `CA-615`, `FL-516`** — that never appear in PIT.
  Because the candidate panel is PIT-keyed, these never become candidate
  rows: they cost **zero** model rows; their HIC bed counts simply fail to
  join and are unused. (This is why HIC lists 76 distinct historical codes
  and 1,125 CoC-years while PIT lists 72 codes and 1,115 CoC-years.) So
  CA-528 is the only unmatched code *on the PIT / lost-model-row axis*, and
  these four are unmatched only on the HIC axis with no row cost.
- **Final complete-case predictor-coverage exclusion (stage 2 → 3).**
  **`FL-518`** is fully boundary-matched — it is in the FY2024 set and is
  even a split-county CoC — but has **no usable
  `coc_relative_home_price_index_2000_base`** value (FHFA local home-price
  index): its member counties never reach the >=40% weighted-coverage floor
  in any year. It supplies **14** candidate-panel rows, of which **11** were
  present in the v1 complete panel. Requiring the FHFA index as a
  complete-case field drops all 11 and removes FL-518 entirely, taking v2
  from 71 to **70** CoCs and 898 to **887** rows. This is a
  **predictor-coverage exclusion, not a boundary mismatch** (see section 2).

Split counties (a county whose population is divided across more than one
CoC) are already flagged via `coc_contains_split_county_flag`, unchanged
from v1; the FY2024 split-county CoCs are CA-600, CA-606, CA-607, CA-612,
FL-506, FL-508, FL-510, and FL-518.

## 6. Files

- `build_expanded_lasso_input_v2.R` — reproducible build script (new).
- `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx` — new one-sheet
  workbook (`LASSO Model Data`), 887 rows across **70 CoCs**, 47 columns: 6
  identifiers, 1 target, 2 controls, 38 predictors.
  `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx` (v1) is untouched.
- Every header cell carries an updated comment recording ROLE and SOURCE,
  including explicit "(NEW in v2)" tags for the three new predictors.
- `diagnose_coc_boundaries_v2.R` — independent boundary/stage diagnostic
  (read-only w.r.t. the dataset and builder); regenerates the four
  `outputs/v2_support/` diagnostic files that establish the 71/71/70 stage
  counts and the three exclusion categories in section 5.

## 7. Validation

All checks in `build_expanded_lasso_input_v2.R` passed, including:
unique CoC/predictor-year key; every target exactly one year after its
predictors; 2021 excluded as a target; **zero missing values** in the
target/controls/predictors; **every numeric target/control/predictor value
is finite** (no NA, NaN, or Inf); target and every control/predictor has
variation; no prohibited leakage field present; both states represented;
HIC capacity rates nonnegative; **at least 850 modeling rows retained**
(887 actual); no audit-excluded (unverifiable) state variable remains in
the panel.
