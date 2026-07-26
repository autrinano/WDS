# Final LASSO results — California and Florida CoC homelessness

_Assembled by [`generate_final_lasso_report.R`](generate_final_lasso_report.R) from the completed primary run, the sensitivity run, and the independent audit. No model was fitted, refitted, or re-scored to produce this document, and no dataset, modelling script, or central project document was modified. Every figure and table lives under [`outputs/lasso_final_report/`](outputs/lasso_final_report/); every number below is traceable through [`tables/KEY_NUMBERS.csv`](outputs/lasso_final_report/tables/KEY_NUMBERS.csv)._

**Everything in this document is a predictive association in a two-state, strongly time-ordered panel with retrospectively applied FY2024 CoC boundaries. Nothing here is a causal effect, an impact estimate, or a policy evaluation.**

---

## 1. What was asked and what this answers

The study asks why homelessness rates diverged between California and Florida. This analysis answers a narrower, tractable version of that question: **given a CoC's housing, economic, demographic, geographic, policy, and service-capacity conditions in year _t_, how well can its Point-in-Time homelessness rate in year _t+1_ be predicted out of time, and which predictors carry that signal stably?**

That is a predictive question. It is deliberately not the causal question. A model that predicts well can do so entirely through markers of the outcome rather than its determinants, and section 6 shows that this analysis does exactly that in one important respect.

---

## 2. Data and design

| Element | Value |
|---|---|
| Input | `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx`, MD5 `5d3fd16b32c687e5207ea59c902e7bef` |
| Unit | CoC-year |
| Rows / CoCs | 887 / 70 |
| Target | `target_homeless_rate_per_10k` — next-year CoC PIT rate per 10,000 estimated residents |
| Predictors | 38 candidate predictors, all measured in the predictor year _t_; target is year _t+1_ |
| Controls | `control_state_florida`, `control_time_index` — **unpenalized**, never shrunk |
| Validation | Expanding-window rolling origin, 8 outer folds on target years **2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025** |
| Lambda | Nested **forward-chaining** time CV inside each training window; `lambda.min` and `lambda.1se` both carried through |
| Scaling | Fit on training rows only; glmnet called with `standardize = FALSE` |
| Scored rows | 555 (347 California, 208 Florida) |

Training windows expand from 332 rows (validating 2017) to 817 rows (validating 2025). No random row splits were used and no in-sample metric is reported anywhere.

An independent audit ([`outputs/lasso_audit/AUDIT_REPORT.md`](outputs/lasso_audit/AUDIT_REPORT.md)) recomputed all 128 exported metric rows from the exported predictions (maximum discrepancy 6.4 × 10⁻¹⁴) and all 392 coefficient-stability rows from the per-fold coefficients. It returned **93 PASS / 7 WARNING / 0 FAIL**. Every warning constrains how a result may be *worded*, not whether it was computed correctly; all seven are carried into this document and recorded machine-readably in [`TABLE_10_reporting_constraints.csv`](outputs/lasso_final_report/tables/TABLE_10_reporting_constraints.csv).

Because a penalised predictor enters glmnet already standardised on training rows, **every penalised coefficient reported here is a standardized coefficient**: the change in the next-year rate per 10,000 residents associated with a one-training-window-SD change in that predictor. The two controls are not standardised and are reported separately in [`TABLE_04b`](outputs/lasso_final_report/tables/TABLE_04b_unpenalized_controls.csv).

---

## 3. Predictive performance

**Figure:** [`FIG_01_model_performance_comparison.png`](outputs/lasso_final_report/figures/FIG_01_model_performance_comparison.png) · **Table:** [`TABLE_01`](outputs/lasso_final_report/tables/TABLE_01_model_performance_comparison.csv)

| Model | Rule | Scope | n | RMSE | MAE | R² |
|---|---|---|---:|---:|---:|---:|
| Separate-state composite | 1se | *not unified* | 555 | 13.902 | 10.179 | 0.674 |
| Separate-state composite | min | *not unified* | 555 | 14.058 | 10.576 | 0.667 |
| **Pooled LASSO + state interactions** | **min** | **unified** | **555** | **14.692** | **10.141** | **0.636** |
| Pooled LASSO + state interactions | 1se | unified | 555 | 15.127 | 9.911 | 0.615 |
| Pooled LASSO | min | unified | 555 | 15.297 | 10.158 | 0.606 |
| Pooled LASSO | 1se | unified | 555 | 15.805 | **9.805** | 0.579 |
| State + linear-time baseline | — | baseline | 555 | 21.931 | 14.983 | 0.190 |

The headline model is the **pooled LASSO with state interactions at `lambda.min`**. Three qualifications travel with that designation and must not be dropped:

1. **It is best on RMSE, not best outright.** It has the lowest RMSE and highest R² among unified models and the lowest RMSE in 6 of the 8 folds, but its MAE (10.141) ranks **fourth of four** unified variants, behind `pooled_lasso`/1se (9.805). This is the signature of a model that cuts large errors at the cost of the typical error. Which model is "best" here depends on which loss you care about.
2. **"Unified" is load-bearing.** The separate-state composite scores better overall (RMSE 13.902, R² 0.674). It is, however, the concatenation of two independently fitted single-state models — not one model, and not a fifth independent piece of corroborating evidence. The claim "best model" is true only when restricted to models that cover both states with one fitted object; without that restriction it is false.
3. **Single-state components are not comparable to both-state totals.** `separate_lasso_FL` scores RMSE 10.409 on its own 208 Florida rows. That number is smaller than every 555-row figure in the table and means nothing in comparison to them.

All LASSO specifications beat the state-and-time baseline by a wide margin (RMSE 21.931 → 14.692, a 33% reduction). **But see section 6 before reading that margin as evidence the factor set is predictively useful.**

### Accuracy by validation year

**Figure:** [`FIG_03`](outputs/lasso_final_report/figures/FIG_03_rmse_r2_by_validation_year.png) · **Table:** [`TABLE_02`](outputs/lasso_final_report/tables/TABLE_02_performance_by_validation_year.csv)

| Validation year | 2017 | 2018 | 2019 | 2020 | 2022 | 2023 | 2024 | 2025 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Headline RMSE | 14.18 | 15.96 | 17.71 | 15.67 | 12.77 | 14.40 | 13.16 | 13.02 |
| Headline R² | 0.634 | 0.588 | 0.462 | 0.557 | 0.733 | 0.633 | 0.728 | 0.719 |
| Training rows | 332 | 400 | 469 | 538 | 608 | 678 | 747 | 817 |

**There is no 2021 fold.** The COVID-disrupted 2021 PIT enumeration is excluded as a modelling target project-wide, so the validation sequence skips from 2020 to 2022 and there are 8 folds rather than 9. Nothing in this analysis reports a 2021 outcome.

Accuracy generally improves as the training window grows, which is expected and is not evidence that the underlying relationships strengthened over time. 2019 is the weakest year in every model and in every sensitivity sample.

---

## 4. California versus Florida

**Figure:** [`FIG_04`](outputs/lasso_final_report/figures/FIG_04_california_vs_florida_performance.png) · **Tables:** [`TABLE_03`](outputs/lasso_final_report/tables/TABLE_03_state_performance_ca_fl.csv), [`TABLE_03b`](outputs/lasso_final_report/tables/TABLE_03b_observed_outcome_spread_by_state.csv)

The two states have very different observed outcome distributions:

| | Scored rows | Mean rate | SD | Range |
|---|---:|---:|---:|---:|
| California | 347 (63%) | 42.6 | 24.2 | 8.6 – 141.4 |
| Florida | 208 (37%) | 16.2 | 13.2 | 4.8 – 130.2 |

**Raw RMSE is not comparable between the two states.** Florida's lower RMSE for every LASSO model reflects its narrower CoC-rate distribution, not better explanation. Once RMSE is rescaled by each state's own outcome SD, the headline model's error is **0.69 SD in California and 0.79 SD in Florida** — a modest gap that runs in the *opposite* direction from the raw-RMSE impression.

Three further points, stated plainly and without embellishment:

- **The headline model is not best for Florida.** In California it is the strongest unified variant (RMSE 16.751, R² 0.520). In Florida it is the **weakest of the four pooled variants** (RMSE 10.386, R² 0.376), behind `pooled_lasso`/1se (8.472, 0.585). Its overall win is carried by California, which supplies 63% of scored rows.
- **Pooled R² is not within-state explanatory power.** The state-and-time baseline has pooled R² 0.190 but R² of **−0.126 in California and −0.072 in Florida** — worse than each state's own mean. Its apparent pooled skill is entirely the CA/FL level gap. No pooled R² in this study should be read as within-state explanation.
- **There is no stable ordering of "which state is better modelled."** It depends on the model and the metric: California wins on normalised RMSE under the headline model; Florida wins on within-state R² under `pooled_lasso`/1se. Reporting either direction as a general finding would overstate what these 555 rows support.

---

## 5. Which predictors carry the signal

**Figures:** [`FIG_05`](outputs/lasso_final_report/figures/FIG_05_stable_standardized_coefficients.png), [`FIG_06`](outputs/lasso_final_report/figures/FIG_06_state_interaction_coefficients.png) · **Tables:** [`TABLE_04`](outputs/lasso_final_report/tables/TABLE_04_stable_standardized_coefficients.csv), [`TABLE_05`](outputs/lasso_final_report/tables/TABLE_05_state_interaction_coefficients.csv), [`TABLE_08`](outputs/lasso_final_report/tables/TABLE_08_robust_predictor_matrix.csv)

### 5.1 Six predictors are stable across every sample

These six are selected in at least half the folds, with the same sign, in **every sensitivity sample in which they are available** ([`TABLE_08`](outputs/lasso_final_report/tables/TABLE_08_robust_predictor_matrix.csv), class A). Sign agreement is 1.00 for all six.

| Predictor | Domain | Direction | Main-model selection frequency |
|---|---|---|---|
| `coc_hic_psh_beds_per_10k` | **Service capacity** | positive | 1.00 |
| `coc_hic_temporary_beds_per_10k` | **Service capacity** | positive | 1.00 |
| `coc_log_estimated_population` | Scale/geography | negative | 1.00 |
| `coc_housing_cost_burdened_households_pct` | Housing market | positive | 1.00 |
| `coc_annual_hpi_change_pct` | Housing market | negative | 1.00 |
| `coc_international_migration_rate_per_1000` | Demographic | negative | 1.00 |

Under `lambda.1se` only three survive: both bed rates and CoC log population.

### 5.2 Service capacity is not a structural factor and is reported separately

The two HIC bed-capacity rates are the two largest coefficients in the headline model (+13.6 and +8.2 standardized). **They are plausibly endogenous to the outcome**: capacity is built where homelessness is already high, and sheltered PIT counts are enumerated in those beds. A positive association between beds and next-year homelessness is at least as consistent with capacity responding to need as with anything else, and this analysis cannot separate the two.

Every statement about housing, economic, demographic, and policy associations in this document is therefore reported **separately** from the bed measures, and the structural-only sensitivity (section 6.3) is treated as the conservative version of those statements.

### 5.3 Stable clusters, not identified individual variables

The v2 EDA records **18 predictor pairs with |r| ≥ 0.80**. Three frequently selected predictors are pair members — `coc_population_growth_rate_pct` and `coc_real_gdp_quantity_index` (both selected in 100% of headline folds) and `coc_permits_value_per_1000_housing_units_2025_usd`. No pair has both members frequently selected.

LASSO chooses among near-collinear columns close to arbitrarily, and which member survives changes with the training window. The sensitivity results demonstrate this directly: `coc_population_density_per_sq_mile` falls from 1.00 to 0.00 in the stable-CoC sample while `coc_contributing_counties` rises from 0.75 to 1.00 — two encodings of the same thing, CoC geographic scale, trading places.

**These predictors are markers for a correlated cluster, never the operative variable.** The identified clusters are: CoC geographic scale (log population, density, contributing counties), population change (growth rate, domestic migration), and permit volume (permits per 1,000 units, permit value per 1,000 units). `TABLE_04` and `TABLE_08` carry an explicit `attribution_identified` column; `FIG_05` marks cluster members with `*`.

### 5.4 State interactions describe the model, not a mechanism

`FIG_06` shows the implied California slope (base term) and Florida slope (base + `:FL` interaction) for every predictor whose interaction was ever selected. The largest is `coc_hic_temporary_beds_per_10k`, whose association is substantially weaker in Florida than in California.

**With two states, a state interaction is indistinguishable from any other state-level difference.** It absorbs differences in PIT enumeration practice, CoC composition, the eight state-level predictors that repeat identically across all of a state's CoCs, and anything else that varies between California and Florida. It is not evidence that a mechanism operates differently in the two states. Note also that the interaction model is the weakest of the four pooled variants *within Florida*, so the Florida slopes it implies should be read with that in mind.

### 5.5 Predictors that are never selected

`coc_domestic_migration_rate_per_1000`, `coc_multifamily_permit_share_pct`, `coc_permits_per_1000_housing_units`, `state_labor_force_participation_pct`, `state_medicaid_expansion`, `state_real_median_rent_2025_usd`, `state_ssi_state_supplement`, and `state_tanf_max_benefit_3person` are never selected at `lambda.min` in any of the seven samples.

For the four `state_*` variables this is close to uninformative: they vary only by state and year, so the unpenalized state and time controls absorb most of what they could contribute. **Their absence is not evidence that they are unrelated to homelessness.**

---

## 6. Sensitivity analysis

**Figures:** [`FIG_07`](outputs/lasso_final_report/figures/FIG_07_sensitivity_comparison.png), [`FIG_09`](outputs/lasso_final_report/figures/FIG_09_persistence_benchmark.png) · **Tables:** [`TABLE_06`](outputs/lasso_final_report/tables/TABLE_06_sensitivity_comparison_own_rows.csv), [`TABLE_06b`](outputs/lasso_final_report/tables/TABLE_06b_sensitivity_comparison_common_rows.csv), [`TABLE_09`](outputs/lasso_final_report/tables/TABLE_09_persistence_benchmark.csv)

Seven samples were fitted under a harness that reproduces the FINAL run exactly (`S0_primary` reproduces the primary fold row counts and pooled metrics to the reported decimals). S1, S2 and S5 change **which rows** are modelled; S3 changes only the **predictor set** and keeps the primary model's exact 887 rows and 8 folds, making it the one exactly like-for-like comparison.

### 6.1 Robust to sample construction

| Sensitivity | Change | Δ RMSE vs primary on shared rows | Prediction correlation |
|---|---|---|---|
| **S1** split-county CoCs excluded (796 rows, 63 CoCs) | drops 7 CoCs whose county predictors are fractional ACS-share allocations | −0.07 to +0.21 | 0.985 – 0.991 |
| **S2** continuously observed CoCs (845 rows, 65 CoCs) | drops 5 California CoCs missing at least one target year | −0.79 to +1.03 | 0.929 – 0.963 |
| **S5** FHFA index dropped, FL-518 restored (898 rows, 71 CoCs) | removes the predictor that excluded FL-518 from the primary model | +0.02 to +0.18 | 0.992 – 0.997 |

None of these changes the leading predictor set. The six stable predictors hold their frequencies and signs throughout. **The fractional split-county allocation, the presence of intermittently observed CoCs, and the FL-518 exclusion are not driving the primary findings.**

### 6.2 One measurement caution surfaced by S5, reported not corrected

FL-518's target rate falls from 69–83 per 10k in 2012–2016 to 30–37 from 2017 onward. That step is larger than any plausible one-year market movement and is consistent with a change in local enumeration or CoC composition. It affects only training rows before 2017 and is left visible rather than adjusted.

### 6.3 Not robust to removing service capacity (S3) — the conservative statement

On **identical rows and identical folds**, removing the two HIC bed rates costs a real and substantial amount of accuracy:

| Model | Rule | RMSE | R² | Δ RMSE | Δ R² |
|---|---|---:|---:|---:|---:|
| Pooled LASSO | min | 18.293 | 0.436 | +2.996 | −0.170 |
| Pooled + interactions | min | 17.822 | 0.465 | +3.130 | −0.171 |

Roughly a **third** of the primary model's out-of-time explained variance is associated with the two bed-capacity measures alone. The remaining models still beat the baseline (RMSE 21.931) clearly, so the non-capacity factors do carry genuine predictive signal.

What steps forward when capacity is unavailable is **housing-market composition**: lower homeownership (−9.45, selected in 100% of folds), more housing units per resident (+5.25, 100%), higher cost burden (+1.95, 100%), and weaker recent home-price growth (−1.15, 100%). Economic and policy predictors appear at lower and less stable frequencies. Four predictors are selected in every S3 fold but never in the primary model: `coc_homeownership_rate_pct`, `coc_high_school_graduate_pct`, `coc_real_per_capita_personal_income_2025_usd`, and `coc_contains_split_county_flag`.

These are **associations conditioned on a different predictor set**. The enlarged coefficients partly reflect variance previously absorbed by the bed measures and must not be read as the "true" effects the bed measures were masking.

### 6.4 Not robust to a persistence benchmark (S4 / S4b) — the most important limitation

Each row's prior rate is the CoC's own PIT rate in its predictor year _t_ (the target is _t+1_, so no future value is used). Eligibility requires a present, finite prior rate with an FY2024 denominator and `pit_count_caution_flag == 0`; the last condition removes every `predictor_year == 2021` row, so validation year 2022 has no eligible rows and the benchmark runs on 7 folds.

| Specification | RMSE | MAE | R² | Non-zero factors per fold |
|---|---:|---:|---:|---:|
| Prior-year rate only | 9.119 | 5.264 | 0.859 | — |
| State + time + prior rate | 8.887 | 5.017 | 0.866 | — |
| **38-factor LASSO + prior rate** (either lambda) | **8.887** | **5.017** | **0.866** | **0.0** |
| + state interactions + prior rate (either lambda) | 8.887 | 5.017 | 0.866 | **0.0** |
| Factor LASSO *without* prior rate | 15.658 | 10.479 | 0.585 | 13.9 |
| State + time baseline | 22.148 | 15.017 | 0.170 | — |

**Given the prior rate as an unpenalized control, nested forward-chaining tuning shrank every one of the 38 factors and every state interaction to exactly zero — in all 7 folds, under both lambda rules, in both eligibility samples.** The factor model is numerically identical to the state + time + prior-rate baseline; the difference is a floating-point artefact. The stricter full-enumeration variant (S4b, 666 rows) gives the same verdict at higher accuracy (R² 0.903).

Next-year CoC homelessness rates are dominated by their own prior level. The factor model's apparent explanatory power in the primary analysis is largely a slower route to the same persistence: it predicts well relative to a state-and-time baseline, but not at all relative to knowing last year's rate.

This does not make the factor associations uninformative about *which local conditions co-move with homelessness levels*. It does mean **the factor set must not be presented as improving short-horizon prediction**.

---

## 7. Residual behaviour

**Figures:** [`FIG_08a`](outputs/lasso_final_report/figures/FIG_08a_residuals_by_year_and_state.png), [`FIG_08b`](outputs/lasso_final_report/figures/FIG_08b_residuals_vs_predicted_by_state.png) · **Table:** [`TABLE_07`](outputs/lasso_final_report/tables/TABLE_07_residuals_by_year_and_state.csv)

The headline model's pooled residual mean is +0.40 with SD 14.70 and a maximum absolute residual of 70.5. By state: California mean +1.21 (SD 16.73), Florida mean −0.95 (SD 10.37). Residuals are close to centred within each year, with California's spread consistently wider — matching California's wider observed rate distribution rather than indicating a difference in model quality.

Three patterns are worth naming. Florida's residual spread **narrows markedly** as the training window grows (SD 10.5 in 2017 to 5.2 in 2025); California's is roughly flat (15.7 to 14.6), so the pooled improvement over time in `FIG_03` is largely a Florida effect. Residuals **fan out at higher predicted values**: the model is least reliable for the highest-rate CoCs, which are concentrated in California. And **2023 is a systematic miss in Florida** — mean residual +10.4, the only year in either state with a mean above ±7 — which the model under-predicts across nearly the whole state. Seven CoC-years are missed by more than 50 per 10,000, six of them under-predictions (largest +70.5, largest over-prediction −58.0).

---

## 8. Limitations

Recorded machine-readably in [`TABLE_10_reporting_constraints.csv`](outputs/lasso_final_report/tables/TABLE_10_reporting_constraints.csv).

**Data construction**

1. **2021 PIT excluded as a target.** COVID-disrupted enumeration is not comparable across years. The panel has 13 usable target years, not 14, and 8 validation folds, not 9. Every rate change spanning 2021 is unreliable and none is reported.
2. **FY2024 CoC boundaries applied retrospectively** to 2010–2025 via ACS 2024 tract-population shares. Historical CoC mergers and splits remain a measurement-error source. CA-528 (Del Norte County CoC, 3 PIT rows in 2010–2012) has no FY2024 denominator and is dropped before the candidate panel. Historical denominators and subcounty predictors are documented estimates, not directly observed CoC values.
3. **FL-518 excluded from the primary model.** Its member counties never reach the 40% weighted-coverage floor for the FHFA local home-price index, so requiring that predictor drops all 11 of its rows and the CoC entirely — 887 rows / 70 CoCs rather than 898 / 71. Sensitivity S5 restores it and finds no material change.
4. **Split-county allocation.** Eight FY2024 CoCs split a county (CA-600, CA-606, CA-607, CA-612, FL-506, FL-508, FL-510, FL-518); 91 rows carry the flag in the primary panel. Their county-derived predictors are fractional ACS 2024 tract-share estimates. Sensitivity S1 removes them and finds no material change.
5. **Repeated state-level values.** Eight `state_*` predictors carry one value per state-year, repeated identically across every CoC in that state. The unpenalized state and time controls absorb most of what they can contribute, and non-selection of any of them is uninformative. Several Eviction Lab rent and burden covariates elsewhere in the project repeat across years because benchmark values were carried forward; that is not evidence of no market change.
6. **Limited two-state time structure.** Two states, 70 CoCs, 13 target years, 887 rows, 8 folds. This is a small panel with strong time ordering and only two units at the state level.

**Inference**

7. **No causal claim is supported.** All coefficients and selection frequencies are predictive associations. Same-year and one-year-lagged associations in a two-state panel cannot identify effects.
8. **Service-capacity predictors are plausibly endogenous** to the outcome and are reported separately from structural factors throughout.
9. **Attribution within correlated clusters is not identified.** 18 pairs have |r| ≥ 0.80; three frequently selected predictors are pair members.
10. **Pooled R² is not within-state explanatory power**, as the baseline's negative within-state R² in both states demonstrates.
11. **"Best unified model" is criterion-dependent** and holds only among unified models.

**Transparency notes with no numerical effect**

12. The log-target shift constant is computed over all 887 rows rather than training rows only. Because the minimum target is 4.83, the shift is identically 0 in every fold and no information crosses the split. It is recorded because it is the one preprocessing quantity in the pipeline read from the full column.
13. A log-target sensitivity model was fitted and performed worse on the raw scale for every unified specification (headline: RMSE 21.746 vs 14.692). The raw-rate target is used throughout.

---

## 9. Conclusions that survived every sensitivity check

Ordered from strongest to most qualified. Each is a **predictive association**.

1. **A factor model predicts next-year CoC homelessness rates substantially better than a state-and-time baseline, out of time.** Pooled RMSE falls from 21.931 to 14.692 (R² 0.190 → 0.636) across all 8 folds. This holds in every sample, at both lambda rules, and in 6 of 8 individual folds for the headline model.

2. **It adds nothing once each CoC's own prior-year rate is known.** With the prior rate present, all 38 factors and all state interactions are shrunk to exactly zero in all 7 folds, under both lambda rules, in both eligibility samples. Prior rate alone reaches R² 0.859 (0.899 under the strict rule). The factor set must not be described as improving short-horizon prediction.

3. **Six predictors are stable in every sample where they are available**, at `lambda.min`, with sign agreement 1.00: both HIC bed-capacity rates (positive), CoC log population (negative), local home-price growth (negative), housing cost burden (positive), and international migration (negative). Three survive `lambda.1se`: both bed rates and log population.

4. **Roughly a third of the model's out-of-time explained variance is associated with service-capacity beds alone** — measures that are plausibly endogenous to the outcome. On identical rows, removing them raises RMSE from 14.692 to 17.822 and lowers R² from 0.636 to 0.465.

5. **Excluding service capacity, housing-market composition is the domain that carries the most consistent signal**: lower homeownership, more housing units per resident, higher cost burden, and weaker recent home-price growth are each selected in 100% of folds with consistent signs. This is the conservative structural statement and should be preferred over the primary coefficient set when the question is about housing and economic conditions rather than prediction.

6. **The findings do not depend on the contested sample-construction choices.** Excluding split-county CoCs, restricting to continuously observed CoCs, and restoring FL-518 by dropping the FHFA index requirement all leave accuracy and the leading predictor set essentially unchanged, with prediction correlations of 0.93–0.997 on shared rows.

7. **The best unified model is best on RMSE only, and its advantage is carried by California.** Its MAE ranks fourth of four unified variants, the separate-state composite beats it outright, and within Florida it is the weakest of the four pooled variants. No claim of general superiority is supported.

8. **No stable claim can be made that one state is better modelled than the other.** Raw RMSE favours Florida only because Florida's outcome distribution is narrower; normalised by within-state SD the headline model is marginally better in California (0.69 vs 0.79 SD), and the ordering reverses again on within-state R² under a different model. Any strong CA-versus-FL performance claim would overstate the evidence.

9. **Attribution within correlated clusters is not identified**, and the analysis demonstrates this rather than assuming it: geographic-scale encodings trade places between samples while the cluster's contribution stays intact. Report the cluster, not the member.

**Not concluded, and not supportable from these outputs:** anything causal; any claim that a state interaction reflects a different mechanism in Florida; any reading of pooled R² as within-state explanation; any claim that a never-selected `state_*` predictor is unrelated to homelessness.

---

## 10. Files

**Owned by this report** — nothing else was written or modified.

```
generate_final_lasso_report.R
LASSO_FINAL_RESULTS.md
outputs/lasso_final_report/
├── FINAL_LASSO_REPORT_TABLES.xlsx      all tables in one workbook (15 sheets)
├── REPORT_MANIFEST.csv                 file list with MD5s, mapped to deliverables
├── session_info_final_report.txt
├── figures/
│   ├── FIG_01_model_performance_comparison.png
│   ├── FIG_02_observed_vs_predicted_headline.png
│   ├── FIG_03_rmse_r2_by_validation_year.png
│   ├── FIG_04_california_vs_florida_performance.png
│   ├── FIG_05_stable_standardized_coefficients.png
│   ├── FIG_06_state_interaction_coefficients.png
│   ├── FIG_07_sensitivity_comparison.png
│   ├── FIG_08a_residuals_by_year_and_state.png
│   ├── FIG_08b_residuals_vs_predicted_by_state.png
│   └── FIG_09_persistence_benchmark.png
└── tables/
    ├── KEY_NUMBERS.csv                 every number quoted above, with its source
    ├── TABLE_01_model_performance_comparison.csv
    ├── TABLE_02_performance_by_validation_year.csv
    ├── TABLE_03_state_performance_ca_fl.csv
    ├── TABLE_03b_observed_outcome_spread_by_state.csv
    ├── TABLE_04_stable_standardized_coefficients.csv
    ├── TABLE_04b_unpenalized_controls.csv
    ├── TABLE_05_state_interaction_coefficients.csv
    ├── TABLE_06_sensitivity_comparison_own_rows.csv
    ├── TABLE_06b_sensitivity_comparison_common_rows.csv
    ├── TABLE_07_residuals_by_year_and_state.csv
    ├── TABLE_08_robust_predictor_matrix.csv
    ├── TABLE_08b_robust_predictor_matrix_compact.csv
    ├── TABLE_09_persistence_benchmark.csv
    └── TABLE_10_reporting_constraints.csv
```

**Read-only sources:** `outputs/lasso_models/FINAL_*`, `outputs/lasso_sensitivity/`, `outputs/lasso_audit/`, `outputs/eda_v2/`, `outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md`.

### Reproduce

```bash
Rscript generate_final_lasso_report.R
```

The script aborts if `outputs/lasso_models/` does not record a `FINAL` run, or if the live MD5 of the v2 input workbook no longer matches the MD5 the FINAL run recorded. Every write is routed through a guard that refuses any path outside `outputs/lasso_final_report/`.
