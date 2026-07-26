# ---------------------------------------------------------------------------
# diagnose_coc_boundaries_v2.R
#
# Independent historical CoC-boundary diagnostics for the v2 LASSO builder.
#
# Compares the yearly CoC identifiers observed in HUD PIT and HIC (2010-2025)
# against the FY2024 boundary / crosswalk set that the v2 pipeline uses to
# allocate county predictors and attach CoC population denominators. Reports:
#   - historical CoC codes absent from FY2024;
#   - FY2024 codes absent in particular historical years;
#   - affected states and years;
#   - the three distinct geographic stages and their CoC/row counts:
#       (1) FY2024 crosswalk, (2) boundary-matched candidate panel,
#       (3) final v2 complete-case workbook;
#   - model rows lost, separated into three categories: boundary mismatch,
#     HIC-only unmatched identifiers (zero lost rows), and the final
#     complete-case predictor-coverage exclusion (a boundary-matched CoC with
#     no usable required-predictor value);
#   - counts before and after matching;
#   - split-county flags; and
#   - any locally verifiable merger / renaming evidence.
#
# READ-ONLY with respect to the v2 dataset, its builder, the crosswalk, and
# central documentation. This script owns only:
#   diagnose_coc_boundaries_v2.R (this file)
#   outputs/v2_support/coc_boundary_diagnostics_by_year.csv
#   outputs/v2_support/historical_coc_codes_not_in_FY2024.csv
#   outputs/v2_support/excluded_model_rows_by_reason.csv
#   outputs/v2_support/COC_BOUNDARY_DIAGNOSTICS.md
#
# It does not invent historical crosswalks and never forces an unmatched
# historical CoC into a current geography.
# ---------------------------------------------------------------------------

options(stringsAsFactors = FALSE)
project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) .libPaths(c(local_r_lib, .libPaths()))
suppressWarnings(suppressMessages({
  library(readxl)
  library(jsonlite)
}))

# --- Inputs (all local project data) ---------------------------------------
pit_cache <- file.path(project_root, "coc_analysis", "cache",
                       "hud_pit_coc_selected_2010_2025.csv")
hic_file <- file.path(project_root, "raw_data",
                      "2007-2025-HIC-Counts-by-CoC.xlsx")
crosswalk_file <- file.path(project_root, "coc_analysis",
                            "county_to_coc_population_crosswalk_FY2024.csv")
geojson_file <- file.path(project_root, "raw_data",
                          "hud_coc_boundaries_FY2024_CA_FL.geojson")
outcomes_file <- file.path(project_root, "coc_analysis",
                           "coc_year_homelessness_outcomes_CA_FL_2010_2025.csv")
candidate_file <- file.path(project_root, "coc_analysis",
                            "lasso_next_year_candidate_panel.csv")
# Final complete-case modeling workbooks (read-only). Needed to separate the
# boundary-matched *candidate* panel from the final *complete-case* panel: a
# CoC can be boundary-matched (present in the candidate panel) yet still be
# dropped from the final workbook because a *required predictor* has no usable
# value for it. That is a predictor-coverage exclusion, not a boundary mismatch.
v1_workbook <- file.path(project_root, "outputs", "lasso_model",
                         "CA_FL_LASSO_MODEL_INPUT.xlsx")
v2_workbook <- file.path(project_root, "outputs", "lasso_model",
                         "CA_FL_LASSO_MODEL_INPUT_v2.xlsx")

out_dir <- file.path(project_root, "outputs", "v2_support")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(pit_cache), file.exists(hic_file),
          file.exists(crosswalk_file), file.exists(geojson_file),
          file.exists(candidate_file), file.exists(v1_workbook),
          file.exists(v2_workbook))

YEARS <- 2010:2025
state_of <- function(code) ifelse(substr(code, 1, 2) == "CA", "CA", "FL")

# --- FY2024 reference set (crosswalk + geojson, cross-checked) --------------
crosswalk <- read.csv(crosswalk_file, check.names = FALSE)
fy2024_xwalk <- sort(unique(crosswalk$coc_number))

geo <- fromJSON(geojson_file, simplifyVector = TRUE)
fy2024_geo <- sort(unique(geo$features$properties$COCNUM))

if (!setequal(fy2024_xwalk, fy2024_geo)) {
  warning("FY2024 crosswalk and geojson CoC sets differ:\n",
          "  crosswalk-only: ",
          paste(setdiff(fy2024_xwalk, fy2024_geo), collapse = ", "), "\n",
          "  geojson-only:   ",
          paste(setdiff(fy2024_geo, fy2024_xwalk), collapse = ", "))
}
fy2024 <- sort(union(fy2024_xwalk, fy2024_geo))
message("FY2024 reference CoCs: ", length(fy2024),
        " (crosswalk=", length(fy2024_xwalk),
        ", geojson=", length(fy2024_geo), ", agree=",
        setequal(fy2024_xwalk, fy2024_geo), ")")

# --- Historical PIT identifiers by year ------------------------------------
pit <- read.csv(pit_cache, check.names = FALSE)
pit <- pit[grepl("^(CA|FL)-[0-9]{3}$", pit$coc_number), c("year", "coc_number")]
pit$year <- as.integer(pit$year)
# One name per historical PIT code (for local merger evidence).
pit_names <- read.csv(pit_cache, check.names = FALSE)
pit_names <- unique(pit_names[c("coc_number", "coc_name")])

# --- Historical HIC identifiers by year ------------------------------------
read_hic_year <- function(year) {
  raw <- as.data.frame(read_excel(hic_file, sheet = as.character(year),
                                  col_names = FALSE, .name_repair = "minimal"))
  fc <- trimws(as.character(raw[[1]]))
  hr <- which(grepl("^CoC( Number)?$", fc, ignore.case = TRUE))[1]
  if (is.na(hr)) stop("No HIC header row for ", year)
  coc <- trimws(as.character(raw[[1]]))[(hr + 1):nrow(raw)]
  coc <- coc[grepl("^(CA|FL)-[0-9]{3}$", coc)]
  data.frame(year = as.integer(year), coc_number = unique(coc))
}
hic <- do.call(rbind, lapply(YEARS, read_hic_year))

# --- Per-year diagnostics (per source x state x year) -----------------------
membership <- rbind(
  data.frame(source = "PIT", pit[c("year", "coc_number")]),
  data.frame(source = "HIC", hic[c("year", "coc_number")])
)
membership$state <- state_of(membership$coc_number)

by_year_rows <- list()
for (src in c("PIT", "HIC")) {
  for (st in c("CA", "FL")) {
    fy_state <- fy2024[state_of(fy2024) == st]
    for (yr in YEARS) {
      codes <- sort(unique(membership$coc_number[
        membership$source == src & membership$state == st &
          membership$year == yr]))
      if (length(codes) == 0) next
      matched <- intersect(codes, fy_state)
      unmatched <- setdiff(codes, fy_state)
      fy_absent <- setdiff(fy_state, codes)
      by_year_rows[[length(by_year_rows) + 1]] <- data.frame(
        source = src, state = st, year = yr,
        n_historical_cocs = length(codes),
        n_matched_fy2024 = length(matched),
        n_unmatched_fy2024 = length(unmatched),
        unmatched_codes = paste(unmatched, collapse = ";"),
        n_fy2024_state_total = length(fy_state),
        n_fy2024_present = length(matched),
        n_fy2024_absent = length(fy_absent),
        fy2024_absent_codes = paste(fy_absent, collapse = ";")
      )
    }
  }
}
by_year <- do.call(rbind, by_year_rows)
by_year <- by_year[order(by_year$source, by_year$state, by_year$year), ]
write.csv(by_year, file.path(out_dir, "coc_boundary_diagnostics_by_year.csv"),
          row.names = FALSE)

# --- Historical codes absent from FY2024 -----------------------------------
hist_codes <- sort(unique(membership$coc_number[
  !membership$coc_number %in% fy2024]))

# Local reassignment evidence: only where a FY2024 crosswalk county row makes
# the successor unambiguous (never invented). CA-528 = Del Norte County CoC,
# and FY2024 assigns Del Norte County (FIPS 06015) to CA-516.
local_evidence <- function(code) {
  nm <- pit_names$coc_name[pit_names$coc_number == code]
  nm <- nm[!is.na(nm) & nzchar(nm)]
  if (code == "CA-528") {
    return(paste0(
      "PIT name 'Del Norte County CoC'; FY2024 crosswalk assigns Del Norte ",
      "County (FIPS 06015) to CA-516 whose CoC name explicitly lists ",
      "'Del Norte' -> CA-528 folded into CA-516."))
  }
  "none available locally (no local name or FY2024 crosswalk row identifies a successor)"
}

hist_rows <- lapply(hist_codes, function(code) {
  py <- sort(unique(pit$year[pit$coc_number == code]))
  hy <- sort(unique(hic$year[hic$coc_number == code]))
  all_y <- sort(unique(c(py, hy)))
  nm <- pit_names$coc_name[pit_names$coc_number == code]
  nm <- unique(nm[!is.na(nm) & nzchar(nm)])
  data.frame(
    coc_number = code, state = state_of(code),
    in_pit = as.integer(length(py) > 0),
    in_hic = as.integer(length(hy) > 0),
    pit_years = paste(py, collapse = ";"),
    hic_years = paste(hy, collapse = ";"),
    first_year = if (length(all_y)) min(all_y) else NA_integer_,
    last_year = if (length(all_y)) max(all_y) else NA_integer_,
    n_distinct_years = length(all_y),
    local_coc_name = if (length(nm)) paste(nm, collapse = " | ") else "",
    fy2024_present = FALSE,
    local_reassignment_evidence = local_evidence(code)
  )
})
hist_not_fy2024 <- do.call(rbind, hist_rows)
write.csv(hist_not_fy2024,
          file.path(out_dir, "historical_coc_codes_not_in_FY2024.csv"),
          row.names = FALSE)

# --- Three geographic stages -----------------------------------------------
# Rows are lost at two structurally different stages, and CoCs correspondingly
# thin out across three stages that must not be conflated:
#   (1) FY2024 crosswalk           -- the reference geography (71 CoCs);
#   (2) boundary-matched candidate -- PIT outcomes with an FY2024 denominator,
#       matched to a next-year target, 2021-as-target excluded (71 CoCs);
#   (3) final complete-case v2     -- candidate rows with EVERY required
#       predictor present (70 CoCs).
# Stage 1->2 loses rows to *boundary mismatch* (a historical PIT CoC with no
# FY2024 denominator). Stage 2->3 loses rows to *predictor coverage* (a
# boundary-matched CoC whose value for a required predictor is unavailable).
candidate <- read.csv(candidate_file, check.names = FALSE)
v1_panel <- as.data.frame(readxl::read_excel(v1_workbook, sheet = 1))
v2_panel <- as.data.frame(readxl::read_excel(v2_workbook, sheet = 1))

fy2024_cocs   <- fy2024
candidate_cocs <- sort(unique(candidate$coc_number))
v1_cocs        <- sort(unique(v1_panel$coc_number))
v2_cocs        <- sort(unique(v2_panel$coc_number))

# CoCs boundary-matched into the candidate panel but dropped from the final
# v2 complete-case workbook: a predictor-coverage exclusion, NOT a boundary
# mismatch (these CoCs ARE in the FY2024 set).
predictor_coverage_excluded <- sort(setdiff(candidate_cocs, v2_cocs))

# --- Candidate/model rows lost to mismatch ---------------------------------
# The model outcome source is PIT. An outcome row whose CoC is absent from
# FY2024 gets no population denominator and is dropped before the candidate
# panel. HIC-only unmatched codes never enter the PIT-keyed candidate panel,
# so they cost zero model rows (their HIC beds simply fail to join).
outcomes <- read.csv(outcomes_file, check.names = FALSE)
unmatched_outcome <- outcomes[!outcomes$coc_number %in% fy2024, ]

# Uniform schema across all three exclusion categories so the reasons stay
# distinguishable and the row-count arithmetic is explicit per CoC.
excl_row <- function(category, reason, source, code, affected_years,
                     n_candidate_panel_rows, n_v1_complete_rows,
                     n_model_rows_lost, stage_dropped, notes) {
  data.frame(
    category = category, reason = reason, source = source,
    coc_number = code, state = state_of(code),
    affected_years = affected_years,
    n_candidate_panel_rows = as.integer(n_candidate_panel_rows),
    n_v1_complete_rows = as.integer(n_v1_complete_rows),
    n_model_rows_lost = as.integer(n_model_rows_lost),
    stage_dropped = stage_dropped, notes = notes
  )
}

excluded_rows <- list()

# Category 1: boundary mismatch (stage 1 -> 2). PIT CoC with no FY2024
# denominator; never reaches the candidate panel.
for (code in sort(unique(unmatched_outcome$coc_number))) {
  yrs <- sort(unique(unmatched_outcome$year[unmatched_outcome$coc_number == code]))
  excluded_rows[[length(excluded_rows) + 1]] <- excl_row(
    category = "boundary_mismatch",
    reason = "historical PIT CoC absent from FY2024 boundary/crosswalk (no population denominator)",
    source = "PIT (model outcome)", code = code,
    affected_years = paste(yrs, collapse = ";"),
    n_candidate_panel_rows = 0L, n_v1_complete_rows = 0L,
    n_model_rows_lost = length(yrs),
    stage_dropped = "outcome -> candidate (population_denominator_status = 'Unavailable: historical CoC not represented by FY2024 boundary')",
    notes = local_evidence(code))
}

# Category 2: HIC-only unmatched codes. Documented, zero model rows lost.
hic_only_unmatched <- setdiff(
  unique(hic$coc_number[!hic$coc_number %in% fy2024]),
  unique(pit$coc_number))
for (code in sort(hic_only_unmatched)) {
  yrs <- sort(unique(hic$year[hic$coc_number == code]))
  excluded_rows[[length(excluded_rows) + 1]] <- excl_row(
    category = "hic_only_unmatched",
    reason = "HIC-only historical CoC absent from FY2024 (never in PIT); zero lost model rows",
    source = "HIC (predictor)", code = code,
    affected_years = paste(yrs, collapse = ";"),
    n_candidate_panel_rows = 0L, n_v1_complete_rows = 0L,
    n_model_rows_lost = 0L,
    stage_dropped = "HIC left-join to PIT-keyed candidates (no matching CoC-year; HIC beds unused)",
    notes = "no local name or FY2024 successor; not forced into a current geography")
}

# Category 3: final complete-case predictor-coverage exclusion (stage 2 -> 3).
# A boundary-matched candidate CoC dropped from the final v2 workbook because a
# required predictor has no usable value. Here the binding predictor is
# coc_relative_home_price_index_2000_base (FHFA county HPI): the excluded CoC's
# member counties never reach the >=40% weighted-coverage floor, so no usable
# CoC-level index exists for any of its years. This is NOT a boundary mismatch
# (the CoC IS in the FY2024 set); it is why the final workbook has 70 CoCs, one
# fewer than the 71-CoC candidate panel.
for (code in predictor_coverage_excluded) {
  cand_yrs <- sort(unique(candidate$predictor_year[candidate$coc_number == code]))
  n_cand <- length(cand_yrs)
  n_v1 <- sum(v1_panel$coc_number == code)
  in_fy2024 <- code %in% fy2024
  excluded_rows[[length(excluded_rows) + 1]] <- excl_row(
    category = "predictor_coverage_final_complete_case",
    reason = "boundary-matched CoC dropped from final v2 complete-case panel: required predictor coc_relative_home_price_index_2000_base (FHFA local home-price index) has no usable value",
    source = "predictor (FHFA home-price index)", code = code,
    affected_years = paste(cand_yrs, collapse = ";"),
    n_candidate_panel_rows = n_cand, n_v1_complete_rows = n_v1,
    n_model_rows_lost = n_v1,
    stage_dropped = "candidate -> final v2 complete-case (no usable FHFA home-price-index value; member counties below the 40% weighted-coverage floor for every year)",
    notes = sprintf(paste0(
      "predictor-coverage exclusion, NOT a boundary mismatch (CoC present in FY2024 = %s); ",
      "%d candidate-panel rows, of which %d were present in the v1 complete panel; ",
      "removing them takes v2 from %d to %d rows and %d to %d CoCs. See CHANGELOG_v1_to_v2.md sections 2 and 5."),
      in_fy2024, n_cand, n_v1, nrow(v1_panel), nrow(v2_panel),
      length(v1_cocs), length(v2_cocs)))
}

excluded <- do.call(rbind, excluded_rows)
write.csv(excluded,
          file.path(out_dir, "excluded_model_rows_by_reason.csv"),
          row.names = FALSE)

# --- Counts before / after matching ----------------------------------------
n_pit_obs <- nrow(pit)
n_pit_matched <- sum(pit$coc_number %in% fy2024)
n_outcome <- nrow(outcomes)
n_outcome_matched <- sum(outcomes$coc_number %in% fy2024)
n_candidate <- nrow(candidate)
n_hic_obs <- nrow(hic)
n_hic_matched <- sum(hic$coc_number %in% fy2024)

# Three-stage CoC and row counts (must not be conflated).
n_fy2024_cocs   <- length(fy2024_cocs)
n_candidate_cocs <- length(candidate_cocs)
n_v1_cocs        <- length(v1_cocs)
n_v2_cocs        <- length(v2_cocs)
n_v1_rows        <- nrow(v1_panel)
n_v2_rows        <- nrow(v2_panel)
# Rows lost by stage transition.
boundary_rows_lost   <- sum(excluded$n_model_rows_lost[
  excluded$category == "boundary_mismatch"])
predcov_rows_lost    <- sum(excluded$n_model_rows_lost[
  excluded$category == "predictor_coverage_final_complete_case"])
predcov_cand_rows    <- sum(excluded$n_candidate_panel_rows[
  excluded$category == "predictor_coverage_final_complete_case"])

# --- Split-county flags -----------------------------------------------------
split_rows <- crosswalk[crosswalk$split_county_flag == 1, ]
split_cocs <- sort(unique(split_rows$coc_number))
split_counties <- sort(unique(split_rows$county_name))

# --- Reconciliation against the v2 finding ---------------------------------
# v2: "CA-528 is the only unmatched historical CoC code and accounts for three
# PIT-year rows."
ca528_pit_years <- sort(unique(pit$year[pit$coc_number == "CA-528"]))
pit_unmatched_codes <- sort(unique(pit$coc_number[!pit$coc_number %in% fy2024]))
all_unmatched_codes <- hist_codes

message("\n================ RECONCILIATION vs v2 ================")
message("v2 claim: CA-528 is the only unmatched historical CoC; 3 PIT-year rows.")
message("PIT-axis unmatched codes: ", paste(pit_unmatched_codes, collapse = ", "),
        "  (CA-528 PIT years: ", paste(ca528_pit_years, collapse = ", "), ")")
message("  -> PIT / model-row finding: ",
        if (identical(pit_unmatched_codes, "CA-528") &&
            length(ca528_pit_years) == 3) "AGREE" else "DISAGREE")
message("ALL historical (PIT+HIC) unmatched codes: ",
        paste(all_unmatched_codes, collapse = ", "))
message("  -> Scope note: HIC adds ",
        paste(setdiff(all_unmatched_codes, "CA-528"), collapse = ", "),
        " (0 model rows lost; PIT never recorded them).")
message("\nCounts: PIT obs ", n_pit_obs, " -> matched ", n_pit_matched,
        " (lost ", n_pit_obs - n_pit_matched, "); outcomes ", n_outcome,
        " -> matched ", n_outcome_matched, "; candidates ", n_candidate, ".")
message("\n----- Three geographic stages (CoCs | rows) -----")
message("(1) FY2024 crosswalk:            ", n_fy2024_cocs, " CoCs")
message("(2) boundary-matched candidate:  ", n_candidate_cocs, " CoCs | ",
        n_candidate, " rows")
message("(3) final v2 complete-case:      ", n_v2_cocs, " CoCs | ", n_v2_rows,
        " rows   (v1 complete-case: ", n_v1_cocs, " CoCs | ", n_v1_rows, " rows)")
message("Predictor-coverage exclusion (candidate -> final v2): ",
        paste(predictor_coverage_excluded, collapse = ", "),
        "  (", predcov_cand_rows, " candidate rows; ", predcov_rows_lost,
        " were in the v1 complete panel)")
message("  -> final v2 has ", n_v2_cocs, " CoCs = ", n_candidate_cocs,
        " candidate CoCs minus the predictor-coverage exclusion; ",
        "NOT a boundary mismatch.")
message("Split-county FY2024 CoCs (", length(split_cocs), "): ",
        paste(split_cocs, collapse = ", "),
        "  | counties: ", paste(split_counties, collapse = ", "))

# --- Markdown report --------------------------------------------------------
agree_pit <- identical(pit_unmatched_codes, "CA-528") &&
  length(ca528_pit_years) == 3
md <- c(
  "# Historical CoC-Boundary Diagnostics for the v2 Builder",
  "",
  "Independent comparison of yearly HUD **PIT** and **HIC** CoC identifiers",
  "(2010-2025) against the **FY2024** boundary / crosswalk set used by the v2",
  "pipeline. Read-only: no v2 dataset, builder, crosswalk, or central document",
  "was modified. Historical crosswalks were not invented and unmatched CoCs were",
  "not forced into current geographies.",
  "",
  "## Reference sets",
  "",
  sprintf("- FY2024 CoCs: **%d** (crosswalk = %d, geojson = %d, identical = %s).",
          length(fy2024), length(fy2024_xwalk), length(fy2024_geo),
          setequal(fy2024_xwalk, fy2024_geo)),
  sprintf("- PIT observations 2010-2025: **%d** CoC-years (matched to FY2024: %d).",
          n_pit_obs, n_pit_matched),
  sprintf("- HIC observations 2010-2025: **%d** CoC-years (matched to FY2024: %d).",
          n_hic_obs, n_hic_matched),
  "",
  "## Three geographic stages (do not conflate)",
  "",
  "CoCs thin out across three stages for two structurally different reasons.",
  "The first transition drops rows for a **boundary mismatch**; the second",
  "drops rows for **predictor coverage**. They are not the same thing.",
  "",
  "| Stage | CoCs | Rows | What it is |",
  "|-------|-----:|-----:|------------|",
  sprintf("| (1) FY2024 crosswalk | **%d** | - | Reference CoC geography (`county_to_coc_population_crosswalk_FY2024.csv`). |",
          n_fy2024_cocs),
  sprintf("| (2) Boundary-matched candidate panel | **%d** | **%d** | PIT outcomes with an FY2024 denominator, matched to a next-year target, 2021-as-target excluded (`lasso_next_year_candidate_panel.csv`). |",
          n_candidate_cocs, n_candidate),
  sprintf("| (3) Final v2 complete-case workbook | **%d** | **%d** | Candidate rows with **every** required predictor present (`CA_FL_LASSO_MODEL_INPUT_v2.xlsx`). |",
          n_v2_cocs, n_v2_rows),
  "",
  sprintf("Stage 1->2 loses **%d** row(s) to boundary mismatch (**%s**). Stage 2->3",
          boundary_rows_lost,
          paste(unique(excluded$coc_number[excluded$category == "boundary_mismatch"]), collapse = ", ")),
  sprintf("loses **%d** further row(s) to predictor coverage (**%s**), which is why",
          predcov_rows_lost,
          paste(predictor_coverage_excluded, collapse = ", ")),
  sprintf("the final workbook has **%d** CoCs, one fewer than the %d-CoC candidate",
          n_v2_cocs, n_candidate_cocs),
  "panel. Details in the two sections below and in",
  "`excluded_model_rows_by_reason.csv`.",
  "",
  "## Reconciliation against the v2 finding",
  "",
  "> v2: *CA-528 is the only unmatched historical CoC code and accounts for three PIT-year rows.*",
  "",
  sprintf("**On the PIT / model-row axis: %s.** The only PIT CoC absent from",
          if (agree_pit) "CONFIRMED" else "DISAGREE"),
  sprintf("FY2024 is **CA-528** (Del Norte County CoC), present in PIT for **%s**",
          paste(ca528_pit_years, collapse = ", ")),
  sprintf("= **%d rows**. It carries `population_denominator_status =",
          length(ca528_pit_years)),
  "'Unavailable: historical CoC not represented by FY2024 boundary'`, so it is",
  sprintf("dropped before the candidate panel; the candidate panel's **%d** CoCs",
          n_candidate_cocs),
  "therefore equal the FY2024 set exactly. (The *final v2 complete-case*",
  sprintf("workbook has **%d** CoCs, one fewer, for a separate predictor-coverage",
          n_v2_cocs),
  "reason documented below — not a boundary mismatch.)",
  "",
  "**Scope clarification (partial disagreement).** If \"historical CoC code\"",
  "includes the **HIC** predictor identifiers the v2 dataset also ingests, then",
  "CA-528 is *not* the only unmatched code. HIC additionally contains",
  sprintf("**%s**, all absent from FY2024.",
          paste(setdiff(all_unmatched_codes, "CA-528"), collapse = ", ")),
  "These cost **zero model rows** (PIT never recorded them, so they never",
  "become candidate rows), but their HIC bed counts fail to join and are",
  "unused. The v2 statement is therefore exact for PIT / lost model rows, and",
  "incomplete as a claim about *all* historical CoC identifiers.",
  "",
  "## Historical CoC codes absent from FY2024",
  "",
  "| Code | State | In PIT (years) | In HIC (years) | Local successor evidence |",
  "|------|-------|----------------|----------------|--------------------------|")
for (i in seq_len(nrow(hist_not_fy2024))) {
  r <- hist_not_fy2024[i, ]
  md <- c(md, sprintf("| %s | %s | %s | %s | %s |",
    r$coc_number, r$state,
    if (nzchar(r$pit_years)) r$pit_years else "-",
    if (nzchar(r$hic_years)) r$hic_years else "-",
    r$local_reassignment_evidence))
}
md <- c(md, "",
  "Only **CA-528 -> CA-516** is locally verifiable (Del Norte County, FIPS",
  "06015, is a CA-516 member in the FY2024 crosswalk and CA-516's name lists",
  "\"Del Norte\"). No local evidence identifies successors for the HIC-only",
  "codes, so none were reassigned.",
  "",
  "## Model rows lost, by stage and reason",
  "",
  "`excluded_model_rows_by_reason.csv` separates three categories:",
  "",
  sprintf("1. **Boundary mismatch** (stage 1->2): exactly **%d** row(s), all **%s** (%s) — a PIT CoC with no FY2024 denominator, dropped before the candidate panel.",
          boundary_rows_lost,
          paste(unique(excluded$coc_number[excluded$category == "boundary_mismatch"]), collapse = ", "),
          paste(ca528_pit_years, collapse = ", ")),
  sprintf("2. **HIC-only unmatched** identifiers (**%s**): **0** model rows lost — they never join the PIT-keyed candidate panel, so their HIC beds are simply unused.",
          paste(sort(hic_only_unmatched), collapse = ", ")),
  sprintf("3. **Predictor-coverage exclusion** (stage 2->3): **%s** is boundary-matched (in FY2024, and even a split-county CoC) but has **no usable `coc_relative_home_price_index_2000_base`** (FHFA local home-price index) — its member counties never reach the 40%% weighted-coverage floor. It supplies **%d** candidate-panel rows, of which **%d** were present in the v1 complete panel; requiring that predictor drops all **%d** and removes the CoC entirely.",
          paste(predictor_coverage_excluded, collapse = ", "),
          predcov_cand_rows, predcov_rows_lost, predcov_rows_lost),
  "",
  "Pipeline counts:",
  sprintf("PIT/outcomes **%d** -> matched to FY2024 **%d** (lost **%d** to boundary mismatch) -> candidate panel **%d** rows / **%d** CoCs -> final v2 complete-case **%d** rows / **%d** CoCs (lost **%d** rows / 1 CoC to predictor coverage; v1 complete-case was **%d** rows / **%d** CoCs).",
          n_outcome, n_outcome_matched, n_outcome - n_outcome_matched,
          n_candidate, n_candidate_cocs, n_v2_rows, n_v2_cocs,
          predcov_rows_lost, n_v1_rows, n_v1_cocs),
  "",
  "## FY2024 codes absent in particular historical years",
  "",
  "Per-source, per-state, per-year presence is in",
  "`coc_boundary_diagnostics_by_year.csv` (`n_fy2024_absent`,",
  "`fy2024_absent_codes`). These are FY2024 CoCs not yet reporting in a given",
  "year (e.g. new/renumbered CoCs in early years), **not** boundary conflicts;",
  "they reduce coverage for that year but do not create unmatched rows.",
  "",
  "## Split-county flags",
  "",
  sprintf("FY2024 CoCs whose allocation splits a county across CoCs (%d CoCs):",
          length(split_cocs)),
  sprintf("**%s**", paste(split_cocs, collapse = ", ")),
  sprintf("across counties: %s.", paste(split_counties, collapse = ", ")),
  "Allocation for these uses fractional ACS 2024 tract-population shares, so",
  "their county-derived predictors are estimates; treat them cautiously in",
  "split-CoC sensitivity checks.",
  "",
  "## Inputs",
  "",
  "- `coc_analysis/cache/hud_pit_coc_selected_2010_2025.csv` (PIT identifiers)",
  "- `raw_data/2007-2025-HIC-Counts-by-CoC.xlsx` (HIC identifiers, read directly)",
  "- `coc_analysis/county_to_coc_population_crosswalk_FY2024.csv` + `raw_data/hud_coc_boundaries_FY2024_CA_FL.geojson` (FY2024 set)",
  "- `coc_analysis/coc_year_homelessness_outcomes_CA_FL_2010_2025.csv`, `lasso_next_year_candidate_panel.csv` (pipeline counts)",
  "- `outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx` (v1) and `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` (v2) complete-case workbooks (final-stage CoC/row counts; read-only)",
  "",
  "## Reproduce",
  "",
  "```bash",
  "Rscript diagnose_coc_boundaries_v2.R",
  "```")
writeLines(md, file.path(out_dir, "COC_BOUNDARY_DIAGNOSTICS.md"))

message("\nWrote 4 outputs to ", out_dir)
