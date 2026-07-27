options(stringsAsFactors = FALSE)
options(openxlsx.maxWidth = 32)

project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) {
  .libPaths(c(local_r_lib, .libPaths()))
}

required_packages <- c("dplyr", "readxl", "sf", "jsonlite", "openxlsx")
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
library(sf)
library(jsonlite)
library(openxlsx)

output_dir <- file.path(project_root, "coc_analysis")
cache_dir <- file.path(output_dir, "cache")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

pit_xlsb <- file.path(
  project_root, "raw_data", "2007-2025-PIT-Counts-by-CoC.xlsb"
)
coc_boundaries_file <- file.path(
  project_root, "raw_data", "hud_coc_boundaries_FY2024_CA_FL.geojson"
)
tract_zip_files <- file.path(
  project_root,
  "raw_data",
  c("census_tl_2024_06_tract.zip", "census_tl_2024_12_tract.zip")
)
tract_population_files <- file.path(
  project_root,
  "raw_data",
  c(
    "census_reporter_acs5_latest_CA_tract_population.json",
    "census_reporter_acs5_latest_FL_tract_population.json"
  )
)
county_panel_file <- file.path(
  project_root,
  "county_raw_panel",
  "county_year_raw_panel_CA_FL_2010_2025.csv"
)
state_panel_file <- file.path(project_root, "DSA Group 10 - Sheet1.csv")

required_files <- c(
  pit_xlsb,
  coc_boundaries_file,
  tract_zip_files,
  tract_population_files,
  county_panel_file,
  state_panel_file
)
if (any(!file.exists(required_files))) {
  stop(
    "Required input files are missing:\n",
    paste(required_files[!file.exists(required_files)], collapse = "\n")
  )
}

selected_pit_cache <- file.path(cache_dir, "hud_pit_coc_selected_2010_2025.csv")

value_or_na <- function(data, variable) {
  if (variable %in% names(data)) {
    suppressWarnings(as.numeric(data[[variable]]))
  } else {
    rep(NA_real_, nrow(data))
  }
}

read_pit_sheet <- function(workbook, year) {
  raw <- read_excel(
    workbook,
    sheet = as.character(year),
    .name_repair = "unique",
    guess_max = 1000
  )

  data.frame(
    year = as.integer(year),
    coc_number = as.character(raw[["CoC Number"]]),
    coc_name = as.character(raw[["CoC Name"]]),
    count_type = as.character(raw[["Count Types"]]),
    total_homeless = value_or_na(raw, "Overall Homeless"),
    sheltered_homeless = value_or_na(raw, "Sheltered Total Homeless"),
    unsheltered_homeless = value_or_na(raw, "Unsheltered Homeless"),
    homeless_individuals = value_or_na(raw, "Overall Homeless Individuals"),
    homeless_people_in_families = value_or_na(
      raw, "Overall Homeless People in Families"
    ),
    chronically_homeless_individuals = value_or_na(
      raw, "Overall Chronically Homeless Individuals"
    ),
    homeless_veterans = value_or_na(raw, "Overall Homeless Veterans"),
    homeless_unaccompanied_youth_under_25 = value_or_na(
      raw, "Overall Homeless Unaccompanied Youth (Under 25)"
    ),
    stringsAsFactors = FALSE
  ) |>
    filter(grepl("^(CA|FL)-", coc_number))
}

extract_selected_pit <- function() {
  if (file.exists(selected_pit_cache)) {
    return(read.csv(selected_pit_cache, check.names = FALSE))
  }

  soffice <- Sys.which("soffice")
  if (!nzchar(soffice)) {
    stop(
      "LibreOffice (soffice) is required once to convert HUD's XLSB file. ",
      "The selected CSV cache is not present."
    )
  }

  conversion_dir <- tempfile("hud_pit_xlsx_")
  profile_dir <- tempfile("libreoffice_profile_")
  dir.create(conversion_dir)
  dir.create(profile_dir)
  on.exit(unlink(c(conversion_dir, profile_dir), recursive = TRUE), add = TRUE)

  profile_url <- paste0("file://", normalizePath(profile_dir, mustWork = TRUE))
  conversion_output <- system2(
    soffice,
    args = c(
      paste0("-env:UserInstallation=", profile_url),
      "--headless",
      "--convert-to", "xlsx",
      "--outdir", shQuote(conversion_dir),
      shQuote(pit_xlsb)
    ),
    stdout = TRUE,
    stderr = TRUE
  )

  converted_workbook <- file.path(
    conversion_dir, "2007-2025-PIT-Counts-by-CoC.xlsx"
  )
  if (!file.exists(converted_workbook)) {
    stop(
      "HUD XLSB conversion failed. LibreOffice output:\n",
      paste(conversion_output, collapse = "\n")
    )
  }

  selected <- bind_rows(lapply(2010:2025, function(y) {
    read_pit_sheet(converted_workbook, y)
  }))
  write.csv(selected, selected_pit_cache, row.names = FALSE, na = "")
  selected
}

pit <- extract_selected_pit() |>
  mutate(
    state_abbr = substr(coc_number, 1, 2),
    state = if_else(state_abbr == "CA", "California", "Florida"),
    coc_year = paste(coc_number, year, sep = " | "),
    pit_count_caution_flag = as.integer(year == 2021),
    unsheltered_share_pct = if_else(
      year == 2021 | is.na(total_homeless) | total_homeless <= 0,
      NA_real_,
      100 * unsheltered_homeless / total_homeless
    )
  ) |>
  select(
    coc_year, state, state_abbr, year, coc_number, coc_name, count_type,
    total_homeless, sheltered_homeless, unsheltered_homeless,
    unsheltered_share_pct, homeless_individuals,
    homeless_people_in_families, chronically_homeless_individuals,
    homeless_veterans, homeless_unaccompanied_youth_under_25,
    pit_count_caution_flag
  ) |>
  arrange(state, coc_number, year)

read_tract_population <- function(path) {
  parsed <- fromJSON(path, simplifyVector = FALSE)
  geography_ids <- names(parsed$data)
  data.frame(
    tract_geoid = sub("^14000US", "", geography_ids),
    tract_population = vapply(
      parsed$data,
      function(record) {
        as.numeric(record$B01003$estimate$B01003001)
      },
      numeric(1)
    ),
    stringsAsFactors = FALSE
  )
}

tract_dir <- tempfile("tract_shapes_")
dir.create(tract_dir)
on.exit(unlink(tract_dir, recursive = TRUE), add = TRUE)
invisible(lapply(tract_zip_files, unzip, exdir = tract_dir))

tract_shape_files <- list.files(
  tract_dir, pattern = "\\.shp$", full.names = TRUE
)
tracts <- bind_rows(lapply(tract_shape_files, function(path) {
  st_read(path, quiet = TRUE) |>
    select(STATEFP, COUNTYFP, TRACTCE, GEOID, NAME)
}))
names(tracts)[names(tracts) == "GEOID"] <- "tract_geoid"

tract_population <- bind_rows(lapply(
  tract_population_files, read_tract_population
))
tracts <- tracts |>
  left_join(tract_population, by = "tract_geoid")

if (anyNA(tracts$tract_population)) {
  stop("Every tract must have a matched ACS 2024 five-year population.")
}

coc_boundaries <- st_read(coc_boundaries_file, quiet = TRUE) |>
  st_make_valid() |>
  group_by(COCNUM, COCNAME, ST_1) |>
  summarise(.groups = "drop") |>
  st_transform(5070)

tract_points <- tracts |>
  st_transform(5070) |>
  st_point_on_surface()

tract_assignment <- st_join(
  tract_points,
  coc_boundaries,
  join = st_within,
  left = TRUE
)
tract_assignment$nearest_boundary_fallback_flag <- as.integer(
  is.na(tract_assignment$COCNUM)
)
tract_assignment$nearest_boundary_distance_km <- 0

unassigned_rows <- which(is.na(tract_assignment$COCNUM))
if (length(unassigned_rows) > 0) {
  for (state_abbr in c("CA", "FL")) {
    state_fips <- if (state_abbr == "CA") "06" else "12"
    row_index <- unassigned_rows[
      tract_assignment$STATEFP[unassigned_rows] == state_fips
    ]
    coc_index <- which(coc_boundaries$ST_1 == state_abbr)
    nearest_local <- st_nearest_feature(
      tract_assignment[row_index, ],
      coc_boundaries[coc_index, ]
    )
    nearest_global <- coc_index[nearest_local]
    tract_assignment$COCNUM[row_index] <-
      coc_boundaries$COCNUM[nearest_global]
    tract_assignment$COCNAME[row_index] <-
      coc_boundaries$COCNAME[nearest_global]
    tract_assignment$ST_1[row_index] <-
      coc_boundaries$ST_1[nearest_global]
    tract_assignment$nearest_boundary_distance_km[row_index] <-
      as.numeric(st_distance(
        tract_assignment[row_index, ],
        coc_boundaries[nearest_global, ],
        by_element = TRUE
      )) / 1000
  }
}

county_lookup <- read.csv(county_panel_file, check.names = FALSE) |>
  transmute(
    county_fips = sprintf("%05d", as.integer(fips)),
    county_name,
    state
  ) |>
  distinct()

county_coc_crosswalk <- tract_assignment |>
  st_drop_geometry() |>
  transmute(
    county_fips = paste0(STATEFP, COUNTYFP),
    coc_number = COCNUM,
    coc_name = COCNAME,
    state_abbr = ST_1,
    tract_population,
    nearest_boundary_fallback_flag,
    nearest_boundary_distance_km
  ) |>
  group_by(county_fips, coc_number, coc_name, state_abbr) |>
  summarise(
    allocated_tract_population_2024 = sum(tract_population),
    assigned_tract_count = n(),
    nearest_boundary_fallback_tract_count =
      sum(nearest_boundary_fallback_flag),
    max_nearest_boundary_distance_km =
      max(nearest_boundary_distance_km),
    .groups = "drop"
  ) |>
  group_by(county_fips) |>
  mutate(
    county_tract_population_2024 = sum(allocated_tract_population_2024),
    county_population_share =
      allocated_tract_population_2024 / county_tract_population_2024,
    meaningful_coc_count = sum(county_population_share >= 0.01),
    split_county_flag = as.integer(meaningful_coc_count > 1)
  ) |>
  ungroup() |>
  left_join(county_lookup, by = "county_fips") |>
  select(
    state, state_abbr, county_fips, county_name, coc_number, coc_name,
    allocated_tract_population_2024, county_tract_population_2024,
    county_population_share, assigned_tract_count,
    nearest_boundary_fallback_tract_count,
    max_nearest_boundary_distance_km, split_county_flag
  ) |>
  arrange(state, county_fips, desc(county_population_share))

county_panel <- read.csv(county_panel_file, check.names = FALSE) |>
  mutate(county_fips = sprintf("%05d", as.integer(fips)))

# Keep the CoC output schema stable when an optional county series is
# temporarily absent from a newer county-panel build. Missing remains missing;
# no values are imputed or replaced with zero.
optional_county_variables <- c(
  "median_home_sale_price_annual_avg_usd"
)
for (variable in setdiff(optional_county_variables, names(county_panel))) {
  county_panel[[variable]] <- NA_real_
}

identifier_columns <- c(
  "state_year_county", "data_status_note", "state_fips", "county_fips",
  "fips", "state", "county_name", "year"
)
candidate_variables <- setdiff(
  names(county_panel),
  c(identifier_columns, "land_area_sq_miles")
)

total_variables <- c(
  "population", "population_change", "births", "deaths", "natural_change",
  "international_migration", "domestic_migration", "net_migration",
  "group_quarters_population", "housing_units",
  "permits_one_unit_units", "permits_two_unit_units",
  "permits_three_four_unit_units", "permits_five_plus_unit_units",
  "permits_total_units_authorized", "permits_total_value_authorized",
  "permits_total_reported_units", "poverty_all_estimate",
  "poverty_all_ci_low", "poverty_all_ci_high", "poverty_child_estimate",
  "poverty_child_ci_low", "poverty_child_ci_high",
  "poverty_age_5_17_estimate", "civilian_labor_force", "employed_people",
  "unemployed_people", "bea_personal_income_thousands_usd",
  "bea_population", "bea_real_gdp_thousands_2017_usd",
  "bea_current_gdp_thousands_usd", "eviction_renting_households",
  "eviction_filings_estimate", "eviction_filings_ci_95_low",
  "eviction_filings_ci_95_high",
  "eviction_households_threatened_estimate",
  "eviction_households_threatened_ci_95_low",
  "eviction_households_threatened_ci_95_high"
)
total_variables <- intersect(total_variables, candidate_variables)
average_variables <- setdiff(candidate_variables, total_variables)

county_allocated <- county_panel |>
  inner_join(
    county_coc_crosswalk |>
      select(
        county_fips, coc_number, coc_name, state_abbr,
        county_population_share, split_county_flag
      ),
    by = "county_fips",
    relationship = "many-to-many"
  ) |>
  mutate(
    allocated_population =
      population * county_population_share
  )

strict_allocated_sum <- function(values, shares) {
  positive <- !is.na(shares) & shares > 0
  if (!any(positive) || any(is.na(values[positive]))) {
    return(NA_real_)
  }
  sum(values[positive] * shares[positive])
}

weighted_average_with_coverage <- function(values, weights, minimum = 0.90) {
  eligible <- !is.na(weights) & weights > 0
  observed <- eligible & !is.na(values)
  if (!any(observed)) {
    return(NA_real_)
  }
  coverage <- sum(weights[observed]) / sum(weights[eligible])
  if (coverage < minimum) {
    return(NA_real_)
  }
  weighted.mean(values[observed], weights[observed])
}

grouped_rows <- split(
  county_allocated,
  interaction(
    county_allocated$coc_number,
    county_allocated$year,
    drop = TRUE
  )
)

aggregate_one_coc_year <- function(group) {
  result <- data.frame(
    state = group$state[1],
    state_abbr = group$state_abbr[1],
    coc_number = group$coc_number[1],
    coc_name = group$coc_name[1],
    year = group$year[1],
    estimated_coc_population = sum(group$allocated_population),
    contributing_counties = n_distinct(group$county_fips),
    contains_split_county_flag = max(group$split_county_flag),
    stringsAsFactors = FALSE
  )

  for (variable in total_variables) {
    result[[variable]] <- strict_allocated_sum(
      group[[variable]],
      group$county_population_share
    )
  }
  for (variable in average_variables) {
    result[[variable]] <- weighted_average_with_coverage(
      group[[variable]],
      group$allocated_population
    )
  }
  result
}

coc_area <- coc_boundaries |>
  mutate(coc_land_area_sq_miles = as.numeric(st_area(geometry)) / 2589988.110336) |>
  st_drop_geometry() |>
  transmute(coc_number = COCNUM, coc_land_area_sq_miles)

cpi_lookup <- read.csv(state_panel_file, check.names = FALSE) |>
  select(year, cpi_u) |>
  distinct()
if (anyDuplicated(cpi_lookup$year)) {
  stop("CPI must have exactly one value per year.")
}
cpi_2025 <- cpi_lookup$cpi_u[cpi_lookup$year == 2025]
if (length(cpi_2025) != 1 || is.na(cpi_2025)) {
  stop("A single 2025 CPI value is required for real-dollar predictors.")
}

coc_predictors <- bind_rows(lapply(grouped_rows, aggregate_one_coc_year)) |>
  left_join(coc_area, by = "coc_number") |>
  left_join(cpi_lookup, by = "year") |>
  mutate(
    coc_year = paste(coc_number, year, sep = " | "),
    population_allocation_method =
      "FY2024 CoC boundaries and ACS 2024 tract-population shares",
    log_estimated_coc_population = log1p(estimated_coc_population),
    population_density_per_sq_mile_derived =
      estimated_coc_population / coc_land_area_sq_miles,
    housing_units_per_1000_residents =
      1000 * housing_units / estimated_coc_population,
    permits_per_1000_residents =
      1000 * permits_total_units_authorized / estimated_coc_population,
    permits_per_1000_housing_units =
      1000 * permits_total_units_authorized / housing_units,
    multifamily_permit_share_pct = if_else(
      permits_total_units_authorized > 0,
      100 * permits_five_plus_unit_units / permits_total_units_authorized,
      NA_real_
    ),
    real_median_household_income_2025_usd =
      median_household_income * cpi_2025 / cpi_u,
    real_per_capita_personal_income_2025_usd =
      bea_per_capita_personal_income_usd * cpi_2025 / cpi_u,
    real_median_home_sale_price_2025_usd =
      median_home_sale_price_annual_avg_usd * cpi_2025 / cpi_u,
    real_state_minimum_wage_2025_usd =
      state_minimum_wage_usd_per_hour * cpi_2025 / cpi_u,
    real_gdp_per_capita_2017_usd =
      1000 * bea_real_gdp_thousands_2017_usd / bea_population
  ) |>
  select(
    coc_year, state, state_abbr, coc_number, coc_name, year,
    estimated_coc_population, contributing_counties,
    contains_split_county_flag, population_allocation_method,
    log_estimated_coc_population, coc_land_area_sq_miles,
    population_density_per_sq_mile_derived,
    housing_units_per_1000_residents, permits_per_1000_residents,
    permits_per_1000_housing_units, multifamily_permit_share_pct,
    real_median_household_income_2025_usd,
    real_per_capita_personal_income_2025_usd,
    real_median_home_sale_price_2025_usd,
    real_state_minimum_wage_2025_usd,
    real_gdp_per_capita_2017_usd,
    all_of(setdiff(candidate_variables, "population"))
  ) |>
  arrange(state, coc_number, year)

outcomes <- pit |>
  left_join(
    coc_predictors |>
      select(coc_number, year, estimated_coc_population),
    by = c("coc_number", "year")
  ) |>
  mutate(
    homeless_rate_per_10k_estimated = if_else(
      is.na(estimated_coc_population) | estimated_coc_population <= 0,
      NA_real_,
      10000 * total_homeless / estimated_coc_population
    ),
    population_denominator_status = if_else(
      is.na(estimated_coc_population),
      "Unavailable: historical CoC not represented by FY2024 boundary",
      "Estimated from county population allocated with ACS 2024 tract shares"
    )
  ) |>
  relocate(
    homeless_rate_per_10k_estimated,
    .after = total_homeless
  )

next_year_outcome <- outcomes |>
  transmute(
    coc_number,
    predictor_year = year - 1L,
    target_year = year,
    target_total_homeless = total_homeless,
    target_estimated_coc_population = estimated_coc_population,
    target_homeless_rate_per_10k =
      homeless_rate_per_10k_estimated,
    target_pit_count_caution_flag = pit_count_caution_flag
  )

lasso_candidates <- coc_predictors |>
  rename(predictor_year = year) |>
  left_join(
    next_year_outcome,
    by = c("coc_number", "predictor_year")
  ) |>
  filter(!is.na(target_year)) |>
  mutate(
    target_definition =
      "Next-year PIT homelessness per 10,000 estimated CoC residents"
  ) |>
  arrange(state, coc_number, predictor_year)

lasso_model_panel <- lasso_candidates |>
  filter(target_pit_count_caution_flag == 0) |>
  select(
    state, state_abbr, coc_number, coc_name, predictor_year, target_year,
    target_total_homeless, target_estimated_coc_population,
    target_homeless_rate_per_10k, target_definition,
    everything(),
    -coc_year
  )

core_predictors <- c(
  "log_estimated_coc_population",
  "population_density_per_sq_mile_derived",
  "housing_units_per_1000_residents",
  "permits_per_1000_housing_units",
  "multifamily_permit_share_pct",
  "net_migration_rate_per_1000",
  "poverty_all_pct",
  "real_median_household_income_2025_usd",
  "homeownership_rate_pct",
  "housing_cost_burdened_households_pct",
  "income_inequality_top_bottom_quintile_ratio",
  "annual_hpi_change_pct",
  "real_gdp_per_capita_2017_usd",
  "real_state_minimum_wage_2025_usd",
  "medicaid_expansion_status"
)

lasso_core_complete_panel <- lasso_model_panel |>
  mutate(
    state_florida = as.integer(state == "Florida"),
    time_index = predictor_year - 2010L
  ) |>
  select(
    state, state_abbr, coc_number, coc_name, predictor_year, target_year,
    target_total_homeless, target_estimated_coc_population,
    target_homeless_rate_per_10k, state_florida, time_index,
    all_of(core_predictors),
    contains_split_county_flag, contributing_counties,
    population_allocation_method, target_definition
  ) |>
  filter(if_all(
    all_of(c("target_homeless_rate_per_10k", core_predictors)),
    ~ !is.na(.x)
  )) |>
  arrange(state, coc_number, predictor_year)

state_panel <- read.csv(state_panel_file, check.names = FALSE)
state_total_check <- pit |>
  group_by(state, year) |>
  summarise(coc_sum_total_homeless = sum(total_homeless), .groups = "drop") |>
  left_join(
    state_panel |>
      select(state, year, total_homeless) |>
      rename(state_total_homeless = total_homeless),
    by = c("state", "year")
  )

crosswalk_share_check <- county_coc_crosswalk |>
  group_by(county_fips) |>
  summarise(share_sum = sum(county_population_share), .groups = "drop")

validation <- data.frame(
  check = c(
    "CoC-year key is unique",
    "PIT counts are nonnegative when observed",
    "Sheltered plus unsheltered equals total",
    "2025 contains 44 California CoCs",
    "2025 contains 27 Florida CoCs",
    "All 125 counties appear in the population crosswalk",
    "County-to-CoC population shares sum to one",
    "Every tract receives a CoC assignment after nearest-boundary fallback",
    "CoC PIT totals reproduce state PIT totals",
    "LASSO target is always the next year",
    "The LASSO model panel excludes the disrupted 2021 target",
    "The core complete-case LASSO panel has no missing model fields"
  ),
  pass = c(
    !anyDuplicated(pit[c("coc_number", "year")]),
    all(pit$total_homeless >= 0, na.rm = TRUE),
    all(
      pit$total_homeless ==
        pit$sheltered_homeless + pit$unsheltered_homeless,
      na.rm = TRUE
    ),
    sum(pit$year == 2025 & pit$state_abbr == "CA") == 44,
    sum(pit$year == 2025 & pit$state_abbr == "FL") == 27,
    n_distinct(county_coc_crosswalk$county_fips) == 125,
    max(abs(crosswalk_share_check$share_sum - 1)) < 1e-10,
    !anyNA(tract_assignment$COCNUM),
    all(
      state_total_check$coc_sum_total_homeless ==
        state_total_check$state_total_homeless,
      na.rm = TRUE
    ),
    all(lasso_candidates$target_year == lasso_candidates$predictor_year + 1),
    !any(lasso_model_panel$target_year == 2021),
    !anyNA(lasso_core_complete_panel[
      c("target_homeless_rate_per_10k", core_predictors)
    ])
  ),
  stringsAsFactors = FALSE
)

coverage_for <- function(data, dataset_name) {
  numeric_names <- names(data)[vapply(data, is.numeric, logical(1))]
  bind_rows(lapply(numeric_names, function(variable) {
    observed <- !is.na(data[[variable]])
    data.frame(
      dataset = dataset_name,
      variable,
      rows = nrow(data),
      nonmissing = sum(observed),
      missing = sum(!observed),
      coverage_pct = round(100 * mean(observed), 1),
      min_year = if (
        any(observed) &&
          ("year" %in% names(data) || "predictor_year" %in% names(data))
      ) {
        year_values <- if ("year" %in% names(data)) {
          data$year
        } else {
          data$predictor_year
        }
        min(year_values[observed])
      } else {
        NA_integer_
      },
      max_year = if (
        any(observed) &&
          ("year" %in% names(data) || "predictor_year" %in% names(data))
      ) {
        year_values <- if ("year" %in% names(data)) {
          data$year
        } else {
          data$predictor_year
        }
        max(year_values[observed])
      } else {
        NA_integer_
      },
      stringsAsFactors = FALSE
    )
  }))
}

coverage <- bind_rows(
  coverage_for(outcomes, "CoC homelessness outcomes"),
  coverage_for(coc_predictors, "Allocated CoC predictors"),
  coverage_for(lasso_model_panel, "Next-year LASSO model panel"),
  coverage_for(lasso_core_complete_panel, "Core complete-case LASSO panel")
)

variable_dictionary <- data.frame(
  variable = c(
    "total_homeless", "sheltered_homeless", "unsheltered_homeless",
    "homeless_rate_per_10k_estimated", "estimated_coc_population",
    "target_homeless_rate_per_10k", "pit_count_caution_flag",
    "contains_split_county_flag", "population_allocation_method"
  ),
  definition = c(
    "HUD Point-in-Time total homelessness count for one CoC.",
    "HUD sheltered PIT count.",
    "HUD unsheltered PIT count.",
    paste(
      "Total PIT homelessness divided by the estimated CoC population",
      "denominator, multiplied by 10,000."
    ),
    paste(
      "Annual county population allocated to FY2024 CoCs using ACS 2024",
      "tract-population shares."
    ),
    paste(
      "Primary LASSO outcome: next-year PIT homelessness per 10,000",
      "estimated CoC residents."
    ),
    "Equals one for the COVID-disrupted 2021 PIT count; never a predictor.",
    "Equals one when a contributing county is materially split across CoCs.",
    paste(
      "Documents that FY2024 CoC boundaries and ACS 2024 tract shares",
      "were used to allocate county-year predictors."
    )
  ),
  unit = c(
    "people", "people", "people", "people per 10,000",
    "estimated residents", "people per 10,000", "0/1", "0/1", "text"
  ),
  role = c(
    "outcome component", "outcome component", "outcome component",
    "descriptive outcome", "denominator/control", "primary prediction target",
    "quality flag", "quality flag", "provenance"
  ),
  stringsAsFactors = FALSE
)

source_notes <- data.frame(
  source = c(
    "HUD PIT",
    "HUD CoC boundaries",
    "Census tract boundaries",
    "ACS tract population",
    "County predictors"
  ),
  coverage = c(
    "CoC PIT counts, 2010-2025",
    "FY2024 CoC geography",
    "2024 TIGER/Line tracts for California and Florida",
    "ACS 2024 five-year B01003 total population",
    "California and Florida county-year panel, 2010-2025"
  ),
  file = c(
    "raw_data/2007-2025-PIT-Counts-by-CoC.xlsb",
    "raw_data/hud_coc_boundaries_FY2024_CA_FL.geojson",
    paste(basename(tract_zip_files), collapse = "; "),
    paste(basename(tract_population_files), collapse = "; "),
    "county_raw_panel/county_year_raw_panel_CA_FL_2010_2025.csv"
  ),
  limitation = c(
    "PIT is a one-night count; 2021 is not comparable.",
    "Applied retrospectively; historical CoC boundaries can differ.",
    "Tracts are assigned by point-on-surface, with a documented nearest fallback.",
    "Used only to create fixed county-to-CoC population shares.",
    paste(
      "County totals and averages are allocated to CoCs; subcounty variation",
      "is not observed."
    )
  ),
  stringsAsFactors = FALSE
)

raw_file_index <- data.frame(
  file = substring(required_files, nchar(project_root) + 2L),
  size_bytes = file.info(required_files)$size,
  modified_at = format(file.info(required_files)$mtime, "%Y-%m-%d %H:%M:%S %Z"),
  md5 = unname(tools::md5sum(required_files)),
  stringsAsFactors = FALSE
)

write.csv(
  outcomes,
  file.path(output_dir, "coc_year_homelessness_outcomes_CA_FL_2010_2025.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  county_coc_crosswalk,
  file.path(output_dir, "county_to_coc_population_crosswalk_FY2024.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  coc_predictors,
  file.path(output_dir, "coc_year_allocated_predictors_CA_FL_2010_2025.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  lasso_model_panel,
  file.path(output_dir, "lasso_next_year_candidate_panel.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  lasso_core_complete_panel,
  file.path(output_dir, "lasso_core_complete_panel.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  coverage,
  file.path(output_dir, "coverage_summary.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  validation,
  file.path(output_dir, "validation_checks.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  variable_dictionary,
  file.path(output_dir, "variable_dictionary.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  source_notes,
  file.path(output_dir, "source_notes.csv"),
  row.names = FALSE,
  na = ""
)
write.csv(
  raw_file_index,
  file.path(output_dir, "raw_file_index.csv"),
  row.names = FALSE,
  na = ""
)

workbook <- createWorkbook()
addWorksheet(workbook, "README")
addWorksheet(workbook, "CoC Outcomes")
addWorksheet(workbook, "LASSO Candidates")
addWorksheet(workbook, "LASSO Core Complete")
addWorksheet(workbook, "County-CoC Crosswalk")
addWorksheet(workbook, "Variable Dictionary")
addWorksheet(workbook, "Coverage")
addWorksheet(workbook, "Validation")
addWorksheet(workbook, "Source Notes")
addWorksheet(workbook, "Raw File Index")

readme_rows <- data.frame(
  Item = c(
    "Purpose",
    "Primary target",
    "Unit of observation",
    "Observed outcome rows",
    "Next-year candidate rows",
    "Core complete-case rows",
    "Outcome geography",
    "Rate denominator",
    "Prediction timing",
    "2021 treatment",
    "Validation",
    "Main limitation",
    "Official HUD source"
  ),
  Value = c(
    "Predict California and Florida homelessness using county-derived factors aligned to HUD Continuums of Care.",
    "target_homeless_rate_per_10k",
    "One CoC-year; predictor year t is matched to PIT target year t + 1.",
    format(nrow(outcomes), big.mark = ","),
    format(nrow(lasso_model_panel), big.mark = ","),
    format(nrow(lasso_core_complete_panel), big.mark = ","),
    "Observed HUD Point-in-Time count by Continuum of Care.",
    "Estimated CoC population from county population allocated with FY2024 CoC boundaries and ACS 2024 tract shares.",
    "Prior-year predictors; use rolling-origin validation, not a random row split.",
    "Excluded as a prediction target because COVID disrupted unsheltered enumeration.",
    paste(sum(validation$pass), "of", nrow(validation), "checks pass."),
    "Historical CoC boundaries can differ from FY2024; allocated subcounty predictors and denominators are estimates.",
    "https://www.huduser.gov/portal/datasets/ahar/2025-ahar-part-1-pit-estimates-of-homelessness-in-the-us.html"
  ),
  stringsAsFactors = FALSE
)

mergeCells(workbook, "README", cols = 1:8, rows = 1)
writeData(
  workbook,
  "README",
  "California–Florida CoC Homelessness & LASSO Analysis",
  startCol = 1,
  startRow = 1
)
writeData(workbook, "README", readme_rows, startCol = 1, startRow = 3)

sheet_data <- list(
  "CoC Outcomes" = outcomes,
  "LASSO Candidates" = lasso_model_panel,
  "LASSO Core Complete" = lasso_core_complete_panel,
  "County-CoC Crosswalk" = county_coc_crosswalk,
  "Variable Dictionary" = variable_dictionary,
  "Coverage" = coverage,
  "Validation" = validation,
  "Source Notes" = source_notes,
  "Raw File Index" = raw_file_index
)
for (sheet in names(sheet_data)) {
  writeData(workbook, sheet, sheet_data[[sheet]])
}

header_style <- createStyle(
  fgFill = "#1F4E78",
  fontColour = "#FFFFFF",
  textDecoration = "bold",
  halign = "center",
  valign = "center"
)
title_style <- createStyle(
  fgFill = "#17365D",
  fontColour = "#FFFFFF",
  textDecoration = "bold",
  fontSize = 15,
  halign = "left",
  valign = "center"
)
readme_label_style <- createStyle(
  fgFill = "#D9EAF7",
  textDecoration = "bold",
  valign = "top"
)
readme_value_style <- createStyle(wrapText = TRUE, valign = "top")
count_style <- createStyle(numFmt = "#,##0")
year_style <- createStyle(numFmt = "0")
decimal_style <- createStyle(numFmt = "0.00")
currency_style <- createStyle(numFmt = "$#,##0")
wrapped_text_style <- createStyle(wrapText = TRUE, valign = "top")

addStyle(workbook, "README", title_style, rows = 1, cols = 1:8, gridExpand = TRUE)
addStyle(
  workbook, "README", header_style,
  rows = 3, cols = 1:2, gridExpand = TRUE
)
addStyle(
  workbook, "README", readme_label_style,
  rows = 4:(nrow(readme_rows) + 3), cols = 1, gridExpand = TRUE
)
addStyle(
  workbook, "README", readme_value_style,
  rows = 4:(nrow(readme_rows) + 3), cols = 2, gridExpand = TRUE
)
setRowHeights(workbook, "README", rows = 1, heights = 36)
setRowHeights(
  workbook, "README", rows = 4:(nrow(readme_rows) + 3), heights = 32
)
setColWidths(workbook, "README", cols = 1, widths = 25)
setColWidths(workbook, "README", cols = 2, widths = 58)
setColWidths(workbook, "README", cols = 3:8, widths = 4)
freezePane(workbook, "README", firstActiveRow = 3)
showGridLines(workbook, "README", showGridLines = FALSE)
pageSetup(
  workbook, "README", orientation = "portrait",
  fitToWidth = 1, fitToHeight = 1
)

for (sheet in names(sheet_data)) {
  sheet_ncols <- ncol(sheet_data[[sheet]])
  sheet_nrows <- nrow(sheet_data[[sheet]])
  headers <- names(sheet_data[[sheet]])
  freezePane(workbook, sheet, firstRow = TRUE)
  if (sheet_ncols > 12) {
    freezePane(workbook, sheet, firstRow = TRUE, firstCol = TRUE)
  }
  addFilter(workbook, sheet, rows = 1, cols = 1:sheet_ncols)
  addStyle(
    workbook,
    sheet,
    header_style,
    rows = 1,
    cols = 1:sheet_ncols,
    gridExpand = TRUE
  )
  setRowHeights(workbook, sheet, rows = 1, heights = 36)
  setColWidths(workbook, sheet, cols = 1:sheet_ncols, widths = "auto")
  showGridLines(workbook, sheet, showGridLines = FALSE)
  pageSetup(
    workbook, sheet, orientation = "landscape",
    fitToWidth = 1, fitToHeight = 0
  )

  if (sheet_nrows > 0) {
    data_rows <- 2:(sheet_nrows + 1)
    currency_cols <- which(grepl(
      "usd|income|price|value_authorized|minimum_wage",
      headers,
      ignore.case = TRUE
    ))
    decimal_cols <- which(grepl(
      "rate|pct|share|per_10|per_100|per_1000|ratio|index|density|distance",
      headers,
      ignore.case = TRUE
    ))
    count_cols <- which(
      vapply(sheet_data[[sheet]], is.numeric, logical(1)) &
        !seq_along(headers) %in% c(currency_cols, decimal_cols)
    )
    year_cols <- which(grepl("(^year$|_year$|time_index$)", headers))
    if (length(currency_cols) > 0) {
      addStyle(
        workbook, sheet, currency_style, rows = data_rows,
        cols = currency_cols, gridExpand = TRUE, stack = TRUE
      )
    }
    if (length(decimal_cols) > 0) {
      addStyle(
        workbook, sheet, decimal_style, rows = data_rows,
        cols = decimal_cols, gridExpand = TRUE, stack = TRUE
      )
    }
    if (length(count_cols) > 0) {
      addStyle(
        workbook, sheet, count_style, rows = data_rows,
        cols = count_cols, gridExpand = TRUE, stack = TRUE
      )
    }
    if (length(year_cols) > 0) {
      addStyle(
        workbook, sheet, year_style, rows = data_rows,
        cols = year_cols, gridExpand = TRUE, stack = TRUE
      )
    }
  }

  identifier_widths <- c(
    state = 12, state_abbr = 11, year = 10, predictor_year = 14,
    target_year = 12, coc_year = 14, coc_number = 13,
    county_fips = 13, pass = 10
  )
  for (column_name in intersect(names(identifier_widths), headers)) {
    setColWidths(
      workbook, sheet, cols = match(column_name, headers),
      widths = unname(identifier_widths[[column_name]])
    )
  }
  name_widths <- c(coc_name = 34, county_name = 30, variable = 37)
  for (column_name in intersect(names(name_widths), headers)) {
    setColWidths(
      workbook, sheet, cols = match(column_name, headers),
      widths = unname(name_widths[[column_name]])
    )
  }

  narrative_widths <- c(
    definition = 58, unit = 22, role = 28, check = 68,
    source = 28, coverage = 42, file = 58, limitation = 62,
    population_denominator_status = 38,
    population_allocation_method = 42, target_definition = 44
  )
  narrative_cols <- intersect(names(narrative_widths), headers)
  for (column_name in narrative_cols) {
    column_number <- match(column_name, headers)
    setColWidths(
      workbook, sheet, cols = column_number,
      widths = unname(narrative_widths[[column_name]])
    )
    if (sheet_nrows > 0) {
      addStyle(
        workbook, sheet, wrapped_text_style, rows = 2:(sheet_nrows + 1),
        cols = column_number, gridExpand = TRUE, stack = TRUE
      )
    }
  }

  if (sheet %in% c(
    "Variable Dictionary", "Validation", "Source Notes", "Raw File Index"
  ) && sheet_nrows > 0) {
    setRowHeights(
      workbook, sheet, rows = 2:(sheet_nrows + 1), heights = 36
    )
  }
  if (sheet == "Coverage") {
    coverage_count_cols <- match(
      intersect(c("rows", "nonmissing", "missing"), headers), headers
    )
    setColWidths(workbook, sheet, cols = coverage_count_cols, widths = 13)
  }
  if (sheet == "Raw File Index") {
    setColWidths(workbook, sheet, cols = match("size_bytes", headers), widths = 15)
    setColWidths(workbook, sheet, cols = match("modified_at", headers), widths = 23)
    setColWidths(workbook, sheet, cols = match("md5", headers), widths = 38)
  }
}

saveWorkbook(
  workbook,
  file.path(output_dir, "coc_lasso_analysis_CA_FL_2010_2025.xlsx"),
  overwrite = TRUE
)

if (!all(validation$pass)) {
  stop(
    "One or more validation checks failed:\n",
    paste(validation$check[!validation$pass], collapse = "\n")
  )
}

message(
  "Built ", nrow(outcomes), " CoC-year outcome rows; ",
  nrow(lasso_model_panel), " next-year LASSO candidate rows; all ",
  nrow(validation), " validation checks passed."
)
