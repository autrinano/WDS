options(stringsAsFactors = FALSE)

project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) {
  .libPaths(c(local_r_lib, .libPaths()))
}

required_packages <- c("dplyr", "readxl", "openxlsx", "tidyr")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0) {
  stop(
    "Install the required R packages before rebuilding: ",
    paste(missing_packages, collapse = ", ")
  )
}

library(dplyr)
library(readxl)
library(openxlsx)
library(tidyr)

candidate_file <- file.path(
  project_root, "coc_analysis", "lasso_next_year_candidate_panel.csv"
)
state_file <- file.path(project_root, "DSA Group 10 - Sheet1.csv")
hic_file <- file.path(
  project_root, "raw_data", "2007-2025-HIC-Counts-by-CoC.xlsx"
)
county_panel_file <- file.path(
  project_root, "county_raw_panel", "county_year_raw_panel_CA_FL_2010_2025.csv"
)
crosswalk_file <- file.path(
  project_root, "coc_analysis", "county_to_coc_population_crosswalk_FY2024.csv"
)
cpi_file <- file.path(project_root, "raw_data", "fred_CPIAUCSL.csv")
lfpr_files <- c(
  California = file.path(project_root, "raw_data", "fred_LBSSA06.csv"),
  Florida = file.path(project_root, "raw_data", "fred_LBSSA12.csv")
)
output_dir <- file.path(project_root, "outputs", "lasso_model")
output_file <- file.path(output_dir, "CA_FL_LASSO_MODEL_INPUT_v2.xlsx")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

required_files <- c(
  candidate_file, state_file, hic_file, county_panel_file,
  crosswalk_file, cpi_file, lfpr_files
)
if (any(!file.exists(required_files))) {
  stop(
    "Missing required files:\n",
    paste(required_files[!file.exists(required_files)], collapse = "\n")
  )
}

to_number <- function(values) {
  values <- gsub(",", "", as.character(values), fixed = TRUE)
  values[values %in% c("", ".", "NA")] <- NA_character_
  suppressWarnings(as.numeric(values))
}

normalize_header <- function(values) {
  trimws(gsub("[^a-z0-9]+", " ", tolower(values)))
}

## ---------------------------------------------------------------------
## 1. HUD HIC bed capacity: temporary (ES+TH+SH) and PSH, unchanged from v1.
##    A Rapid Re-Housing (RRH) bed predictor was investigated for v2 but
##    dropped: HUD's HIC workbook has no standalone RRH column for
##    2010-2012, folds RRH into the combined shelter total for 2013 (the
##    same problem flagged in DATA_LOG.md methodology note 4), and reports
##    a mixed "RRH & DEM" (Rapid Re-Housing plus Demonstration program)
##    category starting in 2014. There is no way to isolate a clean,
##    comparably-defined RRH bed count across the full 2010-2024 panel
##    without either truncating most of the panel or coalescing
##    definitions, so it is excluded rather than guessed.
## ---------------------------------------------------------------------
read_hic_year_v2 <- function(year) {
  raw <- as.data.frame(
    read_excel(
      hic_file,
      sheet = as.character(year),
      col_names = FALSE,
      .name_repair = "minimal"
    )
  )
  first_column <- trimws(as.character(raw[[1]]))
  header_row <- which(grepl("^CoC( Number)?$", first_column, ignore.case = TRUE))[1]
  if (is.na(header_row)) {
    stop("Could not find the HIC header row for ", year, ".")
  }

  headers <- as.character(unlist(raw[header_row, ], use.names = FALSE))
  normalized <- normalize_header(headers)
  es_column <- which(normalized %in% c(
    "total year round beds es", "total year round es beds"
  ))[1]
  th_column <- which(normalized %in% c(
    "total year round beds th", "total year round th beds"
  ))[1]
  sh_column <- which(normalized %in% c(
    "total year round beds sh", "total year round sh beds"
  ))[1]
  psh_column <- which(normalized %in% c(
    "total year round beds psh", "total year round psh beds"
  ))[1]
  if (
    is.na(es_column) || is.na(th_column) || is.na(sh_column) ||
      is.na(psh_column)
  ) {
    stop("Could not locate common HIC capacity fields for ", year, ".")
  }

  data_rows <- raw[(header_row + 1):nrow(raw), , drop = FALSE]
  coc_number <- trimws(as.character(data_rows[[1]]))
  keep <- grepl("^(CA|FL)-[0-9]{3}$", coc_number)
  temporary_beds <- rowSums(
    cbind(
      to_number(data_rows[[es_column]]),
      to_number(data_rows[[th_column]]),
      to_number(data_rows[[sh_column]])
    ),
    na.rm = FALSE
  )
  data.frame(
    coc_number = coc_number[keep],
    predictor_year = as.integer(year),
    hic_temporary_beds = temporary_beds[keep],
    hic_psh_beds = to_number(data_rows[[psh_column]][keep]),
    stringsAsFactors = FALSE
  )
}

hic_panel <- bind_rows(lapply(2010:2024, read_hic_year_v2))
if (anyDuplicated(hic_panel[c("coc_number", "predictor_year")])) {
  stop("The HIC CoC-year key is not unique.")
}

## ---------------------------------------------------------------------
## 2. CPI-U annual average, for constant-2025-dollar conversions
##    (same method as the rest of the project: mean of monthly CPI-U by
##    calendar year; 2025 is the reference year).
## ---------------------------------------------------------------------
cpi_raw <- read.csv(cpi_file, check.names = FALSE)
cpi_annual <- cpi_raw |>
  mutate(year = as.integer(substr(observation_date, 1, 4))) |>
  group_by(year) |>
  summarise(cpi_u = mean(CPIAUCSL, na.rm = TRUE), .groups = "drop")
cpi_2025 <- cpi_annual$cpi_u[cpi_annual$year == 2025]
to_real_2025 <- function(nominal, year) {
  cpi_year <- cpi_annual$cpi_u[match(year, cpi_annual$year)]
  nominal * cpi_2025 / cpi_year
}

## ---------------------------------------------------------------------
## 3. State labor force participation rebuilt directly from FRED LBSSA06 /
##    LBSSA12 (BLS LAUS, distributed via FRED). This replaces the inherited
##    team-sheet column, which had no recorded source, with an official
##    series already downloaded for this project. Annualized as the mean of
##    monthly values in each calendar year, matching the CPI/HVS convention
##    used elsewhere in this project.
## ---------------------------------------------------------------------
read_lfpr <- function(state, path) {
  raw <- read.csv(path, check.names = FALSE)
  series_col <- setdiff(names(raw), "observation_date")[1]
  raw |>
    mutate(year = as.integer(substr(observation_date, 1, 4))) |>
    group_by(year) |>
    summarise(
      state_labor_force_participation_pct = mean(.data[[series_col]], na.rm = TRUE),
      .groups = "drop"
    ) |>
    mutate(state = state)
}
lfpr_panel <- bind_rows(
  read_lfpr("California", lfpr_files[["California"]]),
  read_lfpr("Florida", lfpr_files[["Florida"]])
)

## ---------------------------------------------------------------------
## 4. Retained state-year variables with a documented source:
##    - medicaid_expansion_status and real_state_minimum_wage_2025_usd are
##      already CoC-level fields from the county pipeline (CMS/KFF and
##      U.S. DOL via FRED; see county_raw_panel/source_log.csv) and are
##      read directly from `candidates` below, unchanged from v1.
##    - anticamping_strictness, tanf_max_benefit_3person, and
##      ssi_state_supplement are hand-collected but documented with
##      per-factor citations (CBPP, LAO, Urban Institute WRD, SSA, and the
##      cited court/legislative record) in DATA_LOG.md sections 31-33.
##    - real_median_rent_2025_usd and rental_vacancy_rate are the verified
##      Census/HVS-based housing_metrics series (see
##      DATA_SOURCES_AND_ASSUMPTIONS.md).
##    All other inherited team-sheet state variables (funding per capita,
##    substance use disorder rate, serious mental illness rate, uninsured
##    rate, student debt, in-state tuition, age shares, household size,
##    and the state-level home price/growth trio superseded by new local
##    measures) are DROPPED in v2. See CHANGELOG_v1_to_v2.md for the
##    per-variable audit disposition and the specific sources that were
##    checked and could not be verified within this build.
## ---------------------------------------------------------------------
state_panel <- read.csv(state_file, check.names = FALSE)
state_predictors <- state_panel |>
  transmute(
    state,
    predictor_year = year,
    state_anticamping_strictness = anticamping_strictness,
    state_tanf_max_benefit_3person = tanf_max_benefit_3person,
    state_ssi_state_supplement = ssi_state_supplement,
    state_real_median_rent_2025_usd = real_median_rent_2025_usd,
    state_rental_vacancy_rate = rental_vacancy_rate
  ) |>
  left_join(lfpr_panel, by = c("state", "predictor_year" = "year"))

## ---------------------------------------------------------------------
## 5. Local (CoC-level) relative home-price level, built from the FHFA
##    county House Price Index rebased to a 2000=100 common base
##    (hpi_2000_base, already in county_raw_panel and already documented
##    there as "Federal Housing Finance Agency / Housing market"),
##    allocated to FY2024 CoC geography with the project's existing
##    population-share crosswalk.
##
##    TWO ALTERNATIVES WERE TRIED AND REJECTED FIRST:
##    (1) Zillow county median sale price (a true dollar figure) was tried
##        first, since it is the more directly interpretable "median home
##        price" concept the improvement was originally scoped around.
##        Under the standard CoC aggregation used elsewhere in this
##        project (>=90% weighted population coverage), it is 100% missing
##        at the CoC level. Even under a looser available-case,
##        population-weighted average (>=40% weighted coverage), it is
##        still missing for 96 of 974 CoC-years, concentrated almost
##        entirely in 8 small/rural CoCs (CA-516, CA-523, CA-530, FL-506,
##        FL-508, FL-515, FL-517, FL-518) that never have ANY published
##        Zillow value in ANY contributing county for ANY year -- a
##        structural, not a coverage-threshold, gap. That loss would drop
##        the final complete-case panel to 814 rows, below the 850-row
##        floor, so Zillow-based dollar price and any ratio built from it
##        (home-price-to-income) are excluded rather than forced or
##        fabricated for those CoCs.
##    (2) The FHFA HPI used here has only 16 missing CoC-years out of
##        1,136 (vs. Zillow's 96) and covers 7 of the 8 Zillow-dark CoCs;
##        only FL-518 remains fully uncovered. It is a repeat-sales
##        quality-adjusted INDEX, not a dollar price, so it cannot be
##        divided by income to produce an affordability ratio -- it
##        measures relative price LEVEL and trajectory, comparable across
##        CoCs because every county is rebased to the same 2000=100 point.
##        coc_annual_hpi_change_pct (unchanged from v1) already captures
##        local home-price GROWTH; this new field adds the complementary
##        cross-sectional LEVEL, which v1 did not have at CoC granularity.
##
##    The same available-case, population-weighted aggregation is used,
##    with the same >=40% weighted-coverage floor documented above.
## ---------------------------------------------------------------------
county_panel <- read.csv(county_panel_file, check.names = FALSE)
crosswalk <- read.csv(crosswalk_file, check.names = FALSE)

county_with_coc <- crosswalk |>
  transmute(
    county_fips = sprintf("%05d", as.integer(county_fips)),
    coc_number, county_population_share
  ) |>
  inner_join(
    county_panel |>
      transmute(
        county_fips = sprintf("%05d", as.integer(fips)),
        year,
        hpi_2000_base,
        median_household_income,
        permits_total_value_authorized,
        bea_real_gdp_quantity_index
      ),
    by = "county_fips", relationship = "many-to-many"
  )

available_case_weighted_mean <- function(values, weights, minimum_share = 0.40) {
  observed <- !is.na(values) & !is.na(weights)
  if (!any(observed)) {
    return(NA_real_)
  }
  covered_share <- sum(weights[observed]) / sum(weights)
  if (covered_share < minimum_share) {
    return(NA_real_)
  }
  weighted.mean(values[observed], weights[observed])
}

coc_home_price_panel <- county_with_coc |>
  group_by(coc_number, year) |>
  summarise(
    coc_relative_home_price_index_2000_base = available_case_weighted_mean(
      hpi_2000_base, county_population_share
    ),
    coc_real_gdp_quantity_index = available_case_weighted_mean(
      bea_real_gdp_quantity_index, county_population_share
    ),
    .groups = "drop"
  ) |>
  rename(predictor_year = year)

## ---------------------------------------------------------------------
## 5b. Real GDP quantity index (chain-type, base year set by BEA), CoC-level.
##    Distinct from the existing coc_real_gdp_per_capita_2017_usd (a dollar
##    LEVEL): this captures real economic MOMENTUM/growth trajectory, which
##    a CoC can have independent of its income level. Same source (BEA
##    CAGDP1) and same underlying coverage as the per-capita GDP measure
##    already in the v1 panel, so this does not introduce any additional
##    missingness beyond what real GDP per capita already requires.
## ---------------------------------------------------------------------

## ---------------------------------------------------------------------
## 6. New housing-supply predictor: dollar value of newly authorized
##    construction per 1,000 existing housing units, in constant 2025
##    dollars. This is distinct from the unit-COUNT permit measures
##    already in the panel (coc_permits_per_1000_housing_units,
##    coc_multifamily_permit_share_pct): it captures the dollar intensity
##    / quality mix of new construction, which those count-based measures
##    cannot. Source: U.S. Census Bureau / HUD Building Permits Survey
##    (already in county_raw_panel), allocated to CoC with the same
##    population-share method used elsewhere in this project for strict
##    allocated sums (full, non-missing coverage; no coverage threshold
##    needed because the underlying county series has 100% coverage).
## ---------------------------------------------------------------------
coc_permits_value_panel <- crosswalk |>
  transmute(
    county_fips = sprintf("%05d", as.integer(county_fips)),
    coc_number, county_population_share
  ) |>
  inner_join(
    county_panel |>
      transmute(
        county_fips = sprintf("%05d", as.integer(fips)),
        year,
        permits_total_value_authorized
      ),
    by = "county_fips", relationship = "many-to-many"
  ) |>
  mutate(
    allocated_value = permits_total_value_authorized * county_population_share
  ) |>
  group_by(coc_number, year) |>
  summarise(
    coc_permits_value_allocated_nominal_usd = sum(allocated_value, na.rm = FALSE),
    .groups = "drop"
  ) |>
  rename(predictor_year = year)

## ---------------------------------------------------------------------
## 7. Assemble the expanded panel.
## ---------------------------------------------------------------------
candidates <- read.csv(candidate_file, check.names = FALSE)

expanded <- candidates |>
  left_join(hic_panel, by = c("coc_number", "predictor_year")) |>
  left_join(state_predictors, by = c("state", "predictor_year")) |>
  left_join(coc_home_price_panel, by = c("coc_number", "predictor_year")) |>
  left_join(coc_permits_value_panel, by = c("coc_number", "predictor_year")) |>
  mutate(
    control_state_florida = as.integer(state == "Florida"),
    control_time_index = predictor_year - 2010L,
    coc_group_quarters_per_1000_residents =
      1000 * group_quarters_population / estimated_coc_population,
    coc_hic_temporary_beds_per_10k =
      10000 * hic_temporary_beds / estimated_coc_population,
    coc_hic_psh_beds_per_10k =
      10000 * hic_psh_beds / estimated_coc_population,
    coc_permits_value_per_1000_housing_units_2025_usd = to_real_2025(
      1000 * coc_permits_value_allocated_nominal_usd / housing_units,
      predictor_year
    )
  ) |>
  transmute(
    state,
    state_abbr,
    coc_number,
    coc_name,
    predictor_year,
    target_year,
    target_homeless_rate_per_10k,
    control_state_florida,
    control_time_index,
    coc_log_estimated_population = log_estimated_coc_population,
    coc_population_density_per_sq_mile =
      population_density_per_sq_mile_derived,
    coc_contributing_counties = contributing_counties,
    coc_contains_split_county_flag = contains_split_county_flag,
    coc_housing_units_per_1000_residents =
      housing_units_per_1000_residents,
    coc_permits_per_1000_housing_units =
      permits_per_1000_housing_units,
    coc_multifamily_permit_share_pct =
      multifamily_permit_share_pct,
    coc_permits_value_per_1000_housing_units_2025_usd,
    coc_birth_rate_per_1000 = birth_rate_per_1000,
    coc_death_rate_per_1000 = death_rate_per_1000,
    coc_international_migration_rate_per_1000 =
      international_migration_rate_per_1000,
    coc_domestic_migration_rate_per_1000 =
      domestic_migration_rate_per_1000,
    coc_group_quarters_per_1000_residents,
    coc_population_growth_rate_pct = population_growth_rate_pct,
    coc_housing_supply_growth_rate_pct =
      housing_supply_growth_rate_pct,
    coc_poverty_all_pct = poverty_all_pct,
    coc_poverty_child_pct = poverty_child_pct,
    coc_real_median_household_income_2025_usd =
      real_median_household_income_2025_usd,
    coc_real_per_capita_personal_income_2025_usd =
      real_per_capita_personal_income_2025_usd,
    coc_unemployment_rate_pct = unemployment_rate_pct,
    coc_high_school_graduate_pct =
      high_school_graduate_or_higher_pct_age_18plus,
    coc_homeownership_rate_pct = homeownership_rate_pct,
    coc_housing_cost_burdened_households_pct =
      housing_cost_burdened_households_pct,
    coc_income_inequality_ratio =
      income_inequality_top_bottom_quintile_ratio,
    coc_annual_hpi_change_pct = annual_hpi_change_pct,
    coc_real_gdp_per_capita_2017_usd =
      real_gdp_per_capita_2017_usd,
    coc_real_gdp_quantity_index,
    coc_relative_home_price_index_2000_base,
    state_real_minimum_wage_2025_usd =
      real_state_minimum_wage_2025_usd,
    state_medicaid_expansion = medicaid_expansion_status,
    coc_hic_temporary_beds_per_10k,
    coc_hic_psh_beds_per_10k,
    state_anticamping_strictness,
    state_tanf_max_benefit_3person,
    state_ssi_state_supplement,
    state_labor_force_participation_pct,
    state_real_median_rent_2025_usd,
    state_rental_vacancy_rate
  )

id_columns <- c(
  "state", "state_abbr", "coc_number", "coc_name",
  "predictor_year", "target_year"
)
target_column <- "target_homeless_rate_per_10k"
control_columns <- c("control_state_florida", "control_time_index")
predictor_columns <- setdiff(
  names(expanded),
  c(id_columns, target_column, control_columns)
)
model_fields <- c(target_column, control_columns, predictor_columns)

is_finite_field <- function(x) {
  if (is.numeric(x)) all(is.finite(x)) else all(!is.na(x))
}

model_data <- expanded |>
  filter(if_all(all_of(model_fields), ~ !is.na(.x))) |>
  filter(if_all(all_of(model_fields), ~ if (is.numeric(.x)) is.finite(.x) else TRUE)) |>
  arrange(state, coc_number, predictor_year)

## ---------------------------------------------------------------------
## 8. Validation
## ---------------------------------------------------------------------
prohibited_patterns <- c(
  "^target_total", "^target_estimated", "pit_count_caution",
  "target_definition", "^total_homeless$", "^sheltered_homeless$",
  "^unsheltered_homeless$", "funding_per_homeless",
  "beds_per_100_homeless"
)
prohibited_present <- unique(unlist(lapply(
  prohibited_patterns,
  function(pattern) grep(pattern, names(model_data), value = TRUE)
)))

model_key <- paste(
  model_data$coc_number, model_data$predictor_year, sep = "|"
)
n_model_fields_finite <- all(vapply(
  model_data[model_fields],
  is_finite_field,
  logical(1)
))

validation <- data.frame(
  check = c(
    "The CoC and predictor-year key is unique",
    "Every outcome is exactly one year after its predictors",
    "The disrupted 2021 PIT target is excluded",
    "The one-sheet model input has no missing values",
    "Every numeric target/control/predictor value is finite (no NA/NaN/Inf)",
    "The target has positive variation",
    "Every control and predictor has variation",
    "No prohibited leakage field is present",
    "Both California and Florida are represented",
    "Official HIC capacity rates are nonnegative",
    "At least 850 modeling rows are retained",
    "No audit-excluded (unverifiable) state variable remains in the panel"
  ),
  pass = c(
    !anyDuplicated(model_key),
    all(model_data$target_year == model_data$predictor_year + 1),
    !any(model_data$target_year == 2021),
    !anyNA(model_data),
    n_model_fields_finite,
    length(unique(model_data[[target_column]])) > 1,
    all(vapply(
      model_data[c(control_columns, predictor_columns)],
      function(values) length(unique(values)) > 1,
      logical(1)
    )),
    length(prohibited_present) == 0,
    identical(sort(unique(model_data$state)), c("California", "Florida")),
    all(model_data$coc_hic_temporary_beds_per_10k >= 0) &&
      all(model_data$coc_hic_psh_beds_per_10k >= 0),
    nrow(model_data) >= 850,
    !any(grepl(
      paste(
        "state_homeless_funding_per_capita",
        "state_substance_use_disorder_rate",
        "state_serious_mental_illness_rate",
        "state_uninsured_rate",
        "state_average_student_debt_per_borrower",
        "state_avg_in_state_tuition",
        "state_pct_age_18_24",
        "state_pct_age_65plus",
        "state_avg_household_size",
        "state_real_median_home_price_2025_usd",
        "state_home_price_to_income_ratio",
        "state_real_home_price_growth_pct",
        sep = "|"
      ),
      names(model_data)
    ))
  ),
  stringsAsFactors = FALSE
)

if (!all(validation$pass)) {
  stop(
    "Expanded v2 model-input validation failed:\n",
    paste(validation$check[!validation$pass], collapse = "\n")
  )
}

## ---------------------------------------------------------------------
## 9. Workbook
## ---------------------------------------------------------------------
wb <- createWorkbook(creator = "California–Florida Homelessness Project")
addWorksheet(wb, "LASSO Model Data", gridLines = FALSE, zoom = 80)
writeData(wb, "LASSO Model Data", model_data, keepNA = FALSE)

id_header_style <- createStyle(
  fgFill = "#595959", fontColour = "#FFFFFF",
  textDecoration = "bold", halign = "center",
  valign = "center", wrapText = TRUE
)
target_header_style <- createStyle(
  fgFill = "#C65911", fontColour = "#FFFFFF",
  textDecoration = "bold", halign = "center",
  valign = "center", wrapText = TRUE
)
control_header_style <- createStyle(
  fgFill = "#548235", fontColour = "#FFFFFF",
  textDecoration = "bold", halign = "center",
  valign = "center", wrapText = TRUE
)
predictor_header_style <- createStyle(
  fgFill = "#1F4E78", fontColour = "#FFFFFF",
  textDecoration = "bold", halign = "center",
  valign = "center", wrapText = TRUE
)
new_predictor_header_style <- createStyle(
  fgFill = "#7030A0", fontColour = "#FFFFFF",
  textDecoration = "bold", halign = "center",
  valign = "center", wrapText = TRUE
)
year_style <- createStyle(numFmt = "0")
integer_style <- createStyle(numFmt = "#,##0")
decimal_style <- createStyle(numFmt = "0.00")
currency_style <- createStyle(numFmt = "$#,##0")
currency_two_style <- createStyle(numFmt = "$#,##0.00")

new_v2_columns <- c(
  "coc_permits_value_per_1000_housing_units_2025_usd",
  "coc_relative_home_price_index_2000_base",
  "coc_real_gdp_quantity_index"
)

id_indices <- match(id_columns, names(model_data))
target_index <- match(target_column, names(model_data))
control_indices <- match(control_columns, names(model_data))
new_indices <- match(new_v2_columns, names(model_data))
predictor_indices <- setdiff(
  match(predictor_columns, names(model_data)), new_indices
)

addStyle(wb, "LASSO Model Data", id_header_style, rows = 1, cols = id_indices, gridExpand = TRUE)
addStyle(wb, "LASSO Model Data", target_header_style, rows = 1, cols = target_index, gridExpand = TRUE)
addStyle(wb, "LASSO Model Data", control_header_style, rows = 1, cols = control_indices, gridExpand = TRUE)
addStyle(wb, "LASSO Model Data", predictor_header_style, rows = 1, cols = predictor_indices, gridExpand = TRUE)
addStyle(wb, "LASSO Model Data", new_predictor_header_style, rows = 1, cols = new_indices, gridExpand = TRUE)

data_rows <- 2:(nrow(model_data) + 1)
headers <- names(model_data)
year_indices <- which(grepl("(^predictor_year$|^target_year$|time_index$)", headers))
currency_indices <- which(grepl(
  "usd|tanf|max_benefit|supplement",
  headers, ignore.case = TRUE
))
decimal_indices <- which(grepl(
  paste(
    "rate|pct|ratio|per_10|per_100|per_1000|density|growth|income|population",
    "participation",
    sep = "|"
  ),
  headers, ignore.case = TRUE
))
numeric_indices <- which(vapply(model_data, is.numeric, logical(1)))
integer_indices <- setdiff(
  numeric_indices,
  union(year_indices, union(currency_indices, decimal_indices))
)

if (length(integer_indices) > 0) {
  addStyle(wb, "LASSO Model Data", integer_style, rows = data_rows, cols = integer_indices, gridExpand = TRUE, stack = TRUE)
}
if (length(decimal_indices) > 0) {
  addStyle(wb, "LASSO Model Data", decimal_style, rows = data_rows, cols = decimal_indices, gridExpand = TRUE, stack = TRUE)
}
if (length(currency_indices) > 0) {
  addStyle(wb, "LASSO Model Data", currency_style, rows = data_rows, cols = currency_indices, gridExpand = TRUE, stack = TRUE)
}
if (length(year_indices) > 0) {
  addStyle(wb, "LASSO Model Data", year_style, rows = data_rows, cols = year_indices, gridExpand = TRUE, stack = TRUE)
}

setRowHeights(wb, "LASSO Model Data", rows = 1, heights = 72)
setColWidths(wb, "LASSO Model Data", cols = 1:ncol(model_data), widths = 15)
setColWidths(wb, "LASSO Model Data", cols = match("state", headers), widths = 13)
setColWidths(wb, "LASSO Model Data", cols = match("state_abbr", headers), widths = 11)
setColWidths(wb, "LASSO Model Data", cols = match("coc_number", headers), widths = 13)
setColWidths(wb, "LASSO Model Data", cols = match("coc_name", headers), widths = 36)
setColWidths(
  wb, "LASSO Model Data",
  cols = match(c("predictor_year", "target_year"), headers),
  widths = c(14, 12)
)
setColWidths(wb, "LASSO Model Data", cols = target_index, widths = 21)
freezePane(wb, "LASSO Model Data", firstActiveRow = 2, firstActiveCol = 8)
addFilter(wb, "LASSO Model Data", rows = 1, cols = 1:ncol(model_data))
pageSetup(wb, "LASSO Model Data", orientation = "landscape", fitToWidth = 3, fitToHeight = 0)

header_comments <- lapply(headers, function(variable) {
  if (variable %in% id_columns) {
    paste(
      "ROLE: identifier / validation only.",
      "Do not include this column in the penalized LASSO design matrix."
    )
  } else if (variable == target_column) {
    paste(
      "ROLE: outcome.",
      "Next-year HUD PIT homelessness per 10,000 estimated CoC residents."
    )
  } else if (variable %in% control_columns) {
    paste(
      "ROLE: baseline control.",
      "Recommended penalty.factor = 0 so this control is retained."
    )
  } else if (variable == "coc_permits_value_per_1000_housing_units_2025_usd") {
    paste(
      "ROLE: candidate predictor (NEW in v2).",
      "SOURCE: U.S. Census Bureau/HUD Building Permits Survey (county_raw_panel), constant 2025 USD,",
      "allocated to CoC with the FY2024 population-share crosswalk.",
      "Captures dollar intensity of new construction, distinct from the existing unit-count permit measures."
    )
  } else if (variable == "coc_relative_home_price_index_2000_base") {
    paste(
      "ROLE: candidate predictor (NEW in v2).",
      "SOURCE: FHFA county House Price Index rebased to 2000=100 (county_raw_panel), allocated to CoC with an",
      "available-case population-weighted average (>=40% weighted county coverage required). This is a",
      "repeat-sales quality-adjusted price INDEX, not a dollar price; comparable across CoCs because every",
      "county shares the same 2000 base. A local dollar median-home-price/income-ratio measure was",
      "investigated first (Zillow county median sale price) but rejected because 8 small/rural CoCs never",
      "have any published Zillow value, which would drop the panel below 850 rows; see",
      "CHANGELOG_v1_to_v2.md for the full comparison."
    )
  } else if (variable == "coc_real_gdp_quantity_index") {
    paste(
      "ROLE: candidate predictor (NEW in v2).",
      "SOURCE: BEA CAGDP1 real GDP chain-type quantity index (county_raw_panel), allocated to CoC with the",
      "same available-case population-weighted method. Captures local economic growth MOMENTUM, distinct",
      "from the existing coc_real_gdp_per_capita_2017_usd dollar LEVEL measure."
    )
  } else if (grepl("^coc_hic_", variable)) {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE: official HUD HIC CoC-year counts, normalized by estimated CoC population."
    )
  } else if (grepl("^coc_", variable)) {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE: county-year panel allocated to CoCs using FY2024 boundaries and ACS 2024 tract-population shares."
    )
  } else if (variable == "state_labor_force_participation_pct") {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE: BLS LAUS state labor force participation rate, distributed via FRED (LBSSA06/LBSSA12),",
      "annualized as the mean of monthly values. Rebuilt in v2 from a verified official series (previously",
      "an undocumented inherited team-sheet column)."
    )
  } else if (variable %in% c(
    "state_real_minimum_wage_2025_usd",
    "state_medicaid_expansion",
    "state_real_median_rent_2025_usd",
    "state_rental_vacancy_rate"
  )) {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE: documented or reproducibly derived state-year project series (see DATA_SOURCES_AND_ASSUMPTIONS.md)."
    )
  } else if (variable %in% c(
    "state_anticamping_strictness",
    "state_tanf_max_benefit_3person",
    "state_ssi_state_supplement"
  )) {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE: hand-collected with per-year citations documented in DATA_LOG.md (methodology sections 31-33:",
      "CBPP, LAO, Urban Institute Welfare Rules Database, SSA, and the cited legal/legislative record).",
      "state_anticamping_strictness is a constructed ordinal policy index, not a directly measured quantity."
    )
  } else {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE STATUS: inherited state-year project series; source verification is still needed."
    )
  }
})

for (column_index in seq_along(headers)) {
  writeComment(
    wb,
    sheet = "LASSO Model Data",
    col = column_index,
    row = 1,
    comment = createComment(
      header_comments[[column_index]],
      author = "California–Florida Homelessness Project",
      visible = FALSE
    )
  )
}

saveWorkbook(wb, output_file, overwrite = TRUE)

message(
  "Built v2 one-sheet LASSO input with ", nrow(model_data), " rows, ",
  ncol(model_data), " total columns, and ",
  length(c(control_columns, predictor_columns)),
  " controls/predictors; all ", nrow(validation), " checks passed."
)
