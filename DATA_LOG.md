# WDS Final Project — Data Log & Codebook

**Research question:** What factors explain the divergence in homelessness rates between California and Florida from 2010 through 2025?

**Current stage:** Preliminary EDA. The broad directional trends are expected to remain similar as the data are refined, but exact values and estimated relationships may change. Current charts identify candidate explanations and do not establish causal effects.

**Unit of analysis:** State × Year (California and Florida only), 2010–2025.
**Master merge key:** `state` + `year`. Everyone's factor columns join onto this.

This file is the running log for the whole team. When you add or change data, **append a dated entry to the Changelog at the bottom** and, if it's a new variable, add a row to the Codebook.

---

## How the data is organized

- Canonical data lives in `/data/` as **CSV**, one file per contributor/sector, all keyed by `state` + `year`.
- The pretty spreadsheet (Google Sheet) is just a *view* for merging/presentation — the CSVs are the source of truth.
- Final regression joins all sector CSVs on `state` + `year`.

| File | Owner | Sector |
|---|---|---|
| `data/outcome_homelessness.csv` | Neev | Outcome variables (dependent) |
| `data/policy_social_services.csv` | Neev | Policy / Social Services (factors 30–36) |
| _(housing)_ | Autrin | Housing (1–10) |
| _(economic)_ | Vlad | Economic (11–18) |
| _(demographic + climate)_ | Samya | Demographic (19–25), Climate (26–29) |
| _(health + education)_ | Yuxuan | Health (37–39), Education (40–42) |

---

## Codebook — outcome variables (`data/outcome_homelessness.csv`)

| Column | Definition | Units | Source |
|---|---|---|---|
| `state` | California or Florida | text | — |
| `year` | Count year (PIT taken each January) | int | — |
| `total_homeless` | Total persons experiencing homelessness (Overall Homeless) | count | HUD PIT |
| `sheltered_homeless` | Sheltered total (ES + TH + SH) | count | HUD PIT |
| `unsheltered_homeless` | Unsheltered persons | count | HUD PIT |
| `state_population` | Resident population estimate for that year | persons | Census / FRED |
| `homeless_rate_per_10k` | `total_homeless / state_population * 10000` | rate | derived |

**The dependent variable for the regression is almost certainly `homeless_rate_per_10k`** (population-adjusted, comparable across the two states).

### Sources
- **PIT counts 2010–2024:** HUD "Point-in-Time Counts by State" (2007–2024) — https://www.nhipdata.org/hud-data (accessed 2026-07-20; saved as `data/raw/2007-2024-PIT-Counts-by-State.xlsx`)
- **PIT counts 2025:** HUD 2025 AHAR Part 1, official state file — https://www.huduser.gov/portal/datasets/ahar/2025-ahar-part-1-pit-estimates-of-homelessness-in-the-us.html (accessed 2026-07-20; saved as `data/raw/2007-2025-PIT-Counts-by-State.xlsb`)
- **Population:** FRED annual resident population — CAPOP (https://fred.stlouisfed.org/series/CAPOP), FLPOP (https://fred.stlouisfed.org/series/FLPOP) (saved in `data/raw/`)

### Reproducibility
Run `python3 scripts/build_outcome.py` from the `Final Project/` folder (requires `openpyxl` + `pyxlsb`). It reads only the committed files in `data/raw/` and regenerates `data/outcome_homelessness.csv` exactly (verified byte-identical). No hand-entered numbers.

---

## Codebook — policy / social services (`data/policy_social_services.csv`)

**All 7 policy factors complete (30, 31, 32, 33, 34, 35, 36).** Factors 30/34/35 are computed from HUD data; 31/32/33/36 are hand-collected/constructed with per-value citations in `data/raw/*_manual.csv`. Confidence varies — factor 36 is the weakest (see methodology §9).

| Column | Factor | Definition | Units | Source |
|---|---|---|---|---|
| `state` | — | California or Florida | text | — |
| `year` | — | Count year | int | — |
| `medicaid_expansion` | 30 | 1 if ACA Medicaid expansion in effect that year, else 0. CA effective 2014-01-01; FL never expanded. | 0/1 | KFF / ACA record |
| `tanf_max_benefit_3person` | 31 | Max monthly TANF cash benefit, single-parent family/AU of three. CA = CalWORKs MAP, Region 1, non-exempt; FL = statewide max (flat $303). | $/month | CBPP + LAO + CDSS/DPSS + Urban WRD |
| `ssi_state_supplement` | 32 | Monthly state SSP (add-on to federal SSI) for an aged/disabled individual living independently. CA has a large SSP; FL = $0 (no independent-living supplement). | $/month | LAO SSI/SSP reports + SSA |
| `anticamping_strictness` | 33 | **Constructed** 0–3 ordinal index of anti-camping enforcement strictness (see scheme in methodology §8). Higher = stricter. | 0–3 ordinal | Constructed from case law + statutes |
| `state_homeless_funding_per_capita` | 36 | Dedicated state homelessness-program appropriations ÷ population. **Lowest-confidence factor** (methodology §9). | $/resident | LAO + CA Auditor + FL budget |
| `shelter_beds_per_10k` | 34 | Year-round emergency + transitional + safe-haven beds ÷ population × 10,000 | rate | HUD HIC |
| `psh_beds_per_10k` | 35 | Year-round Permanent Supportive Housing beds ÷ population × 10,000 | rate | HUD HIC |
| `shelter_beds_total` | 34 | Raw shelter bed count (kept for transparency) | count | HUD HIC |
| `psh_beds_total` | 35 | Raw PSH bed count (kept for transparency) | count | HUD HIC |
| `state_homeless_funding_musd` | 36 | Raw appropriation in $ millions (kept for transparency) | $M | see factor 36 |

### Sources
- **Shelter & PSH beds (HIC):** HUD "Housing Inventory Count by State" (2007–2025), file `2007-2025-HIC-Counts-by-State.xlsx` — https://www.huduser.gov/portal/datasets/ahar/2025-ahar-part-1-pit-estimates-of-homelessness-in-the-us.html (accessed 2026-07-20; saved in `data/raw/`)
- **Population denominator:** same FRED CAPOP / FLPOP series as the outcome file.
- **Medicaid expansion dates:** ACA implementation record (CA expanded Jan 2014; FL has not expanded as of 2025) — cross-check KFF status tracker: https://www.kff.org/status-of-state-medicaid-expansion-decisions/
- **TANF benefit (factor 31):** hand-collected into `data/raw/tanf_max_benefit_manual.csv` with a per-year citation on every value. Primary sources: CBPP "Continued Increases in TANF Benefit Levels" 5-29-24 report, Appendix Table 1 (https://www.cbpp.org/sites/default/files/5-29-24tanf_rev2-26-25_0.pdf); LAO "CalWORKs Grants" handout 3/10/2016 (https://www.lao.ca.gov/handouts/socservices/2016/CalWORKs-Grants-031016.pdf); LA County DPSS 44-315 MAP levels eff. 10/1/2024 (https://my.dpss.lacounty.gov/public/en/home/epolicy/program/calworks/payments/calworks-maximum-aid-payment.html); Urban Institute Welfare Rules Database, Tables II.A.4 & L5 (https://wrd.urban.org/policy-tables) for Florida.
- **SSI state supplement (factor 32):** hand-collected into `data/raw/ssi_state_supplement_manual.csv` with per-year citations. Primary sources: LAO SSI/SSP budget reports — 2024-25 (report 4832, https://lao.ca.gov/Publications/Report/4832) and 2025-26 (report 4964, https://lao.ca.gov/Publications/Report/4964) — for CA SSP amounts, the 2009-2011 reduction to the federally-required minimum, and the Jan-2022/2023/2024 COLA increases; SSA "State Assistance Programs for SSI Recipients" for Florida's lack of an independent-living supplement.
- **Anti-camping index (factor 33):** constructed into `data/raw/anticamping_index_manual.csv` with per-year citations; coding scheme in methodology §8 below. Key legal sources: *Martin v. City of Boise* (9th Cir. 2018, cert denied Dec 2019); *City of Grants Pass v. Johnson*, U.S. Supreme Court, June 28 2024 (https://www.supremecourt.gov/opinions/23pdf/23-175_19m2.pdf); CA Executive Order N-1-24, July 25 2024 (https://www.gov.ca.gov/2024/07/25/); Florida HB 1365, signed Mar 20 2024, effective Oct 1 2024 (https://www.flsenate.gov/Session/Bill/2024/1365).
- **State homelessness funding (factor 36):** hand-collected into `data/raw/state_homeless_funding_manual.csv` with per-year confidence flags. Sources: LAO "Recent Homelessness Augmentations and Oversight" 2/22/2023 (https://lao.ca.gov/handouts/socservices/2023/Homelessness-Augmentations-Oversight-022223.pdf); LAO 2025-26 Spending Plan, report 5082 (https://lao.ca.gov/Publications/Report/5082); CA State Auditor 2023-102.1 (https://www.auditor.ca.gov/reports/2023-102-1/); FloridaPolicy.org budget summaries FY2023-24 & FY2024-25 (https://www.floridapolicy.org/). See methodology §9 for scope and heavy caveats.

### Reproducibility
Run `python3 scripts/build_policy.py` from the `Final Project/` folder (requires `openpyxl`). It reads only the committed files in `data/raw/` (HUD HIC, FRED population, and the cited TANF file) and regenerates `data/policy_social_services.csv` exactly. Factors 30/34/35 are computed from HUD data with no manual entry; factor 31 is transcribed from the cited primary sources (no single downloadable dataset exists — see note below).

---

## Methodology decisions & caveats

1. **⚠️ 2021 is unreliable — flag or exclude.** During COVID, HUD permitted CoCs to skip the unsheltered count. California's 2021 unsheltered dropped to **6,039** (vs ~114k the years on either side), producing an artificially low total (57,468) and rate (14.7). Florida's 2021 is also depressed. **Recommendation: exclude 2021 from the regression, or flag it and note the sensitivity.** Do not treat the 2021 total/rate as comparable to other years.

2. **Rate denominator / timing.** PIT counts are taken in **January**; population estimates are the annual figure for the same year. This is the standard approach — state it in the methods section. Population is in persons (FRED reports thousands; converted).

3. **Key finding already visible in the outcome data.** In 2010 CA and FL had nearly identical rates (~33 vs ~31 per 10k). They then diverged sharply: CA rose to ~47, FL fell to ~12. The research question is effectively **"why did the two states diverge after 2010?"** — explanatory factors must move in opposite directions across the states.

4. **2013 HIC shelter total — RRH removed.** In 2013 only, HUD's shelter total column was labeled `(ES,TH,RRH,SH)`, folding in Rapid Re-Housing beds. RRH is a permanent-housing intervention, not shelter, and no other year includes it. The build script subtracts the 2013 RRH bed column so `shelter_beds_per_10k` is consistently ES+TH+SH across all years.

5. **`medicaid_expansion` barely varies.** CA = 0 (2010–13) then 1 (2014+); FL = 0 throughout. This is nearly collinear with the state indicator, so in the regression it will mostly proxy "which state" rather than carry independent explanatory power — expect it to be unstable or dropped. Keep it, but interpret with that in mind.

6. **TANF measure choice (factor 31).** No single dataset gives an annual CA benefit because CalWORKs grants vary by **region** (high vs low cost) and by **exemption status**. We chose **CalWORKs MAP, Region 1 (high-cost counties — LA, SF Bay, San Diego), non-exempt tier**, as the most interpretable and representative measure for a CA-vs-FL comparison. Florida is a flat statewide $303 for a family of three (unchanged since the 1990s). Values are a representative annual (~July 1) snapshot; benefits change on discrete dates, so exact January-vs-July values differ by at most one step. **Two years are medium-confidence** (2017 = $704 and 2019 = $785) — derived from documented percentage changes rather than a directly-quoted dollar figure; all other years are directly sourced. Per-value citations live in `data/raw/tanf_max_benefit_manual.csv`.

7. **SSI supplement measure choice (factor 32).** We report the **state SSP add-on only** (not the combined SSI/SSP), for an aged/disabled individual living **independently** — the measure that captures state policy (federal SSI is identical in both states). California cut its SSP to the federally-required minimum ($160.72) during 2009-2011, froze it there for a decade, then raised it sharply in 2022-2024. Florida has **no** independent-living supplement (its Optional State Supplementation covers only assisted-living/adult-family-care residents), so FL = $0 every year. **Two years are medium-confidence** (2010 and 2011 = $171) — during the phased 2009-2011 reduction toward the $160.72 minimum; all other years are directly sourced. Note this factor, like Medicaid, is close to a state-level constant on the Florida side ($0) and slow-moving on the CA side, so it partly proxies "which state."

8. **Anti-camping index construction (factor 33) — the one subjective factor; team should review.** This is a **constructed** ordinal index, not observed data. Scale (additive, higher = stricter):
   - *Component A (statewide ban):* +2 if a statewide statutory ban on public camping/sleeping is in effect, else 0.
   - *Component B (local enforcement climate):* +1 if local anti-camping ordinances are common **and** enforcement is legally permitted; 0 if enforcement is broadly constrained by binding *Martin v. Boise* precedent (9th-Circuit "no-shelter" rule).

   Timing: regime in effect **as of ~January 1** (aligns with the January PIT count). Result:
   - **CA:** 1 (2010–18, permitted) → **0** (2019–24, constrained by *Boise*) → 1 (2025, freed by *Grants Pass* June 2024 + Newsom EO). No statewide ban ever.
   - **FL:** 1 (2010–24, local ordinances, never *Boise*-bound) → **3** (2025, HB 1365 statewide ban effective Oct 2024 + private cause of action Jan 2025).

   **Two decisions the team should sign off on:** (a) whether the *Boise* constraint should really lower CA's score (we say yes — the regime was less enforceable), and (b) whether **CA 2025 should be 2 instead of 1** to credit the July 2024 Newsom EO's active state-driven clearing (we kept 1 because the EO binds state agencies/land, not a general criminal ban). Both are one-line changes in `data/raw/anticamping_index_manual.csv`.

   **Caveat for the regression:** almost all variation in this factor is 2019–2025 — it is essentially constant 2010–2018 and the biggest moves land in 2024–25. Combined with the 2021 outcome problem, expect limited leverage; interpret its coefficient cautiously.

9. **State homelessness funding (factor 36) — LOWEST-CONFIDENCE FACTOR; read before using.**
   - **Scope:** major *dedicated state* (general-fund) *homelessness-specific* program appropriations, by fiscal-year start year. **Excludes** federal pass-through (HUD CoC/ESG), general affordable-housing money, and bond principal (e.g., CA No Place Like Home). CA programs counted: CalWORKs HSP, HEAP, CESH, HDAP, HHAP (all rounds), Homekey, Encampment Resolution Fund, Family Homelessness Challenge. FL: Challenge Grant, HHAG, staffing, plus the FY2024-25 Rapid Rehousing/Housing First allocation.
   - **Why it's shaky:** there is *no* authoritative annual series. California's own statewide tracking only covered FY2018-19 to 2020-21 and blended sources (it reported ~$2.3B–$3.8B "homelessness-focused" totals — **4–5× larger** than the dedicated-program sums here, because they fold in federal + ongoing + housing dollars). The scope choice alone swings the number several-fold.
   - **Confidence per cell is flagged in the raw file.** High: CA 2010–13 ($0) and 2020–23 and 2025; medium: CA 2018–19, FL 2023–24; **low (order-of-magnitude estimates): CA 2014–17 and ALL FL values 2010–2022.** CA funding is also very lumpy (one-time + capital), so the series is spiky by nature.
   - **What IS robust** (regardless of the exact small numbers): CA ramped from ~$0 (pre-2014) to a ~$73/capita peak (2021–22), then **collapsed to ~$2.7/capita by 2025** amid the state deficit; FL stayed tiny (<$1/capita) until an FY2024-25 jump to ~$4/capita. Notably, **in 2024–25 FL's per-capita funding briefly exceeded CA's** — a real reversal worth a sentence in the writeup.
   - **Recommendation:** use with explicit caveats, or consider a coarser robust version (e.g., a 0–3 funding-intensity tier) if the team wants to avoid false precision. The raw `funding_musd` column is retained so anyone can re-scope.

---

## TODO — remaining policy factors

**None — all 7 policy factors (30–36) are complete.** Open items are the two team sign-off decisions on the anti-camping index (methodology §8) and the recommendation to review factor 36's scope (methodology §9).

---

## Changelog

- **2026-07-20** — Neev — Built outcome dataset `data/outcome_homelessness.csv` (CA + FL, 2010–2025, 32 rows) from HUD PIT counts + FRED population. Documented 2021 data-quality issue and rate methodology. Outcome variables ready for team to merge against.
- **2026-07-20** — Neev — Added `data/policy_social_services.csv` with factors 30 (Medicaid expansion), 34 (shelter beds/10k), 35 (PSH beds/10k) via reproducible `scripts/build_policy.py` from HUD HIC + FRED. Raw HIC file saved to `data/raw/`. Documented 2013 RRH adjustment and Medicaid collinearity. Factors 31, 32, 33, 36 remain (see TODO).
- **2026-07-21** — Neev — Backfilled reproducibility for the outcome file: saved raw PIT sources to `data/raw/` and added `scripts/build_outcome.py` (regenerates `outcome_homelessness.csv` byte-identically). Added `requirements.txt`.
- **2026-07-21** — Neev — Added factor 31 (`tanf_max_benefit_3person`). FL flat $303 (WRD); CA = CalWORKs MAP Region 1 non-exempt, hand-collected with per-year citations in `data/raw/tanf_max_benefit_manual.csv`, wired into `build_policy.py`. Documented the CA measure choice and the two medium-confidence years (2017, 2019). Factors 32, 33, 36 remain.
- **2026-07-21** — Neev — Added factor 32 (`ssi_state_supplement`). CA SSP (individual, living independently): frozen $160.72 (2011-21) then COLAs to $239.94; FL = $0 (no independent-living supplement). Hand-collected with per-year citations in `data/raw/ssi_state_supplement_manual.csv`; generalized the manual-file loader in `build_policy.py`. Two medium-confidence years (2010, 2011). Factors 33, 36 remain.
- **2026-07-21** — Neev — Added factor 33 (`anticamping_strictness`), a constructed 0–3 index (scheme in methodology §8), in `data/raw/anticamping_index_manual.csv` with per-year legal citations. CA: 1→0 (Boise era 2019-24)→1 (2025); FL: 1→3 (HB 1365, 2025). Flagged two coding decisions for team sign-off. Only factor 36 remains.
- **2026-07-21** — Neev — Added factor 36 (`state_homeless_funding_per_capita` + raw `state_homeless_funding_musd`) in `data/raw/state_homeless_funding_manual.csv`. CA ~$0→$73/capita peak (2021)→$2.7 (2025); FL <$1 until ~$4/capita (2024-25). **Flagged as lowest-confidence factor** (methodology §9): scope choice swings values 4–5×, and CA 2014-17 + all FL 2010-22 are order-of-magnitude estimates. **All 7 policy factors (30–36) now complete.**
- **2026-07-21** — Neev — Received the full team-merged dataset `data/DSA Group 10.xlsx` (32 rows × 38 vars, all sectors). Superseded `combined_data.xlsx` → renamed `combined_data_OLD.xlsx`. NOTE: merged file's first column is an unnamed "California 2010" label (needs splitting into state+year); two trailing empty columns; **Housing sector (rent/home price/vacancy/etc.) is not in the file**; substance-use-rate column looks like placeholder data — flag during sanity checks.
- **2026-07-22** — Neev — Step 4 (multicollinearity): added `scripts/step4_multicollinearity.R` (readxl + corrplot + caret) → `outputs/step4_corr_heatmap.png` and `outputs/step4_high_corr_pairs.csv`. FINDING: multicollinearity is pervasive — **150 of 465 pairs (32%) have |r| ≥ 0.8**; caret would drop 23 of 31 variables. Expected given n=32 and the strong CA-vs-FL split (most variables just separate the two states). Do NOT blindly drop by the automatic rule; pick one representative per concept cluster before LASSO.
- **2026-07-23** — Chart/EDA update — Restated the project goal as explaining the post-2010 California–Florida divergence in homelessness rates. Selected six main preliminary EDA charts covering the outcome divergence, affordability, rental vacancy, housing stock, permitted supply, and bed capacity. Ordered guide: `charts/KEY_CHARTS.md`; reproducible list: `charts/key_chart_manifest.csv`.
