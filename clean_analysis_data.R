#!/usr/bin/env Rscript

# Create cleaned, analysis-specific datasets without fabricating observations.
# Structural and source-related gaps remain NA in the broad cleaned panel.
# Complete analysis panels are created by selecting appropriate variables,
# years, and definitions rather than by outcome-based or global imputation.

project_dir <- normalizePath(getwd(), mustWork = TRUE)
if (basename(project_dir) != "Final Project") {
  candidate <- file.path(project_dir, "Final Project")
  if (dir.exists(candidate)) project_dir <- normalizePath(candidate)
}

local_lib <- file.path(project_dir, "_r_libs")
.libPaths(c(local_lib, .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(openxlsx)
})

input_file <- file.path(project_dir, "DSA Group 10 - Sheet1.csv")
output_dir <- file.path(project_dir, "cleaned_data")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

data <- read_csv(input_file, show_col_types = FALSE) |>
  mutate(
    across(where(is.character), trimws),
    state = factor(state, levels = c("California", "Florida")),
    year = as.integer(year)
  ) |>
  arrange(state, year) |>
  mutate(state = as.character(state))

# ---------------------------------------------------------------------------
# Validation checks
# ---------------------------------------------------------------------------

nonnegative_variables <- intersect(
  c(
    "total_homeless", "sheltered_homeless", "unsheltered_homeless",
    "shelter_beds_per_10k", "psh_beds_per_10k",
    "state_homeless_funding_musd", "minimum_wage",
    "personal_income_per_capita", "median_household_income",
    "state_population", "median_rent", "median_home_price",
    "housing_units_per_capita", "new_housing_permits",
    "estimated_housing_units", "permits_per_1000_housing_units"
  ),
  names(data)
)

percentage_variables <- intersect(
  c(
    "poverty_rate", "labor_force_participation", "unemployment_rate",
    "substance_use_disorder_rate", "serious_mental_illness_rate",
    "uninsured_rate", "high_school_graduation_rate",
    "pct_age_18_24", "pct_age_65plus", "rent_as_pct_income",
    "rent_burden_share", "rental_vacancy_rate", "homeownership_rate",
    "unsheltered_share_pct"
  ),
  names(data)
)

binary_variables <- intersect(
  c(
    "medicaid_expansion", "pit_count_caution_flag"
  ),
  names(data)
)

validation_checks <- tibble(
  check = c(
    "32 rows",
    "Unique state-year key",
    "Expected states",
    "Years 2010-2025",
    "Homelessness components sum to total",
    "No infinite numeric values",
    "Selected count/dollar variables are nonnegative",
    "Selected percentage variables are between 0 and 100",
    "Selected binary variables contain only 0, 1, or NA",
    "Anticamping strictness contains only documented ordinal levels 0-3"
  ),
  passed = c(
    nrow(data) == 32,
    !anyDuplicated(data[c("state", "year")]),
    identical(sort(unique(data$state)), c("California", "Florida")),
    identical(sort(unique(data$year)), 2010:2025),
    all(
      data$total_homeless ==
        data$sheltered_homeless + data$unsheltered_homeless,
      na.rm = TRUE
    ),
    all(vapply(
      data[vapply(data, is.numeric, logical(1))],
      function(x) all(is.finite(x) | is.na(x)),
      logical(1)
    )),
    all(vapply(
      data[nonnegative_variables],
      function(x) all(x >= 0, na.rm = TRUE),
      logical(1)
    )),
    all(vapply(
      data[percentage_variables],
      function(x) all(x >= 0 & x <= 100, na.rm = TRUE),
      logical(1)
    )),
    all(vapply(
      data[binary_variables],
      function(x) all(x %in% c(0, 1) | is.na(x)),
      logical(1)
    )),
    all(
      data$anticamping_strictness %in% 0:3 |
        is.na(data$anticamping_strictness)
    )
  )
)

if (!all(validation_checks$passed)) {
  stop(
    "Cleaning stopped because validation failed: ",
    paste(validation_checks$check[!validation_checks$passed], collapse = "; ")
  )
}

# ---------------------------------------------------------------------------
# Broad cleaned panel
# ---------------------------------------------------------------------------

# The all-missing foreclosure field is removed from analytical data. It
# remains in the integrated source workbook as documentation of the gap.
clean_full <- data |>
  select(-foreclosure_rate) |>
  mutate(
    pit_observation_usable = year != 2021L,
    rent_cost_available = !is.na(median_rent),
    rent_income_measure_available = !is.na(rent_as_pct_income),
    rent_burden_measure_available = !is.na(rent_burden_share),
    eviction_measure_available = !is.na(eviction_filing_rate)
  )

# ---------------------------------------------------------------------------
# Complete, purpose-specific panels
# ---------------------------------------------------------------------------

# Candidate columns for a compact full-period model. This file contains no
# missing values, but the team should select a smaller theory-driven predictor
# set rather than fitting every candidate simultaneously.
core_panel <- clean_full |>
  filter(pit_observation_usable) |>
  select(
    state_year, state, year,
    homeless_rate_per_10k,
    real_median_home_price_2025_usd,
    rental_vacancy_rate,
    homeownership_rate,
    housing_units_per_capita,
    permits_per_1000_housing_units,
    total_beds_per_10k,
    real_personal_income_per_capita_2025_usd,
    unemployment_rate,
    real_minimum_wage_2025_usd
  ) |>
  drop_na()

rent_cost_panel <- clean_full |>
  filter(pit_observation_usable) |>
  select(
    state_year, state, year, homeless_rate_per_10k,
    median_rent, real_median_rent_2025_usd,
    rental_vacancy_rate, housing_units_per_capita
  ) |>
  drop_na()

# B25071 is kept separate from Eviction Lab's renter cost-burden share.
rent_income_panel <- clean_full |>
  filter(pit_observation_usable) |>
  select(
    state_year, state, year, homeless_rate_per_10k,
    rent_as_pct_income, rental_vacancy_rate
  ) |>
  drop_na()

rent_burden_panel <- clean_full |>
  filter(pit_observation_usable) |>
  select(
    state_year, state, year, homeless_rate_per_10k,
    rent_burden_share, rental_vacancy_rate
  ) |>
  drop_na()

eviction_panel <- clean_full |>
  filter(pit_observation_usable) |>
  select(
    state_year, state, year, homeless_rate_per_10k,
    eviction_filing_rate, rental_vacancy_rate,
    housing_units_per_capita, real_median_home_price_2025_usd,
    unemployment_rate
  ) |>
  drop_na()

stopifnot(
  !anyNA(core_panel),
  !anyNA(rent_cost_panel),
  !anyNA(rent_income_panel),
  !anyNA(rent_burden_panel),
  !anyNA(eviction_panel)
)

# ---------------------------------------------------------------------------
# Variable-level cleaning audit
# ---------------------------------------------------------------------------

treatment_for <- function(variable) {
  case_when(
    variable == "foreclosure_rate" ~
      "Drop from analysis; all values unavailable.",
    variable == "eviction_filing_rate" ~
      "Use only in the 2010-2018 eviction panel; no imputation.",
    variable == "rent_as_pct_income" ~
      "Use ACS B25071 only; do not combine with renter burden share.",
    variable == "rent_burden_share" ~
      "Use Eviction Lab 2010-2018 panel only; do not combine with B25071.",
    variable %in% c("median_rent", "real_median_rent_2025_usd") ~
      "Observed through 2024; exclude 2025 in rent-specific analysis.",
    variable %in% c(
      "unsheltered_share_pct", "beds_per_100_homeless",
      "funding_per_homeless_person"
    ) ~
      "Keep 2021 suppressed because the PIT denominator is disrupted.",
    variable == "homeless_rate_change_per_10k" ~
      "Keep 2010, 2021, and 2022 missing by design.",
    variable == "housing_supply_growth_rate" ~
      "Keep 2010 and 2020 missing by design; use a dedicated panel.",
    variable %in% c(
      "population_growth_rate_pct", "real_home_price_growth_pct"
    ) ~
      "Keep first year missing because no prior panel year is available.",
    TRUE ~
      "Preserve observed values; verify source and use complete cases as needed."
  )
}

cleaning_audit <- tibble(
  variable = names(data),
  type = vapply(data, function(x) class(x)[1], character(1)),
  available_rows = vapply(data, function(x) sum(!is.na(x)), integer(1)),
  missing_rows = vapply(data, function(x) sum(is.na(x)), integer(1)),
  unique_nonmissing = vapply(
    data,
    function(x) length(unique(x[!is.na(x)])),
    integer(1)
  ),
  minimum = vapply(
    data,
    function(x) if (is.numeric(x) && any(!is.na(x))) {
      as.character(min(x, na.rm = TRUE))
    } else {
      NA_character_
    },
    character(1)
  ),
  maximum = vapply(
    data,
    function(x) if (is.numeric(x) && any(!is.na(x))) {
      as.character(max(x, na.rm = TRUE))
    } else {
      NA_character_
    },
    character(1)
  )
) |>
  mutate(treatment = treatment_for(variable)) |>
  arrange(desc(missing_rows), variable)

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

write_csv(clean_full, file.path(output_dir, "analysis_panel_clean_full.csv"), na = "")
write_csv(core_panel, file.path(output_dir, "analysis_panel_core.csv"), na = "")
write_csv(rent_cost_panel, file.path(output_dir, "analysis_panel_rent_cost.csv"), na = "")
write_csv(rent_income_panel, file.path(output_dir, "analysis_panel_rent_income.csv"), na = "")
write_csv(rent_burden_panel, file.path(output_dir, "analysis_panel_rent_burden.csv"), na = "")
write_csv(eviction_panel, file.path(output_dir, "analysis_panel_eviction_2010_2018.csv"), na = "")
write_csv(cleaning_audit, file.path(output_dir, "cleaning_audit.csv"), na = "")
write_csv(validation_checks, file.path(output_dir, "validation_checks.csv"), na = "")

read_me <- tibble(
  item = c(
    "Broad cleaned panel",
    "Core panel",
    "Rent-cost panel",
    "Rent-to-income panel",
    "Rent-burden panel",
    "Eviction panel",
    "Missing-value policy",
    "Preprocessing warning"
  ),
  description = c(
    "All source variables except all-missing foreclosure_rate; structural NA values remain and availability flags are added.",
    "Thirty non-2021 state-years with complete candidate variables. Do not fit all candidates simultaneously with this sample size.",
    "Non-2021 observations with median rent and related housing measures available.",
    "Non-2021 observations using ACS B25071 median rent as a percentage of income.",
    "2010-2018 observations using the separate Eviction Lab renter cost-burden share.",
    "2010-2018 observations with complete modeled eviction filing rates.",
    "No statistical imputation, zero filling, global mean filling, or outcome-based filling was used.",
    "Any learned scaling or future imputation must be fitted on training years only."
  )
)

workbook_file <- file.path(output_dir, "cleaned_analysis_datasets.xlsx")
wb <- createWorkbook(creator = "DSA Group 10 reproducible cleaning pipeline")
sheet_data <- list(
  "Read Me" = read_me,
  "Clean Full" = clean_full,
  "Core Panel" = core_panel,
  "Rent Cost" = rent_cost_panel,
  "Rent Income" = rent_income_panel,
  "Rent Burden" = rent_burden_panel,
  "Eviction 2010-2018" = eviction_panel,
  "Cleaning Audit" = cleaning_audit,
  "Validation Checks" = validation_checks
)

header_style <- createStyle(
  textDecoration = "bold",
  fgFill = "#D9EAD3",
  border = "Bottom",
  wrapText = TRUE
)

for (sheet_name in names(sheet_data)) {
  addWorksheet(wb, sheet_name)
  writeData(wb, sheet_name, sheet_data[[sheet_name]])
  freezePane(wb, sheet_name, firstRow = TRUE)
  addFilter(
    wb, sheet_name,
    row = 1,
    cols = seq_len(ncol(sheet_data[[sheet_name]]))
  )
  addStyle(
    wb, sheet_name, header_style,
    rows = 1,
    cols = seq_len(ncol(sheet_data[[sheet_name]])),
    gridExpand = TRUE
  )
  setColWidths(
    wb, sheet_name,
    cols = seq_len(ncol(sheet_data[[sheet_name]])),
    widths = "auto"
  )
}

saveWorkbook(wb, workbook_file, overwrite = TRUE)

cat(
  "Created cleaned data products in", normalizePath(output_dir), "\n",
  "Broad panel:", nrow(clean_full), "rows x", ncol(clean_full), "columns\n",
  "Core complete panel:", nrow(core_panel), "rows x", ncol(core_panel), "columns\n",
  "Eviction panel:", nrow(eviction_panel), "rows\n",
  "Rent-cost panel:", nrow(rent_cost_panel), "rows\n",
  "Rent-to-income panel:", nrow(rent_income_panel), "rows\n",
  "Rent-burden panel:", nrow(rent_burden_panel), "rows\n"
)
