# Presentation outline — CA/FL homelessness project

_Section-by-section notes for a class presentation. Numbers are traceable to
`outputs/`; each section lists its source files._

> **Status note.** Sections 6 (Multiple Linear Regression) and 9 (Decision
> Tree / Random Forest) describe work that has **not been run yet**. They are
> written as "what we will do / what we have that is closest" so you can either
> run them before presenting or say plainly that they are the next step. Every
> other section describes completed, audited work.

---

## 1. Title + study overview

**Title:** *Persistence Over Predictors: Modeling Continuum-of-Care Homelessness
in California and Florida, 2010–2025*

**One-paragraph overview:**

California averages **42.6 homeless people per 10,000 residents**; Florida
averages **16.2** — a 2.6× gap between two large, warm, fast-growing,
high-migration states. This study asks how much of that gap is predictable from
measurable local conditions. Using HUD's official Point-in-Time counts at
**Continuum-of-Care (CoC) geography** — the level at which homelessness is
actually measured and funded — we built a panel of **887 CoC-years across 70
CoCs** and tested whether housing, economic, demographic, policy, and
service-capacity conditions in year *t* predict the homelessness rate in year
*t+1*.

**The three headline findings:**

1. A factor model predicts far better than a state-and-time baseline (R² 0.19 → 0.64).
2. But it adds **nothing** once you know each CoC's own prior-year rate (R² 0.86 from persistence alone).
3. Shelter-bed capacity is one of the strongest predictors — and is almost certainly a *response* to homelessness, not a cause.

---

## 2. Why this study

**Personal entry point (2–4 sentences, then move on):**

> I live in California, where homelessness is visible enough that most residents
> have a theory about it — housing costs, weather, policy, services drawing
> people in. I wanted to know whether any of those theories hold up against data.
> Florida made the natural comparison: also large, also warm, also growing fast,
> also a magnet for migration — and yet its homelessness rate is about a third of
> California's.

**Why this comparison is analytically good:** the two explanations people reach
for first — climate and in-migration — apply to *both* states. Whatever drives
the divergence has to be something that differs between them, which points at
housing markets, policy, and service systems. A 50-state regression would blur
this out.

**Why CoC level:** HUD measures homelessness and allocates funding by Continuum
of Care. Most public analysis is state-level, which hides the fact that **CoCs
within California vary more than California differs from Florida** — the range
runs from about 9 to 141 per 10,000.

**Why prediction, not explanation:** claims about homelessness drivers usually
come from cross-sectional correlations with no out-of-time validation. We asked
the harder question: given year *t*, can we predict year *t+1* on data the model
has never seen?

---

## 3. Data acquisition + overview

| Layer | Size | Content |
|---|---|---|
| State panel | 32 state-years × 63 variables | CA + FL, 2010–2025 |
| County raw panel | ~2,000 county-years (125 counties × 16 years) | housing, economic, demographic |
| **Final model input** | **887 CoC-years × 47 columns** | 70 CoCs, 2012–2025 target years |
| Funding extract | 23,039 transactions | USAspending CFDA 14.267 |

**Final input structure (`CA_FL_LASSO_MODEL_INPUT_v2.xlsx`):**

- 6 identifier columns (never enter the model)
- 1 target: `target_homeless_rate_per_10k`
- 2 unpenalized controls: state, time index
- **38 candidate predictors**
- **0 missing values**

**Predictor domains:** housing supply and permits · housing affordability and
cost burden · home-price indices · income, poverty, GDP, unemployment ·
population, density, migration, births/deaths · policy (minimum wage, Medicaid
expansion, anti-camping strictness, TANF, SSI) · HUD service capacity (shelter
and permanent-supportive-housing beds).

**The key structural move:** HUD observes homelessness at **CoC** geography, not
county. We used HUD's FY2024 county-to-CoC crosswalk plus **ACS 2024 census-tract
population shares** to allocate county predictors to CoCs — including fractional
allocation for the 8 CoCs that split a county. PIT and HIC records were merged as
*columns* onto CoC-years, not stacked as extra rows. That's why ~2,000
county-years became 887 CoC-years.

---

## 4. Data cleaning process

**Layered approach:** preserve raw files → standardize identifiers/types/units →
validate domains → build analysis-specific panels.

**Rules we held to:**

- Never fabricate, interpolate, or substitute zero for a missing value
- Yellow Excel cells = unavailable, not zero
- Don't mix definitions, denominators, geographies, or data vintages without documenting why
- Don't auto-delete or winsorize outliers — check them against source and document
- Fit any learned preprocessing (scaling, imputation) on training years only

**Specific decisions worth presenting:**

- **2021 PIT excluded as a modeling target.** COVID disrupted enumeration, so 2021 is not comparable. This is why we have 13 usable target years and 8 validation folds, not 14 and 9.
- **Census vintage boundary.** Housing-units-per-capita uses 2019-vintage estimates through 2019 and 2025-vintage from 2020. 2020 supply growth is left missing because computing it would cross the boundary.
- **Foreclosure rate left blank.** No free, comparable 2010–2025 state series was verified. We did *not* substitute mortgage delinquency.

**The v1 → v2 source audit (the most important cleaning step).** Every inherited
variable marked "source verification needed" was individually audited and either
verified, rebuilt from an official series, or **dropped**:

| Kept / rebuilt | Dropped (no verifiable source) |
|---|---|
| Anti-camping policy index | Substance-use-disorder rate |
| TANF benefit, SSI supplement | Serious-mental-illness rate |
| Labor-force participation (rebuilt from BLS/FRED) | Uninsured rate, student debt, tuition |
| | Age shares, household size |

**Good slide:** the dropped substance-use series looked like this —
`FL: 7.6 7.7 7.8 7.9 8.0 8.1 8.2 8.3 8.4` — a perfectly monotone ramp for nine
years. That's interpolation, not survey data. We dropped it rather than model it.

**Boundary reconciliation:** FY2024 crosswalk has 71 CoCs → boundary-matched
panel 71 CoCs / 974 rows → final complete-case 70 CoCs / 887 rows. CA-528 costs
3 historical rows; FL-518 is excluded (11 rows) for lacking a usable FHFA
home-price index — and we ran a sensitivity that restores it.

_Sources: `CHANGELOG_v1_to_v2.md`, `DECISION_LOG.md`, `DATA_SOURCES_AND_ASSUMPTIONS.md`, `outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md`_

---

## 5. EDA + EDA findings

_Sources: `outputs/eda_v2/EDA_FINDINGS_v2.md` (10 plots, 10 tables), `outputs/qa_v2/QA_AUDIT_v2.md`_

**Independent QA result: 17 PASS / 1 non-blocking warning / 0 FAIL.**

| Finding | Value | What we did about it |
|---|---|---|
| Target skewness | ~1.77 | Ran a log-target sensitivity (it performed worse; kept raw) |
| Highly correlated pairs | **18 pairs at \|r\| ≥ 0.80** | Report predictors as cluster markers, not operative variables |
| Constant / near-zero-variance predictors | none | — |
| Target leakage | none detected | — |
| Missing or infinite values | none | — |
| Extreme observations | flagged | Kept — not winsorized, not deleted |

**Correlated clusters to name on a slide:** TANF ↔ SSI · permit counts ↔ permit
dollar value · overall ↔ child poverty · minimum wage ↔ TANF ↔ rent · domestic
migration ↔ population growth · CoC geographic scale (log population ↔ density ↔
contributing counties).

**Why this matters later:** LASSO picks one member of a correlated pair
near-arbitrarily. We demonstrated this empirically — `population_density` drops
from selection frequency 1.00 to 0.00 in one sensitivity while
`contributing_counties` rises from 0.75 to 1.00. Two encodings of the same thing
trading places.

---

## 6. Multiple linear regression ⚠️ NOT YET RUN

**Be honest about this in the presentation.** We have two things that are
closely related but no dedicated MLR stage:

| What we have | RMSE | R² |
|---|---:|---:|
| **State + linear-time baseline** (OLS) | 21.93 | 0.190 |
| **`no_hidden` network** = OLS on all 40 inputs | 16.06 | 0.565 |

The second is genuinely informative: a zero-hidden-layer neural network *is*
unregularized least squares, and it scores **worse than the LASSO** (16.06 vs
14.69) — because with 38 predictors and 18 correlated pairs, unpenalized OLS
overfits exactly where the penalty helps.

**What a proper MLR section would add:** a small, theory-chosen set of
predictors (say 5–8, picked before looking at results), fit with `lm()`, reported
with coefficients, standard errors, and p-values. That's the one place in this
project where p-values are legitimate — see the note in section 8.

**If asked why we skipped it:** LASSO with all predictors and OLS with all
predictors are both already in the results; a hand-picked MLR is a
*interpretability* exercise, not a prediction one.

---

## 7. LASSO

_Sources: `LASSO_FINAL_RESULTS.md`, `outputs/lasso_models/`, `outputs/lasso_sensitivity/`, `outputs/lasso_audit/`_

**Design (the part worth emphasizing):**

- **Rolling-origin validation on 8 future years:** 2017–2020, 2022–2025. Never a random split — random splits leak temporal structure.
- Nested **forward-chaining** lambda tuning inside each training window
- Scaling and tuning fit on **training years only**
- Training windows expand 332 → 817 rows; 555 rows scored total
- Both `lambda.min` and `lambda.1se`; raw and log targets

**Results:**

| Model | RMSE | MAE | R² |
|---|---:|---:|---:|
| Separate-state composite (*not one model*) | 13.90 | 10.18 | 0.674 |
| **Pooled LASSO + state interactions** (headline) | **14.69** | 10.14 | **0.636** |
| Pooled LASSO | 15.30 | 10.16 | 0.606 |
| State + time baseline | 21.93 | 14.98 | 0.190 |

**Six predictors stable across every sensitivity sample** (same sign, ≥50% of folds):

| Predictor | Direction |
|---|---|
| PSH beds per 10k | **+** |
| Temporary beds per 10k | **+** |
| CoC log population | − |
| Housing cost-burdened households % | **+** |
| Annual home-price change % | − |
| International migration rate | − |

**12 of 38 predictors were never selected in any fold.**

**Independent audit: 93 PASS / 7 WARNING / 0 FAIL.** All 128 exported metrics
recomputed from raw predictions and matched to 6.4 × 10⁻¹⁴. All seven warnings
concerned *wording*, not math.

**Seven sensitivity analyses:**

| Sensitivity | Result |
|---|---|
| Exclude split-county CoCs | No material change |
| Only continuously observed CoCs | No material change |
| Restore FL-518 (drop FHFA index) | No material change |
| **Remove shelter-bed predictors** | **RMSE 14.69 → 17.82; ~⅓ of R² lost** |
| **Add prior-year rate** | **All 38 factors shrink to exactly zero** |

---

## 8. Neural network

_Sources: `NN_FINDINGS.md`, `outputs/neural_net/`_

**Followed the Module 7 lecture recipe**, adapted in four ways:

| Lecture | Ours | Why |
|---|---|---|
| Classification, softmax, cross-entropy | Regression: 1 linear output, MSE loss | Continuous target |
| `sample(n, 10000)` random split | Rolling origin, same 8 years | No random splits; makes LASSO comparison valid |
| `validation_split = 0.15` (random) | Most recent training year held out | Random inner split would leak future years |
| No scaling needed | X and y standardized on training rows only | Project rule |

**Five architectures**, including the lecture's 16→8 unchanged and a
zero-hidden-layer anchor. 5 random seeds per fold, ensembled. 445 model fits.

**Result — the network beat the LASSO on factors:**

| Model | RMSE | R² |
|---|---:|---:|
| NN `wide_32_16_drop` | **12.64** | **0.731** |
| NN `class_16_8` (lecture) | 12.92 | 0.719 |
| LASSO + state interactions | 14.69 | 0.636 |
| NN `no_hidden` (linear) | 16.06 | 0.565 |

The zero-layer anchor proves the gain is **nonlinearity**, not the setup.

**But two honest caveats:**

1. **Much of it is ensembling.** Single-seed RMSE ranges 13.2–16.3; the 5-seed ensemble beats the *best* single seed in 3 of 5 cases. An unlucky seed loses to the LASSO.
2. **On persistence the network loses.** Prior rate alone: 8.93. Prior rate + 38 factors: **10.05** — *worse*. The LASSO zeroed those factors and paid nothing; a network can't discard an input.

**Note on p-values:** LASSO produces none, and neural networks produce none.
Penalization biases coefficients, and variables selected on the same data can't
be tested on it. We used **selection frequency across 8 independent training
windows** plus sign consistency instead — verified out of sample, which a
single-fit p-value never is.

---

## 9. Decision tree / random forest ⚠️ NOT YET RUN

**Planned, not done.** Say this plainly.

**What it would test — and why it's the most interesting remaining model:**
tree ensembles sit exactly between the two families already run. Like LASSO they
*can* ignore useless predictors; like the neural network they capture
nonlinearity. So they directly test whether our two findings are universal or
specific to those two methods:

- Will a random forest also find the factors worthless once prior rate is available?
- Will it match the network's nonlinear gain without the seed instability?

**Constraints it must follow to stay comparable:** same v2 input, same 8
validation years, training-only preprocessing, no random row splits, RMSE/MAE/R²
reported identically, no causal language.

---

## 10. Comparing different models

**What we can compare today** (identical 555 rows, identical folds):

| Family | Best model | RMSE | R² |
|---|---|---:|---:|
| Neural network | `wide_32_16_drop` (5-seed ensemble) | **12.64** | **0.731** |
| Penalized linear | LASSO + state interactions | 14.69 | 0.636 |
| Unpenalized linear | `no_hidden` (OLS, 40 inputs) | 16.06 | 0.565 |
| Naive | State + time baseline | 21.93 | 0.190 |

**On the persistence rows (485 rows, 7 folds):**

| Model | RMSE | R² |
|---|---:|---:|
| LASSO: state + time + prior rate | **8.89** | 0.866 |
| NN: prior rate alone | 8.93 | 0.865 |
| LASSO: prior rate only | 9.12 | 0.859 |
| NN: prior rate + 38 factors | 10.05 | 0.829 |

**The comparison slide people will remember:**

> The neural net wins where the LASSO is weak (nonlinear structure in the
> factors). The LASSO wins where the neural net is weak (knowing what to throw
> away). **Both agree the factor set adds nothing beyond persistence** — reached
> from opposite directions.

**Trade-off framing, not a ranking:** the network predicts better on factors but
is stochastic, uninterpretable, and gives no per-predictor quantities. The LASSO
is deterministic, tells you *which* predictors matter, and degrades gracefully
when predictors are useless. Everything this project says about *which* factors
matter comes from the LASSO.

_Still missing: Ridge, Elastic Net, Random Forest, XGBoost._

---

## 11. Overall findings

1. **Local conditions predict next-year homelessness far better than state and time alone** — R² 0.19 → 0.64 (LASSO) or 0.73 (neural net), out of time, across 8 future years.

2. **But they add nothing once you know last year's rate.** Prior rate alone reaches R² 0.86. The LASSO shrank all 38 factors to exactly zero; the neural net got *worse* when given them. Homelessness is dominated by its own persistence.

3. **Roughly a third of the model's accuracy comes from shelter-bed capacity** — which is plausibly built *in response to* homelessness. Positive bed coefficients must never be read as beds causing homelessness.

4. **Excluding service capacity, housing-market composition carries the most consistent signal:** lower homeownership, more housing units per resident, higher cost burden, weaker home-price growth — each selected in 100% of folds.

5. **Findings are robust to every contested sample choice** — split-county allocation, intermittently observed CoCs, the FL-518 exclusion. Prediction correlations 0.93–0.997.

6. **No stable claim that one state is better modeled.** Florida's lower RMSE just reflects its narrower outcome distribution.

---

## 12. Limitations

**Data construction**

1. 2021 PIT excluded — COVID broke comparability
2. FY2024 CoC boundaries applied retrospectively to 2010–2025; historical denominators are documented estimates, not observed values
3. FL-518 excluded from the primary model (sensitivity restores it, no material change)
4. 8 CoCs split a county; their predictors are fractional ACS tract-share estimates
5. 8 `state_*` predictors repeat identically across every CoC in a state — the unpenalized controls absorb most of what they could contribute, so their non-selection is **uninformative**
6. Small panel: 2 states, 70 CoCs, 13 target years, 887 rows

**Inference**

7. **No causal claim is supported.** Everything is a predictive association.
8. Service-capacity predictors are plausibly endogenous to the outcome
9. Attribution within correlated clusters is not identified (18 pairs at |r| ≥ 0.80)
10. Pooled R² is **not** within-state explanatory power — the baseline's pooled R² is 0.190 but within-state R² is *negative* in both states (CA −0.126, FL −0.072)
11. "Best model" is criterion-dependent — our headline wins on RMSE but ranks 4th of 4 on MAE
12. Neural-net results depend on a 5-seed ensemble; a single run won't reproduce them
13. Ridge, Elastic Net, Random Forest, and XGBoost are not yet run

**Known gaps in variable coverage:** no climate variables at CoC level (requested,
never built — no station-to-county aggregation rule); no substance-use, mental
health, or uninsured measures (dropped — SAMHSA NSDUH publishes overlapping
2-year estimates, not annual series); no CoC-level funding (USAspending coverage
starts 2013 and recipient location ≠ service area).

---

## 13. AI usage

**Be specific and honest — this reads far better than a vague disclosure.**

**What AI was used for:**

- **Pipeline development.** R scripts for data acquisition, county→CoC allocation, model fitting, and report generation were written with Claude Code.
- **Parallel specialist agents.** Separate agents handled the sensitivity analyses, an independent audit of the main LASSO, and final report assembly. Each was restricted to its own files so no agent could overwrite another's work.
- **Independent verification.** The audit agent never read the modeling agent's reasoning — it recomputed all 128 exported metrics directly from the raw predictions and reconciled them against the input workbook.

**What was verified by hand:**

- MD5 hash of the model input checked at every stage
- Audit results independently re-tallied (93 PASS / 7 WARNING / 0 FAIL confirmed)
- Sensitivity harness confirmed to reproduce the main run digit-for-digit
- Report numbers spot-checked against source CSVs — **one transcription error found and corrected** (a selection frequency reported as 0.88 that its own tables showed as 1.00)

**What AI did *not* do:** choose the research question, decide which variables
to drop, or decide what the findings mean. Every data-quality decision is
recorded in `DECISION_LOG.md` and `CHANGELOG_v1_to_v2.md` with a human rationale.

**Worth saying out loud:** the AI-generated first prediction was that the neural
network would *lose* to the LASSO on data this small. It won. The prediction was
recorded, then corrected when the run finished — that's in the project history.

---

## 14. Citations (databases used)

**Homelessness outcomes and service capacity**
- U.S. Department of Housing and Urban Development — Point-in-Time (PIT) Counts by CoC, 2007–2025
- HUD — Housing Inventory Count (HIC) by CoC
- HUD — FY2024 CoC–County crosswalk and CoC boundary files (`huduser.gov`)

**Demographics and housing**
- U.S. Census Bureau — American Community Survey 5-year estimates (incl. B25064, B25071); census-tract population for split-county allocation
- U.S. Census Bureau — Population Estimates Program (PEP), 2019 and 2025 vintages
- U.S. Census Bureau — TIGER/Line shapefiles, 2024

**Housing market**
- Federal Housing Finance Agency (FHFA) — House Price Index, county level
- Zillow — median sale price and ZORI rent series
- Eviction Lab (Princeton) — eviction filing rates and renter covariates, 2000–2018

**Economic**
- U.S. Bureau of Economic Analysis — CAINC1 personal income; real GDP by county
- U.S. Bureau of Labor Statistics — labor-force participation (via FRED: LBSSA06, LBSSA12)
- Federal Reserve Bank of St. Louis (FRED) — CPI-U and distributed series

**Policy and funding**
- USAspending.gov — Assistance Listing (CFDA) 14.267 transaction extract, 23,039 records
- KFF — Medicaid expansion status
- CBPP — TANF benefit levels
- State legislative and executive sources (`flsenate.gov`, `gov.ca.gov`, `lao.ca.gov`) — anti-camping policy index
- U.S. Supreme Court — *Martin v. Boise* / *Grants Pass* materials for the enforcement-climate component

**Cite the original producer even when accessed through FRED or another
distributor.** Full URLs, coverage windows, and limitations are in
`DATA_SOURCES_AND_ASSUMPTIONS.md` and `DATA_LOG.md`.
