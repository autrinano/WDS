# Historical CoC-Boundary Diagnostics for the v2 Builder

Independent comparison of yearly HUD **PIT** and **HIC** CoC identifiers
(2010-2025) against the **FY2024** boundary / crosswalk set used by the v2
pipeline. Read-only: no v2 dataset, builder, crosswalk, or central document
was modified. Historical crosswalks were not invented and unmatched CoCs were
not forced into current geographies.

## Reference sets

- FY2024 CoCs: **71** (crosswalk = 71, geojson = 71, identical = TRUE).
- PIT observations 2010-2025: **1115** CoC-years (matched to FY2024: 1112).
- HIC observations 2010-2025: **1125** CoC-years (matched to FY2024: 1110).

## Three geographic stages (do not conflate)

CoCs thin out across three stages for two structurally different reasons.
The first transition drops rows for a **boundary mismatch**; the second
drops rows for **predictor coverage**. They are not the same thing.

| Stage | CoCs | Rows | What it is |
|-------|-----:|-----:|------------|
| (1) FY2024 crosswalk | **71** | - | Reference CoC geography (`county_to_coc_population_crosswalk_FY2024.csv`). |
| (2) Boundary-matched candidate panel | **71** | **974** | PIT outcomes with an FY2024 denominator, matched to a next-year target, 2021-as-target excluded (`lasso_next_year_candidate_panel.csv`). |
| (3) Final v2 complete-case workbook | **70** | **887** | Candidate rows with **every** required predictor present (`CA_FL_LASSO_MODEL_INPUT_v2.xlsx`). |

Stage 1->2 loses **3** row(s) to boundary mismatch (**CA-528**). Stage 2->3
loses **11** further row(s) to predictor coverage (**FL-518**), which is why
the final workbook has **70** CoCs, one fewer than the 71-CoC candidate
panel. Details in the two sections below and in
`excluded_model_rows_by_reason.csv`.

## Reconciliation against the v2 finding

> v2: *CA-528 is the only unmatched historical CoC code and accounts for three PIT-year rows.*

**On the PIT / model-row axis: CONFIRMED.** The only PIT CoC absent from
FY2024 is **CA-528** (Del Norte County CoC), present in PIT for **2010, 2011, 2012**
= **3 rows**. It carries `population_denominator_status =
'Unavailable: historical CoC not represented by FY2024 boundary'`, so it is
dropped before the candidate panel; the candidate panel's **71** CoCs
therefore equal the FY2024 set exactly. (The *final v2 complete-case*
workbook has **70** CoCs, one fewer, for a separate predictor-coverage
reason documented below — not a boundary mismatch.)

**Scope clarification (partial disagreement).** If "historical CoC code"
includes the **HIC** predictor identifiers the v2 dataset also ingests, then
CA-528 is *not* the only unmatched code. HIC additionally contains
**CA-605, CA-610, CA-615, FL-516**, all absent from FY2024.
These cost **zero model rows** (PIT never recorded them, so they never
become candidate rows), but their HIC bed counts fail to join and are
unused. The v2 statement is therefore exact for PIT / lost model rows, and
incomplete as a claim about *all* historical CoC identifiers.

## Historical CoC codes absent from FY2024

| Code | State | In PIT (years) | In HIC (years) | Local successor evidence |
|------|-------|----------------|----------------|--------------------------|
| CA-528 | CA | 2010;2011;2012 | 2010;2011;2012 | PIT name 'Del Norte County CoC'; FY2024 crosswalk assigns Del Norte County (FIPS 06015) to CA-516 whose CoC name explicitly lists 'Del Norte' -> CA-528 folded into CA-516. |
| CA-605 | CA | - | 2010;2011;2012;2013 | none available locally (no local name or FY2024 crosswalk row identifies a successor) |
| CA-610 | CA | - | 2010 | none available locally (no local name or FY2024 crosswalk row identifies a successor) |
| CA-615 | CA | - | 2015;2016 | none available locally (no local name or FY2024 crosswalk row identifies a successor) |
| FL-516 | FL | - | 2010;2011;2012;2013;2014 | none available locally (no local name or FY2024 crosswalk row identifies a successor) |

Only **CA-528 -> CA-516** is locally verifiable (Del Norte County, FIPS
06015, is a CA-516 member in the FY2024 crosswalk and CA-516's name lists
"Del Norte"). No local evidence identifies successors for the HIC-only
codes, so none were reassigned.

## Model rows lost, by stage and reason

`excluded_model_rows_by_reason.csv` separates three categories:

1. **Boundary mismatch** (stage 1->2): exactly **3** row(s), all **CA-528** (2010, 2011, 2012) — a PIT CoC with no FY2024 denominator, dropped before the candidate panel.
2. **HIC-only unmatched** identifiers (**CA-605, CA-610, CA-615, FL-516**): **0** model rows lost — they never join the PIT-keyed candidate panel, so their HIC beds are simply unused.
3. **Predictor-coverage exclusion** (stage 2->3): **FL-518** is boundary-matched (in FY2024, and even a split-county CoC) but has **no usable `coc_relative_home_price_index_2000_base`** (FHFA local home-price index) — its member counties never reach the 40% weighted-coverage floor. It supplies **14** candidate-panel rows, of which **11** were present in the v1 complete panel; requiring that predictor drops all **11** and removes the CoC entirely.

Pipeline counts:
PIT/outcomes **1115** -> matched to FY2024 **1112** (lost **3** to boundary mismatch) -> candidate panel **974** rows / **71** CoCs -> final v2 complete-case **887** rows / **70** CoCs (lost **11** rows / 1 CoC to predictor coverage; v1 complete-case was **898** rows / **71** CoCs).

## FY2024 codes absent in particular historical years

Per-source, per-state, per-year presence is in
`coc_boundary_diagnostics_by_year.csv` (`n_fy2024_absent`,
`fy2024_absent_codes`). These are FY2024 CoCs not yet reporting in a given
year (e.g. new/renumbered CoCs in early years), **not** boundary conflicts;
they reduce coverage for that year but do not create unmatched rows.

## Split-county flags

FY2024 CoCs whose allocation splits a county across CoCs (8 CoCs):
**CA-600, CA-606, CA-607, CA-612, FL-506, FL-508, FL-510, FL-518**
across counties: Baker County, Dixie County, Los Angeles County, Union County.
Allocation for these uses fractional ACS 2024 tract-population shares, so
their county-derived predictors are estimates; treat them cautiously in
split-CoC sensitivity checks.

## Inputs

- `coc_analysis/cache/hud_pit_coc_selected_2010_2025.csv` (PIT identifiers)
- `raw_data/2007-2025-HIC-Counts-by-CoC.xlsx` (HIC identifiers, read directly)
- `coc_analysis/county_to_coc_population_crosswalk_FY2024.csv` + `raw_data/hud_coc_boundaries_FY2024_CA_FL.geojson` (FY2024 set)
- `coc_analysis/coc_year_homelessness_outcomes_CA_FL_2010_2025.csv`, `lasso_next_year_candidate_panel.csv` (pipeline counts)
- `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx` (v1) and `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` (v2) complete-case workbooks (final-stage CoC/row counts; read-only)

## Reproduce

```bash
Rscript diagnose_coc_boundaries_v2.R
```
