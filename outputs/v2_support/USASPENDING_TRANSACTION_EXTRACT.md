# USAspending CFDA 14.267 — Transaction-Level Extract and Award vs. Transaction Reconciliation

**Program:** Assistance Listing / CFDA **14.267 — Continuum of Care Program** (HUD)
**Scope:** Recipients located in **CA** and **FL**, action years **2013–2025** (query window 2010–2025)
**Produced:** 2026-07-24 · read-only companion to the v2 owner's award-level extract; no v2-owner file was modified.

## Files

| File | Contents |
|------|----------|
| `fetch_usaspending_transactions_cfda_14_267.R` (repo root) | Fetch + reconcile script (this deliverable's owner) |
| `raw_data/usaspending_cfda_14_267/txn_<ST>_<YEAR>_p<NNN>.json` | **Verbatim API responses** — one file per state × calendar year × page (250 pages) |
| `outputs/v2_support/usaspending_cfda_14_267_transactions_CA_FL_2010_2025.csv` | Processed transaction extract (23,039 rows) |
| `outputs/v2_support/usaspending_award_vs_transaction_annual_totals.csv` | Annual award-vs-transaction comparison |
| `outputs/v2_support/_fetch_cache/part_<ST>_<YEAR>.csv` | Resumable per-partition fetch cache (intermediate) |

The pre-existing v2-owner files — `raw_data/fetch_usaspending_coc_awards.R` and
`raw_data/usaspending_coc_program_awards_CA_FL_2010_2025.csv` — are left untouched; **both versions are retained.**

## Method

- **Endpoint:** `POST /api/v2/search/spending_by_transaction/`. The `Transaction Amount`
  field returned by this endpoint is the transaction-level **`federal_action_obligation`**.
- **Filters mirror the award-level extract exactly** so any difference is attributable
  to award-vs-transaction methodology, not to a different record universe:
  `award_type_codes = [02,03,04,05]`, `program_numbers = ["14.267"]`,
  `recipient_locations = [{country:USA, state:CA|FL}]`.
- **Partitioning:** by recipient state × calendar year of `Action Date`. Each partition
  stays far below the transaction-search pagination ceiling, and calendar action-year is
  exactly the axis on which transactions are bucketed.
- **Completeness check:** the paginated fetch returned **16,975 CA + 6,064 FL = 23,039**
  rows, exactly matching `spending_by_transaction_count`. No rows were dropped.

### Pitfall documented: `internal_id` is award-level, not transaction-level

In `spending_by_transaction`, both `internal_id` and `generated_internal_id`
(`ASST_NON_<awardid>_<agency>`) identify the **parent award**, not the individual
transaction — each has exactly 14,575 distinct values (≈ the award count), while there are
23,039 transactions. They must **not** be used to de-duplicate transactions (doing so
silently collapses ~8,500 real federal actions). No stable per-transaction id is exposed by
this endpoint (`Mod` is null for many actions), so every returned row is retained and the
row count is validated against the count endpoint instead.

## Grand totals

| Measure | Value | Records |
|---|---:|---:|
| Award-level obligation (Σ `award_amount`) | **$6,232,028,175** | 14,131 awards |
| Transaction-level (Σ `federal_action_obligation`) | **$6,218,833,387** | 23,039 transactions |
| Difference (txn − award) | −$13,194,788 (−0.2%) | |
| Deobligating (negative) transactions | −$820,603,392 | 7,685 |
| Positive obligating transactions | | 15,340 |

The grand totals are within 0.2% because, for financial-assistance awards, the
`spending_by_award` **"Award Amount" is itself the award's net summed
`federal_action_obligation`.** Award-level reconciliation confirms this:
**13,996 of 14,131 awards (99.0%)** have `award_amount` equal (within $1) to the net sum of
their own transactions in this extract.

## Annual comparison

Award obligations are bucketed by the **period-of-performance start-date year**;
transaction obligations by the **action-date year**. `federal_action_obligation` is summed.

| Year | Award $ (start-year) | Txn $ (action-year) | Txn − Award | Deoblig. txns |
|-----:|---------------------:|--------------------:|------------:|--------------:|
| 2013 | 311,698,334 | 334,649,457 | +22,951,123 | 142 |
| 2014 | 302,628,539 | 347,892,463 | +45,263,924 | 66 |
| 2015 | 327,253,790 | 379,164,547 | +51,910,758 | 620 |
| 2016 | 325,165,394 | 353,189,587 | +28,024,193 | 531 |
| 2017 | 347,811,352 | 408,297,365 | +60,486,013 | 797 |
| 2018 | 383,449,561 | 387,913,551 | +4,463,989 | 515 |
| 2019 | 438,561,947 | 479,686,115 | +41,124,168 | 663 |
| 2020 | 436,393,872 | 462,987,423 | +26,593,551 | 846 |
| 2021 | 474,757,103 | 564,892,369 | +90,135,266 | 239 |
| 2022 | 536,028,741 | 465,657,300 | −70,371,440 | 1,262 |
| 2023 | 626,387,299 | 713,624,220 | +87,236,922 | 130 |
| 2024 | 737,995,008 | 562,527,575 | −175,467,433 | 1,229 |
| 2025 | 796,958,404 | 758,351,416 | −38,606,988 | 645 |
| 2026 | 143,065,219 | 0 | −143,065,219 | — |

(Full precision in `usaspending_award_vs_transaction_annual_totals.csv`.)

## Why the annual totals differ

Even though the **grand** totals nearly match, the **annual** totals diverge for four
compounding reasons:

1. **Different time axes.** Award rows are dated by *period-of-performance start*; each
   transaction is dated by its own *action date*. A renewal whose PoP starts in January is
   frequently obligated the prior September, shifting dollars between calendar years.

2. **Award-level netting vs. transaction-level gross flows.** `award_amount` folds every
   obligation *and* deobligation into a single figure placed in the award's start year. The
   transaction view spreads the **gross** +$ obligations and −$ deobligations across the
   years they actually occurred. There are **7,685 deobligating transactions totaling
   −$820.6M**; the years absorbing the most deobligations (2022: 1,262; 2024: 1,229) are
   exactly the years where the transaction total falls **below** the award total.

3. **Period-of-performance boundary at the window edge.** **139 awards ($143.1M)** have a
   PoP start-year of **2026**; their obligating transactions land in 2024–2025 (in-window),
   so they appear only on the award axis in 2026 and inflate the transaction axis in
   2024–2025 — a large part of those years' negative differences.

4. **USAspending assistance coverage begins ~FY2013.** Both files are empty before 2013;
   no 14.267 transactions exist for 2010–2012.

### Worked example — award `CA0042L9T011205` (City & County of San Francisco)

`award_amount = $672,257.90`, `start_date = 2013-12-01`.

| Action year | Σ `federal_action_obligation` |
|---:|---:|
| 2013 | +849,629.00 (obligation) |
| 2016 | −170,046.10 (deobligation) |
| 2019 | −7,325.00 (deobligation) |
| **Net** | **672,257.90** = `award_amount` |

The award view books the full **net** $672,258 in **2013**. The transaction view books the
**gross** $849,629 in 2013 and pulls 2016 and 2019 down by later deobligations. Summed over
all years the two agree; year by year they cannot.

## Caveats for the v2 builder

- **Recipient-location geography, not CoC geography.** Records are filtered by the
  recipient's physical state (CA/FL), mirroring the award file. Some `award_id` values carry
  a non-CA/FL CoC prefix (e.g. an `AZ-` CoC award to a CA-located recipient). Do not read
  `award_id` prefix as the CoC of service.
- The residual −$13.2M grand-total gap (0.2%) comes from the 135 awards whose `award_amount`
  does not exactly equal their in-extract transaction sum (award totals can include actions
  outside the per-transaction recipient-location/window filters).
- `pit_count_caution_flag` and other analysis conventions are unaffected; this extract adds a
  spending series only.

## Reproduction

```bash
Rscript fetch_usaspending_transactions_cfda_14_267.R
```

Idempotent: completed state-years reload from `outputs/v2_support/_fetch_cache/`; delete the
extract CSV (and, to refetch from the API, the cache) to rebuild. Live API calls are retried
with backoff on transient 5xx / empty replies.
