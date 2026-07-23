#!/usr/bin/env Rscript

# Rebuild the team state-year spreadsheet with corrected housing data,
# transparent derived variables, inflation-adjusted measures, categories,
# a data dictionary, and missingness documentation.

options(timeout = 300)

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

team_file <- file.path(project_dir, "DSA Group 10 - Sheet1.csv")
backup_file <- file.path(project_dir, "raw_data", "DSA_Group_10_Sheet1_original.csv")
housing_file <- file.path(project_dir, "housing_metrics_CA_FL_2010_2025.csv")
cpi_file <- file.path(project_dir, "raw_data", "fred_CPIAUCSL.csv")

stopifnot(file.exists(housing_file), file.exists(cpi_file))

if (!file.exists(backup_file)) {
  stopifnot(file.exists(team_file))
  file.copy(team_file, backup_file, overwrite = FALSE)
}

# Always rebuild from the preserved original so rerunning the script is stable.
base_file <- backup_file

clean_numeric <- function(x) {
  cleaned <- gsub("[^0-9.-]", "", x)
  cleaned[cleaned == ""] <- NA_character_
  as.numeric(cleaned)
}

raw_team <- read_csv(
  base_file,
  col_types = cols(.default = col_character()),
  name_repair = "minimal",
  show_col_types = FALSE
)
names(raw_team)[1] <- "state_year"
names(raw_team)[names(raw_team) == "avrg_in-state_tution"] <- "avg_in_state_tuition"

team <- raw_team
numeric_columns <- setdiff(names(team), "state_year")
team[numeric_columns] <- lapply(team[numeric_columns], clean_numeric)
team <- team |>
  mutate(
    state = sub(" [0-9]{4}$", "", state_year),
    year = as.integer(sub("^.* ([0-9]{4})$", "\\1", state_year))
  ) |>
  relocate(state_year, state, year)

stopifnot(
  nrow(team) == 32,
  !anyDuplicated(team[c("state", "year")]),
  all(sort(unique(team$state)) == c("California", "Florida")),
  all(range(team$year) == c(2010, 2025))
)

# Replace the stale housing fields with the validated housing panel.
housing <- read_csv(housing_file, show_col_types = FALSE)
housing_fields <- c(
  "median_rent",
  "median_home_price",
  "rent_as_pct_income",
  "rent_burden_share",
  "rental_vacancy_rate",
  "homeownership_rate",
  "housing_units_per_capita",
  "new_housing_permits",
  "housing_supply_growth_rate",
  "eviction_filing_rate",
  "foreclosure_rate"
)

housing_update <- housing |>
  select(state, year, all_of(housing_fields))

team <- team |>
  select(-any_of(housing_fields)) |>
  left_join(housing_update, by = c("state", "year"))

# CPI-U annual averages. Monetary series are converted to constant 2025 dollars.
cpi_annual <- read_csv(cpi_file, show_col_types = FALSE) |>
  transmute(
    date = as.Date(observation_date),
    year = as.integer(format(date, "%Y")),
    cpi_u = as.numeric(CPIAUCSL)
  ) |>
  filter(year %in% 2010:2025) |>
  group_by(year) |>
  summarise(cpi_u = mean(cpi_u, na.rm = TRUE), .groups = "drop")

cpi_2025 <- cpi_annual$cpi_u[cpi_annual$year == 2025]
stopifnot(length(cpi_2025) == 1, !is.na(cpi_2025))

land_area_sq_miles <- c(
  "California" = 155858.33,
  "Florida" = 53652.17
)

team <- team |>
  left_join(cpi_annual, by = "year") |>
  arrange(state, year) |>
  group_by(state) |>
  mutate(
    # Correct previously incomplete demographic series from existing population.
    population_growth_rate_pct =
      100 * (state_population / lag(state_population) - 1),
    population_density =
      state_population / unname(land_area_sq_miles[state]),

    # Outcome and data-quality variables.
    unsheltered_share_pct = if_else(
      year == 2021L,
      NA_real_,
      100 * unsheltered_homeless / total_homeless
    ),
    homeless_rate_change_per_10k = if_else(
      year %in% c(2021L, 2022L),
      NA_real_,
      homeless_rate_per_10k - lag(homeless_rate_per_10k)
    ),
    pit_count_caution_flag = as.integer(year == 2021),

    # Service-capacity variables on interpretable denominators.
    total_beds_per_10k =
      shelter_beds_per_10k + psh_beds_per_10k,
    beds_per_100_homeless = if_else(
      year == 2021L,
      NA_real_,
      100 * total_beds_per_10k / homeless_rate_per_10k
    ),
    funding_per_homeless_person = if_else(
      year == 2021L,
      NA_real_,
      1e6 * state_homeless_funding_musd / total_homeless
    ),

    # Housing supply and affordability variables.
    estimated_housing_units =
      housing_units_per_capita * state_population,
    permits_per_1000_housing_units =
      1000 * new_housing_permits / estimated_housing_units,
    home_price_to_income_ratio =
      median_home_price / median_household_income,

    # Constant-dollar variables. Do not use nominal and real versions together.
    real_median_rent_2025_usd =
      median_rent * cpi_2025 / cpi_u,
    real_median_home_price_2025_usd =
      median_home_price * cpi_2025 / cpi_u,
    real_personal_income_per_capita_2025_usd =
      personal_income_per_capita * cpi_2025 / cpi_u,
    real_median_household_income_2025_usd =
      median_household_income * cpi_2025 / cpi_u,
    real_minimum_wage_2025_usd =
      minimum_wage * cpi_2025 / cpi_u,
    real_home_price_growth_pct =
      100 * (
        real_median_home_price_2025_usd /
          lag(real_median_home_price_2025_usd) - 1
      )
  ) |>
  ungroup()

# Keep a logical order: identifiers, original/validated variables, new variables.
new_variables <- c(
  "cpi_u",
  "unsheltered_share_pct",
  "homeless_rate_change_per_10k",
  "pit_count_caution_flag",
  "total_beds_per_10k",
  "beds_per_100_homeless",
  "funding_per_homeless_person",
  "estimated_housing_units",
  "permits_per_1000_housing_units",
  "home_price_to_income_ratio",
  "real_median_rent_2025_usd",
  "real_median_home_price_2025_usd",
  "real_personal_income_per_capita_2025_usd",
  "real_median_household_income_2025_usd",
  "real_minimum_wage_2025_usd",
  "real_home_price_growth_pct"
)
team <- team |>
  relocate(all_of(new_variables), .after = last_col())

stopifnot(
  nrow(team) == 32,
  !anyDuplicated(team[c("state", "year")]),
  sum(is.na(team$housing_units_per_capita)) == 0,
  sum(is.na(team$population_density)) == 0,
  sum(is.na(team$population_growth_rate_pct)) == 2,
  all(team$total_homeless ==
        team$sheltered_homeless + team$unsheltered_homeless)
)

write_csv(team, team_file, na = "")

# ---------------------------------------------------------------------------
# Variable dictionary and category assignment
# ---------------------------------------------------------------------------

category_map <- c(
  state_year = "Identifier",
  state = "Identifier",
  year = "Identifier",
  total_homeless = "Homelessness outcome",
  sheltered_homeless = "Homelessness outcome",
  unsheltered_homeless = "Homelessness outcome",
  homeless_rate_per_10k = "Homelessness outcome",
  unsheltered_share_pct = "Homelessness outcome",
  homeless_rate_change_per_10k = "Homelessness outcome",
  shelter_beds_per_10k = "Service capacity and funding",
  psh_beds_per_10k = "Service capacity and funding",
  total_beds_per_10k = "Service capacity and funding",
  beds_per_100_homeless = "Service capacity and funding",
  state_homeless_funding_musd = "Service capacity and funding",
  state_homeless_funding_per_capita = "Service capacity and funding",
  funding_per_homeless_person = "Service capacity and funding",
  anticamping_strictness = "Policy and safety net",
  medicaid_expansion = "Policy and safety net",
  tanf_max_benefit_3person = "Policy and safety net",
  ssi_state_supplement = "Policy and safety net",
  minimum_wage = "Policy and safety net",
  real_minimum_wage_2025_usd = "Policy and safety net",
  personal_income_per_capita = "Economy",
  median_household_income = "Economy",
  poverty_rate = "Economy",
  labor_force_participation = "Economy",
  unemployment_rate = "Economy",
  real_personal_income_per_capita_2025_usd = "Economy",
  real_median_household_income_2025_usd = "Economy",
  cpi_u = "Economy",
  substance_use_disorder_rate = "Health and social conditions",
  serious_mental_illness_rate = "Health and social conditions",
  uninsured_rate = "Health and social conditions",
  high_school_graduation_rate = "Education",
  average_student_debt_per_borrower = "Education",
  avg_in_state_tuition = "Education",
  state_population = "Demographics",
  population_density = "Demographics",
  population_growth_rate_pct = "Demographics",
  pct_age_18_24 = "Demographics",
  pct_age_65plus = "Demographics",
  avg_household_size = "Demographics",
  avg_temp_f = "Climate",
  precip_in = "Climate",
  cooling_degree_days = "Climate",
  median_rent = "Housing cost and supply",
  median_home_price = "Housing cost and supply",
  rent_as_pct_income = "Housing cost and supply",
  rent_burden_share = "Housing instability",
  rental_vacancy_rate = "Housing cost and supply",
  homeownership_rate = "Housing cost and supply",
  housing_units_per_capita = "Housing cost and supply",
  estimated_housing_units = "Housing cost and supply",
  new_housing_permits = "Housing cost and supply",
  permits_per_1000_housing_units = "Housing cost and supply",
  housing_supply_growth_rate = "Housing cost and supply",
  eviction_filing_rate = "Housing instability",
  foreclosure_rate = "Housing instability",
  home_price_to_income_ratio = "Housing affordability",
  real_median_rent_2025_usd = "Housing affordability",
  real_median_home_price_2025_usd = "Housing affordability",
  real_home_price_growth_pct = "Housing affordability",
  pit_count_caution_flag = "Data quality"
)

definition_map <- c(
  state_year = "State and calendar year merge key.",
  state = "State name.",
  year = "Calendar year.",
  total_homeless = "Total PIT homelessness count.",
  sheltered_homeless = "Sheltered PIT homelessness count.",
  unsheltered_homeless = "Unsheltered PIT homelessness count.",
  homeless_rate_per_10k = "People experiencing homelessness per 10,000 residents.",
  unsheltered_share_pct = "Unsheltered count divided by total homelessness count, percent; 2021 is suppressed.",
  homeless_rate_change_per_10k = "Year-over-year change in homelessness rate within state; 2021 and 2022 are suppressed because either endpoint involves the disrupted 2021 count.",
  pit_count_caution_flag = "Equals 1 for 2021, when COVID disrupted PIT counting; use as a warning, not a predictor.",
  shelter_beds_per_10k = "Shelter beds per 10,000 residents.",
  psh_beds_per_10k = "Permanent supportive housing beds per 10,000 residents.",
  total_beds_per_10k = "Shelter plus PSH beds per 10,000 residents.",
  beds_per_100_homeless = "Total beds per 100 people counted as homeless; 2021 is suppressed because the PIT denominator is disrupted.",
  state_homeless_funding_musd = "Recorded state homelessness funding, millions of nominal dollars.",
  state_homeless_funding_per_capita = "Recorded state homelessness funding per resident.",
  funding_per_homeless_person = "Recorded state funding divided by total homelessness count; 2021 is suppressed because the PIT denominator is disrupted.",
  median_rent = "Median gross rent, nominal dollars per month.",
  median_home_price = "Annual median of Zillow monthly state median sale price.",
  rent_as_pct_income = "Median gross rent as a percentage of household income.",
  rent_burden_share = "Share of renter households meeting the Eviction Lab rent-burden definition.",
  rental_vacancy_rate = "Annual rental vacancy rate, percent.",
  homeownership_rate = "Annual homeownership rate, percent.",
  housing_units_per_capita = "Estimated housing units divided by resident population.",
  estimated_housing_units = "Housing units per capita multiplied by state population.",
  new_housing_permits = "Private housing units authorized by building permits.",
  permits_per_1000_housing_units = "Authorized housing units per 1,000 estimated housing units.",
  housing_supply_growth_rate = "Within-vintage annual percent change in housing units.",
  eviction_filing_rate = "Modeled eviction filings per 100 renter homes.",
  foreclosure_rate = "Reserved field; no comparable open 2010–2025 state series has been verified.",
  home_price_to_income_ratio = "Median sale price divided by median household income.",
  cpi_u = "Annual average U.S. CPI-U index.",
  real_median_rent_2025_usd = "Median rent expressed in constant 2025 dollars.",
  real_median_home_price_2025_usd = "Median home sale price expressed in constant 2025 dollars.",
  real_personal_income_per_capita_2025_usd = "Personal income per capita in constant 2025 dollars.",
  real_median_household_income_2025_usd = "Median household income in constant 2025 dollars.",
  real_minimum_wage_2025_usd = "State minimum wage in constant 2025 dollars.",
  real_home_price_growth_pct = "Year-over-year growth in inflation-adjusted median home price.",
  population_density = "State population per square mile of Census land area.",
  population_growth_rate_pct = "Year-over-year population growth within state, percent."
)

housing_documented <- c(
  housing_fields,
  "real_median_rent_2025_usd",
  "real_median_home_price_2025_usd",
  "real_home_price_growth_pct"
)
derived_variables <- c(
  "unsheltered_share_pct", "homeless_rate_change_per_10k",
  "pit_count_caution_flag", "total_beds_per_10k",
  "beds_per_100_homeless", "funding_per_homeless_person",
  "estimated_housing_units", "permits_per_1000_housing_units",
  "home_price_to_income_ratio", "population_density",
  "population_growth_rate_pct", "real_median_rent_2025_usd",
  "real_median_home_price_2025_usd",
  "real_personal_income_per_capita_2025_usd",
  "real_median_household_income_2025_usd",
  "real_minimum_wage_2025_usd", "real_home_price_growth_pct"
)

dictionary <- tibble(variable = names(team)) |>
  mutate(
    category = unname(category_map[variable]),
    category = if_else(is.na(category), "Uncategorized", category),
    definition = unname(definition_map[variable]),
    definition = if_else(
      is.na(definition),
      tools::toTitleCase(gsub("_", " ", variable)),
      definition
    ),
    source_or_derivation = case_when(
      variable == "cpi_u" ~
        "U.S. BLS CPI-U via FRED series CPIAUCSL; annual mean.",
      variable %in% housing_fields ~
        "Validated housing panel; see DATA_SOURCES_AND_ASSUMPTIONS.md.",
      variable %in% derived_variables ~
        paste(
          "Derived in update_team_dataset.R from named component variables;",
          "consult the component source statuses before analysis."
        ),
      variable %in% c("state_year", "state", "year") ~
        "Team panel identifiers.",
      TRUE ~
        "Original team spreadsheet; original source is not documented in this folder."
    ),
    source_status = case_when(
      variable %in% c("state_year", "state", "year", "cpi_u") ~ "documented",
      variable %in% housing_documented ~ "documented",
      variable %in% derived_variables ~
        "derivation documented; verify component sources",
      TRUE ~ "source verification needed"
    ),
    available_rows = vapply(
      variable,
      function(v) sum(!is.na(team[[v]])),
      integer(1)
    ),
    total_rows = nrow(team),
    missing_rows = total_rows - available_rows,
    modeling_note = case_when(
      category == "Identifier" ~ "Identifier; do not treat year as an ordinary independent row.",
      variable == "pit_count_caution_flag" ~ "Data-quality flag; use to exclude or annotate 2021.",
      variable %in% c("total_homeless", "sheltered_homeless",
                      "unsheltered_homeless", "unsheltered_share_pct") ~
        "Outcome or outcome component; do not use to predict homeless_rate_per_10k.",
      grepl("^real_", variable) ~
        "Use instead of, not alongside, the corresponding nominal variable.",
      variable %in% c("state_homeless_funding_musd",
                      "state_homeless_funding_per_capita",
                      "funding_per_homeless_person") ~
        "Same underlying funding measure on different denominators; choose one.",
      variable == "eviction_filing_rate" ~
        "Coverage ends in 2018; do not impute post-2018 values from the outcome.",
      TRUE ~ "Check timing, source status, and missingness before modeling."
    )
  )

missingness <- dictionary |>
  select(category, variable, available_rows, missing_rows, total_rows) |>
  arrange(desc(missing_rows), category, variable)

source_notes <- tibble(
  topic = c(
    "Corrected housing data",
    "Housing source producers",
    "CPI and real-dollar conversions",
    "Original team variables",
    "Derived-variable provenance",
    "Missing values",
    "2021 PIT counts",
    "Cleaning workflow",
    "Modeling"
  ),
  note = c(
    "Housing fields are replaced from housing_metrics_CA_FL_2010_2025.csv.",
    paste(
      "Housing sources are Eviction Lab; Census ACS, Housing Vacancy Survey,",
      "Population Estimates, and Building Permits Survey; and Zillow Research.",
      "See DATA_SOURCES_AND_ASSUMPTIONS.md for definitions and endpoints."
    ),
    "CPI-U is the annual mean of FRED CPIAUCSL. Real values use the 2025 annual mean as the base.",
    "Many original non-housing variables lack source documentation in this folder. The dictionary flags them for verification.",
    "A documented formula does not verify an undocumented input. Check each component source before using a derived variable.",
    "Blank means unavailable, not zero. No statistical imputation is performed.",
    "COVID disrupted the 2021 PIT count. Use pit_count_caution_flag to annotate or exclude that year.",
    paste(
      "Preserve raw files; standardize IDs, types, units, and NA values;",
      "validate domains and identities; investigate outliers against sources;",
      "and fit learned preprocessing on training years only."
    ),
    "Use time-based validation. Avoid outcome components, redundant denominators, and nominal/real duplicates in the same model."
  )
)

# ---------------------------------------------------------------------------
# Excel workbook
# ---------------------------------------------------------------------------

workbook_file <- file.path(project_dir, "DSA_Group_10_updated.xlsx")
wb <- createWorkbook(creator = "DSA Group 10 reproducible data pipeline")
addWorksheet(wb, "Data")
addWorksheet(wb, "Variable Dictionary")
addWorksheet(wb, "Missingness")
addWorksheet(wb, "Source Notes")

writeData(wb, "Data", team)
writeData(wb, "Variable Dictionary", dictionary)
writeData(wb, "Missingness", missingness)
writeData(wb, "Source Notes", source_notes)

category_colors <- c(
  "Identifier" = "#D9EAD3",
  "Homelessness outcome" = "#F4CCCC",
  "Service capacity and funding" = "#FCE5CD",
  "Policy and safety net" = "#FFF2CC",
  "Economy" = "#D9EAF7",
  "Health and social conditions" = "#EADCF8",
  "Education" = "#D0E0E3",
  "Demographics" = "#CFE2F3",
  "Climate" = "#D9EAD3",
  "Housing cost and supply" = "#F9CB9C",
  "Housing instability" = "#E6B8AF",
  "Housing affordability" = "#F6B26B",
  "Data quality" = "#D9D9D9",
  "Uncategorized" = "#EEEEEE"
)

for (col_idx in seq_along(names(team))) {
  variable <- names(team)[col_idx]
  category <- dictionary$category[dictionary$variable == variable]
  style <- createStyle(
    textDecoration = "bold",
    fgFill = unname(category_colors[category]),
    halign = "center",
    valign = "center",
    wrapText = TRUE,
    border = "Bottom"
  )
  addStyle(wb, "Data", style, rows = 1, cols = col_idx)
  missing_rows <- which(is.na(team[[variable]])) + 1
  if (length(missing_rows)) {
    addStyle(
      wb, "Data",
      createStyle(fgFill = "#FFF2CC", fontColour = "#7F6000"),
      rows = missing_rows, cols = col_idx
    )
  }
}

header_style <- createStyle(
  textDecoration = "bold", fgFill = "#D9EAD3",
  halign = "center", valign = "center", wrapText = TRUE,
  border = "Bottom"
)
for (sheet in c("Variable Dictionary", "Missingness", "Source Notes")) {
  sheet_cols <- switch(
    sheet,
    "Variable Dictionary" = ncol(dictionary),
    "Missingness" = ncol(missingness),
    "Source Notes" = ncol(source_notes)
  )
  addStyle(wb, sheet, header_style, rows = 1, cols = 1:sheet_cols,
           gridExpand = TRUE)
  freezePane(wb, sheet, firstRow = TRUE)
  setColWidths(wb, sheet, cols = 1:sheet_cols, widths = "auto")
}

freezePane(wb, "Data", firstRow = TRUE, firstCol = TRUE)
addFilter(wb, "Data", rows = 1, cols = 1:ncol(team))
setColWidths(wb, "Data", cols = 1, widths = 20)
setColWidths(wb, "Data", cols = 2, widths = 12)
setColWidths(wb, "Data", cols = 3, widths = 8)
setColWidths(wb, "Data", cols = 4:ncol(team), widths = 19)
setRowHeights(wb, "Data", rows = 1, heights = 44)
setColWidths(wb, "Variable Dictionary", cols = c(3, 4, 5, 9),
             widths = c(52, 58, 24, 58))
setColWidths(wb, "Source Notes", cols = 2, widths = 100)

saveWorkbook(wb, workbook_file, overwrite = TRUE)

cat(
  "Updated team CSV and workbook.\n",
  "Rows:", nrow(team), "\n",
  "Variables:", ncol(team), "\n",
  "New variables:", length(new_variables), "\n",
  "Workbook:", workbook_file, "\n"
)
