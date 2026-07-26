# ---------------------------------------------------------------------------
# fetch_usaspending_transactions_cfda_14_267.R
#
# Transaction-level companion to the v2 owner's award-level extract
# (raw_data/fetch_usaspending_coc_awards.R ->
#  raw_data/usaspending_coc_program_awards_CA_FL_2010_2025.csv).
#
# This script pulls TRANSACTION-level records (each obligating / deobligating
# federal action, i.e. federal_action_obligation) for CFDA/Assistance Listing
# 14.267 (HUD Continuum of Care Program) for CA and FL recipients, then
# compares annual transaction obligations against the award-level totals.
#
# It never modifies the v2 owner's script or award-level CSV.
#   - Raw API responses  -> raw_data/usaspending_cfda_14_267/
#   - Processed outputs  -> outputs/v2_support/
# ---------------------------------------------------------------------------

options(stringsAsFactors = FALSE)
project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) .libPaths(c(local_r_lib, .libPaths()))
library(httr)
library(jsonlite)
library(dplyr)

`%||%` <- function(a, b) if (is.null(a)) b else a

# --- Paths -----------------------------------------------------------------
raw_dir <- file.path(project_root, "raw_data", "usaspending_cfda_14_267")
out_dir <- file.path(project_root, "outputs", "v2_support")
# raw_dir holds ONLY verbatim API responses; the resumable per-partition fetch
# cache is a processed intermediate and lives under the processed output tree.
cache_dir <- file.path(out_dir, "_fetch_cache")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

award_file <- file.path(
  project_root, "raw_data",
  "usaspending_coc_program_awards_CA_FL_2010_2025.csv"
)
txn_extract_file <- file.path(
  out_dir, "usaspending_cfda_14_267_transactions_CA_FL_2010_2025.csv"
)
compare_file <- file.path(
  out_dir, "usaspending_award_vs_transaction_annual_totals.csv"
)

# Mirror the v2 owner's filters exactly so any annual-total difference is
# attributable to the award-vs-transaction methodology, not to a different
# universe of records.
AWARD_TYPE_CODES <- list("02", "03", "04", "05")
PROGRAM_NUMBERS  <- list("14.267")
STATES <- c("CA", "FL")
# Partition by recipient state x calendar year: each partition stays far below
# the transaction-search pagination ceiling, and action_date calendar year is
# exactly the axis we bucket transactions on. Window matches the award file
# (2009-10-01 .. 2025-12-31), i.e. calendar action years 2010-2025.
YEARS <- 2010:2025

# --- Transaction fetch -----------------------------------------------------
fetch_state_year <- function(state, year) {
  # Per-partition cache makes the run resumable: a completed state-year is
  # reloaded instead of re-hitting the (occasionally flaky) API.
  part_cache <- file.path(cache_dir, sprintf("part_%s_%d.csv", state, year))
  if (file.exists(part_cache)) {
    message(state, " ", year, ": cached (", part_cache, ")")
    df <- read.csv(part_cache, colClasses = c(award_id = "character",
                                              modification_number = "character"))
    if (nrow(df) == 0) return(NULL)
    return(df)
  }
  page <- 1
  collected <- list()
  repeat {
    body <- list(
      filters = list(
        award_type_codes = AWARD_TYPE_CODES,
        program_numbers = PROGRAM_NUMBERS,
        time_period = list(list(
          start_date = sprintf("%d-01-01", year),
          end_date = sprintf("%d-12-31", year)
        )),
        recipient_locations = list(list(country = "USA", state = state))
      ),
      fields = list(
        "Award ID", "Recipient Name", "Transaction Amount",
        "Action Date", "Mod", "Awarding Agency"
      ),
      page = page,
      limit = 100,
      sort = "Action Date",
      order = "asc"
    )
    # USAspending occasionally returns transient 5xx errors; retry with backoff.
    attempt <- 1
    max_attempts <- 6
    repeat {
      resp <- tryCatch(
        POST(
          "https://api.usaspending.gov/api/v2/search/spending_by_transaction/",
          body = toJSON(body, auto_unbox = TRUE),
          content_type_json(),
          encode = "raw",
          timeout(120)
        ),
        error = function(e) structure(list(err = conditionMessage(e)),
                                      class = "fetch_error")
      )
      ok <- !inherits(resp, "fetch_error") && status_code(resp) == 200
      if (ok) break
      detail <- if (inherits(resp, "fetch_error")) resp$err else
        paste0("HTTP ", status_code(resp))
      if (attempt >= max_attempts) {
        stop(
          "Transaction request failed for ", state, " ", year,
          " page ", page, ": ", detail, " after ", max_attempts, " attempts"
        )
      }
      message("  ", detail, " for ", state, " ", year,
              " page ", page, "; retry ", attempt, "/", max_attempts - 1)
      Sys.sleep(3 * attempt)
      attempt <- attempt + 1
    }
    txt <- content(resp, as = "text", encoding = "UTF-8")

    # Persist the raw API response page verbatim.
    raw_path <- file.path(
      raw_dir, sprintf("txn_%s_%d_p%03d.json", state, year, page)
    )
    writeLines(txt, raw_path)

    parsed <- fromJSON(txt, simplifyVector = FALSE)
    results <- parsed$results
    if (length(results) == 0) break

    rows <- lapply(results, function(r) {
      data.frame(
        internal_id = r[["internal_id"]] %||% NA_integer_,
        generated_internal_id = r[["generated_internal_id"]] %||% NA_character_,
        award_id = r[["Award ID"]] %||% NA_character_,
        recipient_name = r[["Recipient Name"]] %||% NA_character_,
        recipient_state = state,
        action_date = r[["Action Date"]] %||% NA_character_,
        modification_number = r[["Mod"]] %||% NA_character_,
        federal_action_obligation = as.numeric(r[["Transaction Amount"]] %||% NA),
        stringsAsFactors = FALSE
      )
    })
    collected[[length(collected) + 1]] <- bind_rows(rows)

    has_next <- isTRUE(parsed$page_metadata$hasNext)
    message(state, " ", year, " page ", page, ": ",
            length(results), " txns, hasNext=", has_next)
    if (!has_next) break
    page <- page + 1
    Sys.sleep(0.25)
  }
  part <- if (length(collected) == 0) {
    data.frame(
      internal_id = integer(0), generated_internal_id = character(0),
      award_id = character(0), recipient_name = character(0),
      recipient_state = character(0), action_date = character(0),
      modification_number = character(0),
      federal_action_obligation = numeric(0)
    )
  } else {
    bind_rows(collected)
  }
  write.csv(part, part_cache, row.names = FALSE)
  if (nrow(part) == 0) return(NULL)
  part
}

if (file.exists(txn_extract_file)) {
  message("Transaction extract already exists at ", txn_extract_file,
          "; delete it to refetch. Reloading for comparison.")
  transactions <- read.csv(txn_extract_file)
} else {
  parts <- list()
  for (st in STATES) {
    for (yr in YEARS) {
      part <- fetch_state_year(st, yr)
      if (!is.null(part)) parts[[length(parts) + 1]] <- part
    }
  }
  transactions <- bind_rows(parts)

  # NOTE: in spending_by_transaction, `internal_id` / `generated_internal_id`
  # identify the parent AWARD, not the individual transaction (they are 1:1 with
  # awards), so they must NOT be used to dedupe transactions. There is no single
  # stable transaction-id field exposed here; `Mod` is null for many actions.
  # The paginated fetch returns exactly the count reported by
  # spending_by_transaction_count, so every returned row is a distinct federal
  # action and all rows are retained.
  transactions$action_year <- as.integer(substr(transactions$action_date, 1, 4))
  transactions <- transactions[order(transactions$recipient_state,
                                      transactions$action_date,
                                      transactions$award_id), ]
  write.csv(transactions, txn_extract_file, row.names = FALSE)
  message("Saved ", nrow(transactions), " transaction rows to ",
          txn_extract_file)
}

if (is.null(transactions$action_year)) {
  transactions$action_year <- as.integer(substr(transactions$action_date, 1, 4))
}

# --- Annual comparison -----------------------------------------------------
awards <- read.csv(award_file)
awards$start_year <- as.integer(substr(awards$start_date, 1, 4))

award_annual <- awards |>
  filter(!is.na(start_year)) |>
  group_by(year = start_year) |>
  summarise(
    award_rows = n(),
    award_obligation = sum(award_amount, na.rm = TRUE),
    .groups = "drop"
  )

txn_annual <- transactions |>
  filter(!is.na(action_year)) |>
  group_by(year = action_year) |>
  summarise(
    transaction_rows = n(),
    transaction_deobligation_rows = sum(federal_action_obligation < 0, na.rm = TRUE),
    transaction_federal_action_obligation = sum(federal_action_obligation, na.rm = TRUE),
    .groups = "drop"
  )

annual <- full_join(award_annual, txn_annual, by = "year") |>
  arrange(year) |>
  mutate(
    award_obligation = coalesce(award_obligation, 0),
    transaction_federal_action_obligation =
      coalesce(transaction_federal_action_obligation, 0),
    difference_txn_minus_award =
      transaction_federal_action_obligation - award_obligation
  )

write.csv(annual, compare_file, row.names = FALSE)

# --- Console summary -------------------------------------------------------
fmt <- function(x) format(round(x), big.mark = ",", scientific = FALSE)
message("\n=== Grand totals ===")
message("Award-level obligation (sum award_amount):        $",
        fmt(sum(awards$award_amount, na.rm = TRUE)),
        "  over ", nrow(awards), " awards")
message("Transaction-level federal_action_obligation:      $",
        fmt(sum(transactions$federal_action_obligation, na.rm = TRUE)),
        "  over ", nrow(transactions), " transactions")
message("Deobligation (negative) transactions:             ",
        sum(transactions$federal_action_obligation < 0, na.rm = TRUE),
        "  totalling $",
        fmt(sum(transactions$federal_action_obligation[
          transactions$federal_action_obligation < 0], na.rm = TRUE)))
message("Positive obligating transactions:                 ",
        sum(transactions$federal_action_obligation > 0, na.rm = TRUE))
message("\nComparison written to: ", compare_file)
message("Extract written to:    ", txn_extract_file)
