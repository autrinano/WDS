###############################################################################
# build_lasso_sensitivity_inputs.R
#
# Builds every SENSITIVITY sample definition for the California-Florida CoC-year
# homelessness LASSO. This script is owned by the sensitivity effort. It does
# NOT modify the primary workbook (CA_FL_LASSO_MODEL_INPUT_v2.xlsx), does NOT
# modify fit_lasso_models.R or any FINAL_ output, and does NOT touch central
# project documentation. Everything it writes goes under outputs/lasso_sensitivity/.
#
# Inputs (all read-only):
#   outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx  (primary immutable input)
#   coc_analysis/coc_year_homelessness_outcomes_CA_FL_2010_2025.csv (prior PIT)
#   ... plus, for sensitivity 5 only, the SAME audited v2 pipeline inputs used by
#       build_expanded_lasso_input_v2.R (candidate panel, HIC workbook, county
#       raw panel, FY2024 crosswalk, CPI-U, FRED LBSSA06/LBSSA12, team state
#       sheet). No v1 workbook column is ever read or copied.
#
# Sensitivity samples produced:
#   S0_primary                 full v2 panel (replication reference)
#   S1_split_county_excluded   drops every coc_contains_split_county_flag == 1 row
#   S2_stable_cocs             CoCs observed in EVERY usable v2 target year
#   S3_no_structural_beds      drops the two HIC service-capacity predictors
#   S4_persistence             rows with a reliable prior-year PIT rate + that rate
#   S5_no_hpi_fl518            v2 pipeline rebuilt WITHOUT requiring the FHFA
#                              home-price index, restoring eligible FL-518 rows
#
# Nothing is imputed anywhere. Every sample is a row filter and/or a column
# removal applied to fully observed, audited values.
###############################################################################

options(stringsAsFactors = FALSE)

project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib  <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) .libPaths(c(local_r_lib, .libPaths()))

suppressWarnings(suppressMessages({
  library(dplyr)
  library(readxl)
  library(openxlsx)
  library(tidyr)
}))

OUT_DIR  <- file.path(project_root, "outputs", "lasso_sensitivity")
DATA_DIR <- file.path(OUT_DIR, "data")
DEF_DIR  <- file.path(OUT_DIR, "definitions")
for (d in c(OUT_DIR, DATA_DIR, DEF_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

banner <- function(txt) {
  line <- paste(rep("=", 78), collapse = "")
  cat(line, "\n", txt, "\n", line, "\n", sep = "")
}
banner("build_lasso_sensitivity_inputs.R")

## ---------------------------------------------------------------------------
## 0. PRIMARY IMMUTABLE INPUT (read-only, fingerprinted)
## ---------------------------------------------------------------------------
PRIMARY_FILE     <- file.path(project_root, "outputs", "lasso_model",
                              "CA_FL_LASSO_MODEL_INPUT_v2.xlsx")
EXPECTED_V2_MD5  <- "5d3fd16b32c687e5207ea59c902e7bef"   # same fingerprint fit_lasso_models.R requires
SHEET            <- "LASSO Model Data"

if (!file.exists(PRIMARY_FILE)) stop("Primary model input not found: ", PRIMARY_FILE)
primary_md5 <- unname(tools::md5sum(PRIMARY_FILE))
if (!identical(primary_md5, EXPECTED_V2_MD5))
  stop("Primary v2 workbook MD5 ", primary_md5, " does not match the audited ",
       EXPECTED_V2_MD5, ". Sensitivities must be built from the same audited input ",
       "as the FINAL run.")

id_cols      <- c("state", "state_abbr", "coc_number", "coc_name",
                  "predictor_year", "target_year")
target_col   <- "target_homeless_rate_per_10k"
control_cols <- c("control_state_florida", "control_time_index")

primary <- read.xlsx(PRIMARY_FILE, sheet = SHEET)
predictor_cols <- setdiff(names(primary), c(id_cols, target_col, control_cols))

cat(sprintf("Primary v2 input: %d rows x %d cols | %d predictors | %d CoCs | target years %s\n",
            nrow(primary), ncol(primary), length(predictor_cols),
            length(unique(primary$coc_number)),
            paste(range(primary$target_year), collapse = "-")))

usable_target_years <- sort(unique(primary$target_year))
cat("Usable v2 target years (", length(usable_target_years), "): ",
    paste(usable_target_years, collapse = ", "), "\n", sep = "")

## Strict finite gate on the primary input, mirroring fit_lasso_models.R.
stopifnot(all(vapply(primary[c(target_col, control_cols, predictor_cols)],
                     function(v) all(is.finite(v)), logical(1))))

## Collector for the machine-readable sample-definition and exclusion tables.
sample_defs <- list()
exclusions  <- list()

add_def <- function(sample_id, label, rule, n_rows, n_cocs, n_predictors,
                    target_years, notes) {
  sample_defs[[length(sample_defs) + 1]] <<- data.frame(
    sample_id = sample_id, label = label, selection_rule = rule,
    n_rows = n_rows, n_cocs = n_cocs, n_predictors = n_predictors,
    n_target_years = length(target_years),
    target_years = paste(target_years, collapse = ";"),
    rows_vs_primary = n_rows - nrow(primary),
    cocs_vs_primary = n_cocs - length(unique(primary$coc_number)),
    predictors_vs_primary = n_predictors - length(predictor_cols),
    notes = notes, stringsAsFactors = FALSE)
}

add_excl <- function(sample_id, level, unit, reason, n_rows) {
  exclusions[[length(exclusions) + 1]] <<- data.frame(
    sample_id = sample_id, level = level, unit = unit,
    reason = reason, n_rows_affected = n_rows, stringsAsFactors = FALSE)
}

write_sample <- function(sample_id, df) {
  path <- file.path(DATA_DIR, sprintf("%s_data.csv", sample_id))
  write.csv(df, path, row.names = FALSE)
  invisible(path)
}

## ---------------------------------------------------------------------------
## S0. PRIMARY (replication reference)
## ---------------------------------------------------------------------------
write_sample("S0_primary", primary)
add_def("S0_primary", "Primary v2 panel (replication reference)",
        "All audited v2 complete-case rows and all 38 candidate predictors.",
        nrow(primary), length(unique(primary$coc_number)), length(predictor_cols),
        usable_target_years,
        "Refit under the sensitivity harness to confirm it reproduces the FINAL run.")

## ---------------------------------------------------------------------------
## S1. SPLIT-COUNTY SENSITIVITY
##     Drop every row whose CoC allocation splits at least one county across
##     CoCs, because those CoC-level predictors are fractional ACS-share
##     estimates rather than whole-county aggregates.
## ---------------------------------------------------------------------------
split_rows <- primary$coc_contains_split_county_flag == 1
split_cocs <- sort(unique(primary$coc_number[split_rows]))
s1 <- primary[!split_rows, , drop = FALSE]

## The flag is CoC-constant, so removing flagged rows removes whole CoCs.
flag_constant_within_coc <- all(tapply(primary$coc_contains_split_county_flag,
                                       primary$coc_number,
                                       function(v) length(unique(v))) == 1)
if (!flag_constant_within_coc)
  warning("coc_contains_split_county_flag is not constant within CoC; ",
          "S1 removes rows rather than whole CoCs.")

## The flag is now constant (all zero) inside S1, so it cannot be a predictor there.
s1_predictors <- setdiff(predictor_cols, "coc_contains_split_county_flag")
s1 <- s1[, c(id_cols, target_col, control_cols, s1_predictors)]

for (cc in split_cocs)
  add_excl("S1_split_county_excluded", "CoC", cc,
           "coc_contains_split_county_flag == 1 (county split across CoCs; predictors are fractional ACS-share estimates)",
           sum(primary$coc_number == cc))
add_excl("S1_split_county_excluded", "column", "coc_contains_split_county_flag",
         "Predictor becomes constant (all zero) after the row filter and is dropped", 0L)

write_sample("S1_split_county_excluded", s1)
add_def("S1_split_county_excluded", "Split-county CoCs excluded",
        "Keep rows with coc_contains_split_county_flag == 0.",
        nrow(s1), length(unique(s1$coc_number)), length(s1_predictors),
        sort(unique(s1$target_year)),
        sprintf("Removed %d rows and %d CoCs (%s). coc_contains_split_county_flag dropped as constant.",
                sum(split_rows), length(split_cocs), paste(split_cocs, collapse = ", ")))

cat(sprintf("\nS1 split-county: removed %d rows / %d CoCs (%s) -> %d rows, %d CoCs\n",
            sum(split_rows), length(split_cocs), paste(split_cocs, collapse = ", "),
            nrow(s1), length(unique(s1$coc_number))))

## ---------------------------------------------------------------------------
## S2. STABLE-CoC SENSITIVITY
##     STABILITY DEFINITION (stated once, applied literally, not varied):
##     a CoC is STABLE if and only if it supplies a modeling row in EVERY usable
##     v2 target year, i.e. all 13 of 2012-2020 and 2022-2025 (2021 is excluded
##     project-wide as a COVID-disrupted PIT target). A CoC missing even one of
##     those 13 years is not stable.
## ---------------------------------------------------------------------------
years_per_coc <- tapply(primary$target_year, primary$coc_number,
                        function(v) length(unique(v)))
stable_cocs   <- sort(names(years_per_coc)[years_per_coc == length(usable_target_years)])
unstable_cocs <- sort(names(years_per_coc)[years_per_coc <  length(usable_target_years)])
s2 <- primary[primary$coc_number %in% stable_cocs, , drop = FALSE]

for (cc in unstable_cocs) {
  have <- sort(unique(primary$target_year[primary$coc_number == cc]))
  add_excl("S2_stable_cocs", "CoC", cc,
           sprintf("Observed in %d of %d usable v2 target years (missing %s)",
                   length(have), length(usable_target_years),
                   paste(setdiff(usable_target_years, have), collapse = ";")),
           sum(primary$coc_number == cc))
}

write_sample("S2_stable_cocs", s2)
add_def("S2_stable_cocs", "Stable CoCs only",
        sprintf("Keep CoCs with a modeling row in all %d usable v2 target years (%s).",
                length(usable_target_years), paste(usable_target_years, collapse = ";")),
        nrow(s2), length(stable_cocs), length(predictor_cols),
        sort(unique(s2$target_year)),
        sprintf("Removed %d CoCs (%s) supplying %d rows.",
                length(unstable_cocs), paste(unstable_cocs, collapse = ", "),
                nrow(primary) - nrow(s2)))

cat(sprintf("S2 stable-CoC: %d of %d CoCs stable across all %d usable target years -> %d rows (removed %d CoCs: %s)\n",
            length(stable_cocs), length(years_per_coc), length(usable_target_years),
            nrow(s2), length(unstable_cocs), paste(unstable_cocs, collapse = ", ")))

## ---------------------------------------------------------------------------
## S3. STRUCTURAL-PREDICTOR SENSITIVITY
##     Remove the two HIC service-capacity predictors. Shelter/PSH bed capacity
##     is plausibly endogenous to observed homelessness (capacity is built where
##     homelessness is high, and sheltered PIT counts are taken in those beds),
##     so this sample asks which housing, economic, demographic, and policy
##     predictors are selected once capacity is unavailable.
## ---------------------------------------------------------------------------
structural_preds <- c("coc_hic_psh_beds_per_10k", "coc_hic_temporary_beds_per_10k")
stopifnot(all(structural_preds %in% predictor_cols))
s3_predictors <- setdiff(predictor_cols, structural_preds)
s3 <- primary[, c(id_cols, target_col, control_cols, s3_predictors)]

for (p in structural_preds)
  add_excl("S3_no_structural_beds", "column", p,
           "HUD HIC service-capacity predictor removed as potentially endogenous to the outcome", 0L)

write_sample("S3_no_structural_beds", s3)
add_def("S3_no_structural_beds", "Service-capacity predictors removed",
        "All primary rows; drop coc_hic_psh_beds_per_10k and coc_hic_temporary_beds_per_10k.",
        nrow(s3), length(unique(s3$coc_number)), length(s3_predictors),
        sort(unique(s3$target_year)),
        "Same rows and folds as the primary model; only the predictor set changes.")

cat(sprintf("S3 structural: %d predictors (removed %s)\n",
            length(s3_predictors), paste(structural_preds, collapse = ", ")))

## ---------------------------------------------------------------------------
## S4. PERSISTENCE BENCHMARK SAMPLE
##     Attach each CoC's PRIOR homelessness rate: the PIT rate observed in the
##     row's own predictor_year (t), predicting the target in t+1. This value is
##     known at prediction time; no future information is used.
##
##     ELIGIBILITY (a row is dropped, never back-filled with an older year):
##       (i)   the CoC-year must exist in the outcomes file;
##       (ii)  homeless_rate_per_10k_estimated must be present and finite;
##       (iii) the FY2024 population denominator must be available;
##       (iv)  pit_count_caution_flag must be 0 -- this is the project's own
##             reliability marker and it flags exactly the COVID-disrupted 2021
##             PIT, so every row whose predictor_year is 2021 is excluded.
##
##     A STRICTER variant is also emitted (S4b) which additionally requires the
##     prior count to be a full sheltered-and-unsheltered enumeration, dropping
##     sheltered-only and partial-unsheltered prior counts. Both eligibility
##     rules are reported; neither is applied silently.
## ---------------------------------------------------------------------------
outcomes_file <- file.path(project_root, "coc_analysis",
                           "coc_year_homelessness_outcomes_CA_FL_2010_2025.csv")
if (!file.exists(outcomes_file)) stop("Outcomes file not found: ", outcomes_file)
outcomes <- read.csv(outcomes_file, check.names = FALSE)

FULL_ENUMERATION_TYPES <- c("Sheltered and Unsheltered Count",
                            "Sheltered and full unsheltered count")

prior <- outcomes |>
  transmute(
    coc_number,
    predictor_year = as.integer(year),
    prior_homeless_rate_per_10k = as.numeric(homeless_rate_per_10k_estimated),
    prior_pit_caution_flag      = as.integer(pit_count_caution_flag),
    prior_count_type            = as.character(count_type),
    prior_denominator_status    = as.character(population_denominator_status)
  ) |>
  mutate(
    prior_available = is.finite(prior_homeless_rate_per_10k) &
      !grepl("^Unavailable", prior_denominator_status),
    prior_reliable  = prior_available & prior_pit_caution_flag == 0,
    prior_full_enumeration = prior_reliable & prior_count_type %in% FULL_ENUMERATION_TYPES
  )

joined <- primary |> left_join(prior, by = c("coc_number", "predictor_year"))
joined$prior_matched  <- !is.na(joined$prior_homeless_rate_per_10k) |
  !is.na(joined$prior_count_type)
joined$prior_reliable <- !is.na(joined$prior_reliable) & joined$prior_reliable
joined$prior_full_enumeration <- !is.na(joined$prior_full_enumeration) &
  joined$prior_full_enumeration

s4_cols  <- c(id_cols, target_col, control_cols, "prior_homeless_rate_per_10k",
              predictor_cols)
s4  <- joined[joined$prior_reliable, s4_cols, drop = FALSE]
s4b <- joined[joined$prior_full_enumeration, s4_cols, drop = FALSE]
stopifnot(all(is.finite(s4$prior_homeless_rate_per_10k)),
          all(is.finite(s4b$prior_homeless_rate_per_10k)))

## Row-level exclusion audit for the persistence sample.
drop4 <- joined[!joined$prior_reliable, , drop = FALSE]
if (nrow(drop4)) {
  reason4 <- ifelse(!drop4$prior_matched, "prior CoC-year absent from the outcomes file",
             ifelse(!is.finite(drop4$prior_homeless_rate_per_10k), "prior PIT rate missing",
             ifelse(grepl("^Unavailable", drop4$prior_denominator_status),
                    "prior-year population denominator unavailable",
                    "prior PIT flagged unreliable (pit_count_caution_flag == 1: COVID-disrupted 2021 count)")))
  for (r in unique(reason4))
    add_excl("S4_persistence", "row", "prior-year PIT eligibility", r, sum(reason4 == r))
}
extra_b <- sum(joined$prior_reliable & !joined$prior_full_enumeration)
add_excl("S4b_persistence_full_enum", "row", "prior-year PIT count type",
         "Prior count is sheltered-only or partial-unsheltered, not a full sheltered-and-unsheltered enumeration",
         extra_b)

write_sample("S4_persistence", s4)
write_sample("S4b_persistence_full_enum", s4b)
add_def("S4_persistence", "Persistence benchmark (reliable prior PIT)",
        paste("Keep rows whose predictor_year PIT rate is present, has an FY2024",
              "denominator, and carries pit_count_caution_flag == 0. Prior rate is",
              "the CoC's own predictor_year (t) PIT rate; the target is year t+1."),
        nrow(s4), length(unique(s4$coc_number)), length(predictor_cols) + 1L,
        sort(unique(s4$target_year)),
        sprintf("Dropped %d primary rows; every predictor_year == 2021 row is excluded because the 2021 PIT is COVID-disrupted.",
                nrow(primary) - nrow(s4)))
add_def("S4b_persistence_full_enum", "Persistence benchmark (full-enumeration prior PIT)",
        paste("S4 eligibility plus: prior count_type must be a full sheltered-and-unsheltered",
              "enumeration (excludes sheltered-only and partial-unsheltered prior counts)."),
        nrow(s4b), length(unique(s4b$coc_number)), length(predictor_cols) + 1L,
        sort(unique(s4b$target_year)),
        sprintf("Stricter eligibility variant; drops %d further rows beyond S4.", extra_b))

cat(sprintf("S4 persistence: %d eligible rows / %d CoCs (dropped %d). Excluded target years: %s\n",
            nrow(s4), length(unique(s4$coc_number)), nrow(primary) - nrow(s4),
            paste(setdiff(usable_target_years, unique(s4$target_year)), collapse = ", ")))
cat(sprintf("S4b full-enumeration prior: %d rows / %d CoCs\n",
            nrow(s4b), length(unique(s4b$coc_number))))

## Prior-count-type composition of the eligible persistence sample.
ct_tab <- as.data.frame(table(count_type = s4$prior_count_type <- joined$prior_count_type[joined$prior_reliable]),
                        stringsAsFactors = FALSE)
s4$prior_count_type <- NULL
names(ct_tab) <- c("prior_count_type", "n_rows")
write.csv(ct_tab, file.path(DEF_DIR, "S4_prior_count_type_composition.csv"), row.names = FALSE)

## ---------------------------------------------------------------------------
## S5. NO-HPI / FL-518 SENSITIVITY
##     Rebuild the v2 model table from the SAME audited v2 pipeline inputs used
##     by build_expanded_lasso_input_v2.R, with one change: the FHFA home-price
##     index (coc_relative_home_price_index_2000_base) is dropped from the
##     predictor set and therefore from the complete-case requirement. Nothing
##     is imputed, and no v1 column is read.
##
##     Integrity check: the same rebuild WITH the index must reproduce the
##     primary v2 workbook exactly. If it does not, the script stops.
## ---------------------------------------------------------------------------
candidate_file   <- file.path(project_root, "coc_analysis", "lasso_next_year_candidate_panel.csv")
state_file       <- file.path(project_root, "DSA Group 10 - Sheet1.csv")
hic_file         <- file.path(project_root, "raw_data", "2007-2025-HIC-Counts-by-CoC.xlsx")
county_panel_file<- file.path(project_root, "county_raw_panel", "county_year_raw_panel_CA_FL_2010_2025.csv")
crosswalk_file   <- file.path(project_root, "coc_analysis", "county_to_coc_population_crosswalk_FY2024.csv")
cpi_file         <- file.path(project_root, "raw_data", "fred_CPIAUCSL.csv")
lfpr_files       <- c(California = file.path(project_root, "raw_data", "fred_LBSSA06.csv"),
                      Florida    = file.path(project_root, "raw_data", "fred_LBSSA12.csv"))

req <- c(candidate_file, state_file, hic_file, county_panel_file, crosswalk_file,
         cpi_file, lfpr_files)
if (any(!file.exists(req)))
  stop("Missing audited v2 pipeline inputs:\n", paste(req[!file.exists(req)], collapse = "\n"))

to_number <- function(values) {
  values <- gsub(",", "", as.character(values), fixed = TRUE)
  values[values %in% c("", ".", "NA")] <- NA_character_
  suppressWarnings(as.numeric(values))
}
normalize_header <- function(values) trimws(gsub("[^a-z0-9]+", " ", tolower(values)))

read_hic_year_v2 <- function(year) {
  raw <- as.data.frame(read_excel(hic_file, sheet = as.character(year),
                                  col_names = FALSE, .name_repair = "minimal"))
  first_column <- trimws(as.character(raw[[1]]))
  header_row <- which(grepl("^CoC( Number)?$", first_column, ignore.case = TRUE))[1]
  if (is.na(header_row)) stop("Could not find the HIC header row for ", year, ".")
  headers    <- as.character(unlist(raw[header_row, ], use.names = FALSE))
  normalized <- normalize_header(headers)
  es  <- which(normalized %in% c("total year round beds es",  "total year round es beds"))[1]
  th  <- which(normalized %in% c("total year round beds th",  "total year round th beds"))[1]
  sh  <- which(normalized %in% c("total year round beds sh",  "total year round sh beds"))[1]
  psh <- which(normalized %in% c("total year round beds psh", "total year round psh beds"))[1]
  if (is.na(es) || is.na(th) || is.na(sh) || is.na(psh))
    stop("Could not locate common HIC capacity fields for ", year, ".")
  data_rows  <- raw[(header_row + 1):nrow(raw), , drop = FALSE]
  coc_number <- trimws(as.character(data_rows[[1]]))
  keep <- grepl("^(CA|FL)-[0-9]{3}$", coc_number)
  temporary_beds <- rowSums(cbind(to_number(data_rows[[es]]), to_number(data_rows[[th]]),
                                  to_number(data_rows[[sh]])), na.rm = FALSE)
  data.frame(coc_number = coc_number[keep], predictor_year = as.integer(year),
             hic_temporary_beds = temporary_beds[keep],
             hic_psh_beds = to_number(data_rows[[psh]][keep]), stringsAsFactors = FALSE)
}

cat("\nRebuilding the v2 assembly from audited pipeline inputs (S5)...\n")
hic_panel <- bind_rows(lapply(2010:2024, read_hic_year_v2))
if (anyDuplicated(hic_panel[c("coc_number", "predictor_year")]))
  stop("The HIC CoC-year key is not unique.")

cpi_raw <- read.csv(cpi_file, check.names = FALSE)
cpi_annual <- cpi_raw |>
  mutate(year = as.integer(substr(observation_date, 1, 4))) |>
  group_by(year) |>
  summarise(cpi_u = mean(CPIAUCSL, na.rm = TRUE), .groups = "drop")
cpi_2025 <- cpi_annual$cpi_u[cpi_annual$year == 2025]
to_real_2025 <- function(nominal, year) nominal * cpi_2025 / cpi_annual$cpi_u[match(year, cpi_annual$year)]

read_lfpr <- function(state, path) {
  raw <- read.csv(path, check.names = FALSE)
  series_col <- setdiff(names(raw), "observation_date")[1]
  raw |>
    mutate(year = as.integer(substr(observation_date, 1, 4))) |>
    group_by(year) |>
    summarise(state_labor_force_participation_pct = mean(.data[[series_col]], na.rm = TRUE),
              .groups = "drop") |>
    mutate(state = state)
}
lfpr_panel <- bind_rows(read_lfpr("California", lfpr_files[["California"]]),
                        read_lfpr("Florida",    lfpr_files[["Florida"]]))

state_panel <- read.csv(state_file, check.names = FALSE)
state_predictors <- state_panel |>
  transmute(state, predictor_year = year,
            state_anticamping_strictness    = anticamping_strictness,
            state_tanf_max_benefit_3person  = tanf_max_benefit_3person,
            state_ssi_state_supplement      = ssi_state_supplement,
            state_real_median_rent_2025_usd = real_median_rent_2025_usd,
            state_rental_vacancy_rate       = rental_vacancy_rate) |>
  left_join(lfpr_panel, by = c("state", "predictor_year" = "year"))

county_panel <- read.csv(county_panel_file, check.names = FALSE)
crosswalk    <- read.csv(crosswalk_file, check.names = FALSE)

county_with_coc <- crosswalk |>
  transmute(county_fips = sprintf("%05d", as.integer(county_fips)),
            coc_number, county_population_share) |>
  inner_join(county_panel |>
               transmute(county_fips = sprintf("%05d", as.integer(fips)), year,
                         hpi_2000_base, median_household_income,
                         permits_total_value_authorized, bea_real_gdp_quantity_index),
             by = "county_fips", relationship = "many-to-many")

available_case_weighted_mean <- function(values, weights, minimum_share = 0.40) {
  observed <- !is.na(values) & !is.na(weights)
  if (!any(observed)) return(NA_real_)
  if (sum(weights[observed]) / sum(weights) < minimum_share) return(NA_real_)
  weighted.mean(values[observed], weights[observed])
}

coc_home_price_panel <- county_with_coc |>
  group_by(coc_number, year) |>
  summarise(coc_relative_home_price_index_2000_base =
              available_case_weighted_mean(hpi_2000_base, county_population_share),
            coc_real_gdp_quantity_index =
              available_case_weighted_mean(bea_real_gdp_quantity_index, county_population_share),
            .groups = "drop") |>
  rename(predictor_year = year)

coc_permits_value_panel <- crosswalk |>
  transmute(county_fips = sprintf("%05d", as.integer(county_fips)),
            coc_number, county_population_share) |>
  inner_join(county_panel |>
               transmute(county_fips = sprintf("%05d", as.integer(fips)), year,
                         permits_total_value_authorized),
             by = "county_fips", relationship = "many-to-many") |>
  mutate(allocated_value = permits_total_value_authorized * county_population_share) |>
  group_by(coc_number, year) |>
  summarise(coc_permits_value_allocated_nominal_usd = sum(allocated_value, na.rm = FALSE),
            .groups = "drop") |>
  rename(predictor_year = year)

candidates <- read.csv(candidate_file, check.names = FALSE)

expanded <- candidates |>
  left_join(hic_panel,              by = c("coc_number", "predictor_year")) |>
  left_join(state_predictors,       by = c("state", "predictor_year")) |>
  left_join(coc_home_price_panel,   by = c("coc_number", "predictor_year")) |>
  left_join(coc_permits_value_panel, by = c("coc_number", "predictor_year")) |>
  mutate(control_state_florida = as.integer(state == "Florida"),
         control_time_index    = predictor_year - 2010L,
         coc_group_quarters_per_1000_residents = 1000 * group_quarters_population / estimated_coc_population,
         coc_hic_temporary_beds_per_10k = 10000 * hic_temporary_beds / estimated_coc_population,
         coc_hic_psh_beds_per_10k       = 10000 * hic_psh_beds / estimated_coc_population,
         coc_permits_value_per_1000_housing_units_2025_usd =
           to_real_2025(1000 * coc_permits_value_allocated_nominal_usd / housing_units, predictor_year)) |>
  transmute(
    state, state_abbr, coc_number, coc_name, predictor_year, target_year,
    target_homeless_rate_per_10k,
    control_state_florida, control_time_index,
    coc_log_estimated_population = log_estimated_coc_population,
    coc_population_density_per_sq_mile = population_density_per_sq_mile_derived,
    coc_contributing_counties = contributing_counties,
    coc_contains_split_county_flag = contains_split_county_flag,
    coc_housing_units_per_1000_residents = housing_units_per_1000_residents,
    coc_permits_per_1000_housing_units = permits_per_1000_housing_units,
    coc_multifamily_permit_share_pct = multifamily_permit_share_pct,
    coc_permits_value_per_1000_housing_units_2025_usd,
    coc_birth_rate_per_1000 = birth_rate_per_1000,
    coc_death_rate_per_1000 = death_rate_per_1000,
    coc_international_migration_rate_per_1000 = international_migration_rate_per_1000,
    coc_domestic_migration_rate_per_1000 = domestic_migration_rate_per_1000,
    coc_group_quarters_per_1000_residents,
    coc_population_growth_rate_pct = population_growth_rate_pct,
    coc_housing_supply_growth_rate_pct = housing_supply_growth_rate_pct,
    coc_poverty_all_pct = poverty_all_pct,
    coc_poverty_child_pct = poverty_child_pct,
    coc_real_median_household_income_2025_usd = real_median_household_income_2025_usd,
    coc_real_per_capita_personal_income_2025_usd = real_per_capita_personal_income_2025_usd,
    coc_unemployment_rate_pct = unemployment_rate_pct,
    coc_high_school_graduate_pct = high_school_graduate_or_higher_pct_age_18plus,
    coc_homeownership_rate_pct = homeownership_rate_pct,
    coc_housing_cost_burdened_households_pct = housing_cost_burdened_households_pct,
    coc_income_inequality_ratio = income_inequality_top_bottom_quintile_ratio,
    coc_annual_hpi_change_pct = annual_hpi_change_pct,
    coc_real_gdp_per_capita_2017_usd = real_gdp_per_capita_2017_usd,
    coc_real_gdp_quantity_index,
    coc_relative_home_price_index_2000_base,
    state_real_minimum_wage_2025_usd = real_state_minimum_wage_2025_usd,
    state_medicaid_expansion = medicaid_expansion_status,
    coc_hic_temporary_beds_per_10k,
    coc_hic_psh_beds_per_10k,
    state_anticamping_strictness,
    state_tanf_max_benefit_3person,
    state_ssi_state_supplement,
    state_labor_force_participation_pct,
    state_real_median_rent_2025_usd,
    state_rental_vacancy_rate)

complete_case <- function(df, fields) {
  keep <- Reduce(`&`, lapply(fields, function(f) {
    v <- df[[f]]
    if (is.numeric(v)) is.finite(v) else !is.na(v)
  }))
  df[keep, , drop = FALSE] |> arrange(state, coc_number, predictor_year)
}

HPI_COL <- "coc_relative_home_price_index_2000_base"
full_fields   <- c(target_col, control_cols, predictor_cols)
nohpi_fields  <- setdiff(full_fields, HPI_COL)

## Integrity check: the rebuild WITH the index must equal the primary workbook.
rebuild_with_hpi <- complete_case(expanded, full_fields)[, names(primary)]
prim_sorted <- primary |> arrange(state, coc_number, predictor_year)
if (nrow(rebuild_with_hpi) != nrow(prim_sorted))
  stop("S5 integrity check failed: rebuild has ", nrow(rebuild_with_hpi),
       " rows vs primary ", nrow(prim_sorted), ".")
num_cols <- names(prim_sorted)[vapply(prim_sorted, is.numeric, logical(1))]
## Relative tolerance: the workbook round-trip stores doubles at Excel precision,
## so a few large-magnitude fields differ in the ~1e-16 relative digit.
max_abs_diff <- max(vapply(num_cols, function(cn) {
  a <- rebuild_with_hpi[[cn]]; b <- prim_sorted[[cn]]
  max(abs(a - b) / pmax(1, abs(b)))
}, numeric(1)))
key_ok <- identical(paste(rebuild_with_hpi$coc_number, rebuild_with_hpi$predictor_year),
                    paste(prim_sorted$coc_number, prim_sorted$predictor_year))
if (!key_ok || max_abs_diff > 1e-10)
  stop("S5 integrity check failed: rebuild does not reproduce the primary v2 workbook ",
       "(key_ok = ", key_ok, ", max relative numeric diff = ", max_abs_diff, ").")
cat(sprintf("S5 integrity check PASSED: rebuild-with-HPI reproduces the primary v2 workbook (max relative diff = %.2e).\n",
            max_abs_diff))

s5_predictors <- setdiff(predictor_cols, HPI_COL)
s5 <- complete_case(expanded, nohpi_fields)[, c(id_cols, target_col, control_cols, s5_predictors)]

restored_rows <- anti_join(s5[c("coc_number", "predictor_year")],
                           primary[c("coc_number", "predictor_year")],
                           by = c("coc_number", "predictor_year"))
restored_cocs <- sort(unique(restored_rows$coc_number))
fl518_candidate_rows <- sum(candidates$coc_number == "FL-518")
fl518_restored       <- sum(restored_rows$coc_number == "FL-518")
fl518_still_dropped  <- fl518_candidate_rows - fl518_restored

add_excl("S5_no_hpi_fl518", "column", HPI_COL,
         "FHFA home-price index removed from the predictor requirement so HPI-dark CoCs are not excluded", 0L)
if (fl518_still_dropped > 0)
  add_excl("S5_no_hpi_fl518", "row", "FL-518",
           "Candidate-panel FL-518 rows still excluded because another required v2 predictor is missing (no imputation applied)",
           fl518_still_dropped)

write_sample("S5_no_hpi_fl518", s5)
add_def("S5_no_hpi_fl518", "No FHFA home-price index; FL-518 restored",
        paste("v2 pipeline rebuilt from the same audited inputs with",
              "coc_relative_home_price_index_2000_base dropped from the predictor set",
              "and from the complete-case requirement. No imputation; no v1 column used."),
        nrow(s5), length(unique(s5$coc_number)), length(s5_predictors),
        sort(unique(s5$target_year)),
        sprintf("Restores %d rows across %d CoC(s) (%s). FL-518 supplies %d of %d candidate-panel rows; %d remain excluded for other missing predictors.",
                nrow(restored_rows), length(restored_cocs), paste(restored_cocs, collapse = ", "),
                fl518_restored, fl518_candidate_rows, fl518_still_dropped))

cat(sprintf("S5 no-HPI: %d rows / %d CoCs (primary %d / %d). Restored %d rows, CoCs: %s\n",
            nrow(s5), length(unique(s5$coc_number)), nrow(primary),
            length(unique(primary$coc_number)), nrow(restored_rows),
            paste(restored_cocs, collapse = ", ")))

restored_detail <- s5 |>
  semi_join(restored_rows, by = c("coc_number", "predictor_year")) |>
  transmute(sample_id = "S5_no_hpi_fl518", coc_number, coc_name, state,
            predictor_year, target_year, target_homeless_rate_per_10k)
write.csv(restored_detail, file.path(DEF_DIR, "S5_restored_rows.csv"), row.names = FALSE)

## ---------------------------------------------------------------------------
## WRITE DEFINITION + EXCLUSION TABLES
## ---------------------------------------------------------------------------
sample_definitions <- do.call(rbind, sample_defs)
row_coc_exclusions <- do.call(rbind, exclusions)
write.csv(sample_definitions, file.path(DEF_DIR, "sensitivity_sample_definitions.csv"), row.names = FALSE)
write.csv(row_coc_exclusions, file.path(DEF_DIR, "sensitivity_row_coc_exclusions.csv"), row.names = FALSE)

## Predictor availability matrix across samples.
all_samples <- c("S0_primary", "S1_split_county_excluded", "S2_stable_cocs",
                 "S3_no_structural_beds", "S4_persistence",
                 "S4b_persistence_full_enum", "S5_no_hpi_fl518")
pred_sets <- list(S0_primary = predictor_cols, S1_split_county_excluded = s1_predictors,
                  S2_stable_cocs = predictor_cols, S3_no_structural_beds = s3_predictors,
                  S4_persistence = c(predictor_cols, "prior_homeless_rate_per_10k"),
                  S4b_persistence_full_enum = c(predictor_cols, "prior_homeless_rate_per_10k"),
                  S5_no_hpi_fl518 = s5_predictors)
all_preds <- sort(unique(unlist(pred_sets)))
pred_matrix <- data.frame(predictor = all_preds, stringsAsFactors = FALSE)
for (s in all_samples) pred_matrix[[s]] <- as.integer(all_preds %in% pred_sets[[s]])
write.csv(pred_matrix, file.path(DEF_DIR, "sensitivity_predictor_availability.csv"), row.names = FALSE)

manifest <- data.frame(
  field = c("primary_input", "primary_input_md5", "expected_v2_md5", "md5_matches",
            "usable_v2_target_years", "n_usable_target_years",
            "stability_definition", "prior_rate_definition",
            "prior_reliability_rule", "s5_rebuild_integrity_check",
            "imputation", "R_version", "timestamp_utc"),
  value = c(PRIMARY_FILE, primary_md5, EXPECTED_V2_MD5,
            identical(primary_md5, EXPECTED_V2_MD5),
            paste(usable_target_years, collapse = ";"), length(usable_target_years),
            sprintf("A CoC is stable iff it supplies a modeling row in all %d usable v2 target years",
                    length(usable_target_years)),
            "prior_homeless_rate_per_10k = the CoC's PIT rate in its own predictor_year (t); target is t+1; no future value used",
            "available rate + FY2024 denominator + pit_count_caution_flag == 0 (excludes the COVID-disrupted 2021 PIT); ineligible rows are dropped, never back-filled",
            sprintf("PASSED (max relative numeric diff %.2e vs primary workbook)", max_abs_diff),
            "none anywhere",
            R.version.string,
            format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")),
  stringsAsFactors = FALSE)
write.csv(manifest, file.path(DEF_DIR, "sensitivity_input_manifest.csv"), row.names = FALSE)

banner("Sensitivity sample definitions")
print(sample_definitions[, c("sample_id", "n_rows", "n_cocs", "n_predictors",
                             "n_target_years", "rows_vs_primary")], row.names = FALSE)
cat("\nWritten to ", OUT_DIR, "/ (data/ and definitions/).\n", sep = "")
