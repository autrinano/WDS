#!/usr/bin/env Rscript

# Raw county-year acquisition panel for all California and Florida counties,
# 2010-2025. Source values are reshaped and keyed by FIPS, but are not
# interpolated, imputed, winsorized, inflation-adjusted, or otherwise cleaned.

options(timeout = 300)

project_dir <- normalizePath(getwd(), mustWork = TRUE)
if (basename(project_dir) != "Final Project") {
  candidate <- file.path(project_dir, "Final Project")
  if (dir.exists(candidate)) project_dir <- normalizePath(candidate)
}

output_dir <- file.path(project_dir, "county_raw_panel")
raw_dir <- file.path(output_dir, "raw_downloads")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

local_lib <- file.path(project_dir, "_r_libs")
if (dir.exists(local_lib)) .libPaths(c(local_lib, .libPaths()))

required <- c("dplyr", "tidyr", "readr", "readxl", "jsonlite", "httr", "openxlsx")
missing_pkgs <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs)) {
  stop("Missing required R packages: ", paste(missing_pkgs, collapse = ", "))
}

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(readxl)
  library(jsonlite)
  library(httr)
  library(openxlsx)
})

retrieval_date <- as.Date("2026-07-24")
target_states <- c("06" = "California", "12" = "Florida")
target_abbr <- c("06" = "CA", "12" = "FL")
target_years <- 2010:2025

download_once <- function(url, destination) {
  if (!file.exists(destination) || file.info(destination)$size == 0) {
    message("Downloading ", basename(destination))
    download.file(url, destination, mode = "wb", quiet = TRUE)
  }
  destination
}

as_number_raw <- function(x) {
  x <- trimws(as.character(x))
  x[x %in% c("", ".", "(NA)", "NA", "--", "(D)", "(L)")] <- NA_character_
  suppressWarnings(as.numeric(gsub(",", "", x, fixed = TRUE)))
}

clean_geo_name <- function(x) {
  x |>
    sub("^\\.", "", x = _) |>
    sub(", (California|Florida)$", "", x = _) |>
    sub(" County$", "", x = _) |>
    tolower() |>
    gsub("[^a-z0-9]", "", x = _)
}

reshape_prefix <- function(data, prefix, value_name) {
  cols <- names(data)[grepl(paste0("^", prefix, "[0-9]{4}$"), names(data))]
  if (!length(cols)) return(tibble())
  data |>
    select(state_fips, county_fips, fips, state, county_name, all_of(cols)) |>
    pivot_longer(
      cols = all_of(cols),
      names_to = "year",
      names_pattern = paste0("^", prefix, "([0-9]{4})$"),
      values_to = value_name
    ) |>
    mutate(
      year = as.integer(year),
      across(all_of(value_name), as_number_raw)
    ) |>
    filter(year %in% target_years)
}

# ---------------------------------------------------------------------------
# 1. Census Population Estimates Program (PEP)
# ---------------------------------------------------------------------------

pep_urls <- c(
  "2010_2019" = paste0(
    "https://www2.census.gov/programs-surveys/popest/datasets/",
    "2010-2019/counties/totals/co-est2019-alldata.csv"
  ),
  "2020_2025" = paste0(
    "https://www2.census.gov/programs-surveys/popest/datasets/",
    "2020-2025/counties/totals/co-est2025-alldata.csv"
  )
)

pep_files <- c(
  "2010_2019" = file.path(raw_dir, "census_pep_co-est2019-alldata.csv"),
  "2020_2025" = file.path(raw_dir, "census_pep_co-est2025-alldata.csv")
)

Map(download_once, pep_urls, pep_files)

read_pep <- function(path) {
  read_csv(path, col_types = cols(.default = col_character()), show_col_types = FALSE) |>
    filter(SUMLEV == "050", STATE %in% names(target_states)) |>
    transmute(
      state_fips = sprintf("%02d", as.integer(STATE)),
      county_fips = sprintf("%03d", as.integer(COUNTY)),
      fips = paste0(state_fips, county_fips),
      state = STNAME,
      county_name = CTYNAME,
      across(everything())
    ) |>
    select(-SUMLEV, -REGION, -DIVISION, -STATE, -COUNTY, -STNAME, -CTYNAME)
}

pep_old <- read_pep(pep_files[["2010_2019"]])
pep_new <- read_pep(pep_files[["2020_2025"]])

pep_prefixes <- c(
  population = "POPESTIMATE",
  population_change = "NPOPCHG",
  births = "BIRTHS",
  deaths = "DEATHS",
  natural_change = "NATURALCHG",
  international_migration = "INTERNATIONALMIG",
  domestic_migration = "DOMESTICMIG",
  net_migration = "NETMIG",
  group_quarters_population = "GQESTIMATES",
  birth_rate_per_1000 = "RBIRTH",
  death_rate_per_1000 = "RDEATH",
  natural_change_rate_per_1000 = "RNATURALCHG",
  international_migration_rate_per_1000 = "RINTERNATIONALMIG",
  domestic_migration_rate_per_1000 = "RDOMESTICMIG",
  net_migration_rate_per_1000 = "RNETMIG"
)

pep_long_parts <- lapply(names(pep_prefixes), function(value_name) {
  prefix <- pep_prefixes[[value_name]]
  bind_rows(
    reshape_prefix(pep_old, prefix, value_name),
    reshape_prefix(pep_new, prefix, value_name)
  ) |>
    distinct(fips, year, .keep_all = TRUE)
})

pep_raw <- Reduce(
  function(x, y) full_join(
    x, y,
    by = c("state_fips", "county_fips", "fips", "state", "county_name", "year")
  ),
  pep_long_parts
) |>
  arrange(fips, year)

county_lookup <- pep_raw |>
  distinct(state_fips, county_fips, fips, state, county_name) |>
  mutate(
    state_abbr = unname(target_abbr[state_fips]),
    county_key = clean_geo_name(county_name)
  ) |>
  arrange(fips)

stopifnot(nrow(county_lookup) == 125L)

# ---------------------------------------------------------------------------
# 2. Census county housing-unit estimates
# ---------------------------------------------------------------------------

housing_urls <- c(
  "2010_2019" = paste0(
    "https://www2.census.gov/programs-surveys/popest/tables/",
    "2010-2019/housing/totals/CO-EST2019-ANNHU.xlsx"
  ),
  "2020_2025" = paste0(
    "https://www2.census.gov/programs-surveys/popest/tables/",
    "2020-2025/housing/totals/CO-EST2025-HU.xlsx"
  )
)

housing_files <- c(
  "2010_2019" = file.path(raw_dir, "census_CO-EST2019-ANNHU.xlsx"),
  "2020_2025" = file.path(raw_dir, "census_CO-EST2025-HU.xlsx")
)

Map(download_once, housing_urls, housing_files)

read_housing <- function(path) {
  dat <- read_excel(path, col_names = FALSE)
  header <- unlist(dat[4, ], use.names = FALSE)
  years <- suppressWarnings(as.integer(header))
  year_cols <- which(years %in% target_years)
  geo <- as.character(dat[[1]])
  state <- case_when(
    grepl(", California$", geo) ~ "California",
    grepl(", Florida$", geo) ~ "Florida",
    TRUE ~ NA_character_
  )
  base <- tibble(source_geo_name = geo, state = state) |>
    mutate(
      state_fips = names(target_states)[match(state, unname(target_states))],
      county_key = clean_geo_name(source_geo_name)
  )
  values <- dat[, year_cols, drop = FALSE]
  names(values) <- as.character(years[year_cols])
  values <- values |>
    mutate(across(everything(), as.character))
  bind_cols(base, values) |>
    filter(!is.na(state)) |>
    pivot_longer(
      cols = all_of(as.character(years[year_cols])),
      names_to = "year",
      values_to = "housing_units"
    ) |>
    mutate(
      year = as.integer(year),
      housing_units = as_number_raw(housing_units)
    ) |>
    left_join(
      county_lookup |>
        select(state_fips, county_key, county_fips, fips, county_name),
      by = c("state_fips", "county_key")
    ) |>
    select(
      state_fips, county_fips, fips, state, county_name, year,
      source_geo_name, housing_units
    )
}

housing_raw <- bind_rows(lapply(housing_files, read_housing)) |>
  distinct(fips, year, .keep_all = TRUE) |>
  arrange(fips, year)

stopifnot(!any(is.na(housing_raw$fips)))

# ---------------------------------------------------------------------------
# 3. Census Bureau / HUD Building Permits Survey
# ---------------------------------------------------------------------------

bps_names <- c(
  "survey_year", "state_fips", "county_fips", "region_code", "division_code",
  "source_county_name",
  "one_unit_buildings", "one_unit_units", "one_unit_value",
  "two_unit_buildings", "two_unit_units", "two_unit_value",
  "three_four_unit_buildings", "three_four_unit_units", "three_four_unit_value",
  "five_plus_unit_buildings", "five_plus_unit_units", "five_plus_unit_value",
  "one_unit_reported_buildings", "one_unit_reported_units", "one_unit_reported_value",
  "two_unit_reported_buildings", "two_unit_reported_units", "two_unit_reported_value",
  "three_four_reported_buildings", "three_four_reported_units", "three_four_reported_value",
  "five_plus_reported_buildings", "five_plus_reported_units", "five_plus_reported_value"
)

bps_urls <- setNames(
  sprintf("https://www2.census.gov/econ/bps/County/co%da.txt", target_years),
  target_years
)
bps_files <- setNames(
  file.path(raw_dir, sprintf("census_bps_co%da.txt", target_years)),
  target_years
)
Map(download_once, bps_urls, bps_files)

read_bps <- function(path) {
  dat <- read_csv(
    path,
    skip = 2,
    col_names = bps_names,
    col_types = cols(.default = col_character()),
    show_col_types = FALSE,
    trim_ws = TRUE
  ) |>
    filter(state_fips %in% names(target_states)) |>
    mutate(
      state_fips = sprintf("%02d", as.integer(state_fips)),
      county_fips = sprintf("%03d", as.integer(county_fips)),
      fips = paste0(state_fips, county_fips),
      year = as.integer(survey_year),
      state = unname(target_states[state_fips]),
      county_name = trimws(source_county_name),
      across(
        matches("(buildings|units|value)$"),
        as_number_raw
      )
    )

  dat |>
    rowwise() |>
    mutate(
      total_units_authorized = sum(
        c_across(c(one_unit_units, two_unit_units, three_four_unit_units, five_plus_unit_units)),
        na.rm = FALSE
      ),
      total_value_authorized = sum(
        c_across(c(one_unit_value, two_unit_value, three_four_unit_value, five_plus_unit_value)),
        na.rm = FALSE
      ),
      total_reported_units = sum(
        c_across(c(
          one_unit_reported_units, two_unit_reported_units,
          three_four_reported_units, five_plus_reported_units
        )),
        na.rm = FALSE
      )
    ) |>
    ungroup() |>
    select(-survey_year)
}

bps_raw <- bind_rows(lapply(bps_files, read_bps)) |>
  arrange(fips, year)

# ---------------------------------------------------------------------------
# 4. Census Small Area Income and Poverty Estimates (SAIPE)
# ---------------------------------------------------------------------------

saipe_urls <- setNames(
  sprintf(
    paste0(
      "https://www2.census.gov/programs-surveys/saipe/datasets/%d/",
      "%d-state-and-county/est%02dall.xls"
    ),
    target_years[target_years <= 2024],
    target_years[target_years <= 2024],
    target_years[target_years <= 2024] %% 100
  ),
  target_years[target_years <= 2024]
)
saipe_files <- setNames(
  file.path(
    raw_dir,
    sprintf("census_saipe_est%02dall.xls", target_years[target_years <= 2024] %% 100)
  ),
  target_years[target_years <= 2024]
)
Map(download_once, saipe_urls, saipe_files)

saipe_names <- c(
  "state_fips", "county_fips", "postal_code", "source_county_name",
  "poverty_all_estimate", "poverty_all_ci_low", "poverty_all_ci_high",
  "poverty_all_pct", "poverty_all_pct_ci_low", "poverty_all_pct_ci_high",
  "poverty_child_estimate", "poverty_child_ci_low", "poverty_child_ci_high",
  "poverty_child_pct", "poverty_child_pct_ci_low", "poverty_child_pct_ci_high",
  "poverty_age_5_17_estimate", "poverty_age_5_17_ci_low", "poverty_age_5_17_ci_high",
  "poverty_age_5_17_pct", "poverty_age_5_17_pct_ci_low", "poverty_age_5_17_pct_ci_high",
  "median_household_income", "median_household_income_ci_low",
  "median_household_income_ci_high"
)

read_saipe <- function(path, year) {
  dat <- read_excel(path, col_names = FALSE, col_types = "text")
  header_row <- which(grepl("State FIPS", as.character(dat[[1]]), ignore.case = TRUE))[1]
  values <- dat[(header_row + 1):nrow(dat), seq_along(saipe_names), drop = FALSE]
  names(values) <- saipe_names
  values |>
    filter(state_fips %in% names(target_states)) |>
    mutate(
      state_fips = sprintf("%02d", as.integer(state_fips)),
      county_fips = sprintf("%03d", as.integer(county_fips)),
      fips = paste0(state_fips, county_fips),
      state = unname(target_states[state_fips]),
      county_name = source_county_name,
      year = as.integer(year),
      across(all_of(saipe_names[5:length(saipe_names)]), as_number_raw)
    ) |>
    select(
      state_fips, county_fips, fips, state, county_name, year,
      everything(), -postal_code
    )
}

saipe_raw <- bind_rows(Map(read_saipe, saipe_files, as.integer(names(saipe_files)))) |>
  arrange(fips, year)

# ---------------------------------------------------------------------------
# 5. BEA county personal income and GDP
# ---------------------------------------------------------------------------

bea_urls <- c(
  "CAINC1" = "https://apps.bea.gov/regional/zip/CAINC1.zip",
  "CAGDP1" = "https://apps.bea.gov/regional/zip/CAGDP1.zip"
)
bea_files <- c(
  "CAINC1" = file.path(raw_dir, "bea_CAINC1.zip"),
  "CAGDP1" = file.path(raw_dir, "bea_CAGDP1.zip")
)
Map(download_once, bea_urls, bea_files)

read_bea <- function(zip_path, table_name, state_abbr, first_year) {
  member <- sprintf(
    "%s_%s_%d_2024.csv",
    table_name, state_abbr,
    ifelse(table_name == "CAINC1", 1969, first_year)
  )
  con <- unz(zip_path, member)
  read_csv(con, col_types = cols(.default = col_character()), show_col_types = FALSE) |>
    mutate(
      fips = gsub('[ "]+', "", GeoFIPS),
      state_fips = substr(fips, 1, 2),
      county_fips = substr(fips, 3, 5)
    ) |>
    filter(
      nchar(fips) == 5,
      county_fips != "000",
      state_fips %in% names(target_states)
    ) |>
    pivot_longer(
      cols = matches("^[0-9]{4}$"),
      names_to = "year",
      values_to = "value"
    ) |>
    mutate(
      year = as.integer(year),
      value = as_number_raw(value),
      state = unname(target_states[state_fips]),
      county_name = sub(", (CA|FL)$", "", trimws(GeoName))
    ) |>
    filter(year %in% target_years) |>
    transmute(
      state_fips, county_fips, fips, state, county_name, year,
      table_name = TableName,
      line_code = as.integer(LineCode),
      description = trimws(Description),
      unit = Unit,
      value
    )
}

bea_income_raw <- bind_rows(
  read_bea(bea_files[["CAINC1"]], "CAINC1", "CA", 1969),
  read_bea(bea_files[["CAINC1"]], "CAINC1", "FL", 1969)
) |>
  arrange(fips, line_code, year)

bea_gdp_raw <- bind_rows(
  read_bea(bea_files[["CAGDP1"]], "CAGDP1", "CA", 2001),
  read_bea(bea_files[["CAGDP1"]], "CAGDP1", "FL", 2001)
) |>
  arrange(fips, line_code, year)

# ---------------------------------------------------------------------------
# 6. FHFA annual county House Price Index
# ---------------------------------------------------------------------------

fhfa_url <- "https://www.fhfa.gov/hpi/download/annual/hpi_at_county.xlsx"
fhfa_file <- file.path(raw_dir, "fhfa_hpi_at_county.xlsx")
download_once(fhfa_url, fhfa_file)

fhfa_raw <- read_excel(
  fhfa_file,
  skip = 5,
  col_names = c(
    "state_abbr", "county_name", "fips", "year", "annual_hpi_change_pct",
    "hpi", "hpi_1990_base", "hpi_2000_base"
  ),
  col_types = "text"
) |>
  filter(state_abbr %in% unname(target_abbr)) |>
  mutate(
    fips = sprintf("%05d", as.integer(fips)),
    state_fips = substr(fips, 1, 2),
    county_fips = substr(fips, 3, 5),
    state = unname(target_states[state_fips]),
    year = as.integer(year),
    across(
      c(annual_hpi_change_pct, hpi, hpi_1990_base, hpi_2000_base),
      as_number_raw
    )
  ) |>
  filter(year %in% target_years) |>
  select(
    state_fips, county_fips, fips, state, county_name, year,
    annual_hpi_change_pct, hpi, hpi_1990_base, hpi_2000_base
  ) |>
  arrange(fips, year)

# ---------------------------------------------------------------------------
# 7. Zillow county housing-market series
# ---------------------------------------------------------------------------

zillow_urls <- c(
  "median_sale_price" = paste0(
    "https://files.zillowstatic.com/research/public_csvs/median_sale_price/",
    "County_median_sale_price_uc_sfrcondo_month.csv"
  ),
  "zori" = paste0(
    "https://files.zillowstatic.com/research/public_csvs/zori/",
    "County_zori_uc_sfrcondomfr_sm_month.csv"
  )
)
zillow_files <- c(
  "median_sale_price" = file.path(raw_dir, "zillow_county_median_sale_price_monthly.csv"),
  "zori" = file.path(raw_dir, "zillow_county_zori_monthly.csv")
)
Map(download_once, zillow_urls, zillow_files)

read_zillow_county_monthly <- function(path, value_name) {
  dat <- read_csv(
    path,
    col_types = cols(.default = col_character()),
    show_col_types = FALSE
  )
  date_cols <- names(dat)[grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", names(dat))]
  dat |>
    filter(State %in% unname(target_abbr)) |>
    transmute(
      state_fips = sprintf("%02d", as.integer(StateCodeFIPS)),
      county_fips = sprintf("%03d", as.integer(MunicipalCodeFIPS)),
      fips = paste0(state_fips, county_fips),
      state = unname(target_states[state_fips]),
      county_name = RegionName,
      across(all_of(date_cols))
    ) |>
    pivot_longer(
      cols = all_of(date_cols),
      names_to = "observation_date",
      values_to = value_name
    ) |>
    mutate(
      observation_date = as.Date(observation_date),
      year = as.integer(format(observation_date, "%Y")),
      across(all_of(value_name), as_number_raw)
    ) |>
    filter(year %in% target_years) |>
    arrange(fips, observation_date)
}

zillow_sale_price_raw <- read_zillow_county_monthly(
  zillow_files[["median_sale_price"]],
  "zillow_median_sale_price_usd"
)
zillow_zori_raw <- read_zillow_county_monthly(
  zillow_files[["zori"]],
  "zillow_observed_rent_index_usd"
)

summarise_zillow_annual <- function(data, value_name, annual_name, months_name) {
  data |>
    group_by(fips, year) |>
    summarise(
      "{annual_name}" := ifelse(
        any(!is.na(.data[[value_name]])),
        mean(.data[[value_name]], na.rm = TRUE),
        NA_real_
      ),
      "{months_name}" := sum(!is.na(.data[[value_name]])),
      .groups = "drop"
    )
}

zillow_sale_price_panel <- summarise_zillow_annual(
  zillow_sale_price_raw,
  "zillow_median_sale_price_usd",
  "median_home_sale_price_annual_avg_usd",
  "median_home_sale_price_months_observed"
)
zillow_zori_panel <- summarise_zillow_annual(
  zillow_zori_raw,
  "zillow_observed_rent_index_usd",
  "zori_annual_avg_usd",
  "zori_months_observed"
)

# ---------------------------------------------------------------------------
# 8. Eviction Lab county eviction estimates
# ---------------------------------------------------------------------------

eviction_url <- paste0(
  "https://eviction-lab-data-downloads.s3.amazonaws.com/",
  "estimating-eviction-prevalance-across-us/",
  "county_eviction_estimates_2000_2018.csv"
)
eviction_file <- file.path(raw_dir, "eviction_lab_county_estimates_2000_2018.csv")
download_once(eviction_url, eviction_file)

eviction_raw <- read_csv(
  eviction_file,
  col_types = cols(.default = col_character()),
  show_col_types = FALSE
) |>
  transmute(
    state,
    county_name = county,
    state_fips = sprintf("%02d", as.integer(FIPS_state)),
    county_fips = sprintf("%03d", as.integer(substr(FIPS_county, 3, 5))),
    fips = sprintf("%05d", as.integer(FIPS_county)),
    year = as.integer(year),
    eviction_renting_households = as_number_raw(renting_hh),
    eviction_filings_estimate = as_number_raw(filings_estimate),
    eviction_filings_ci_95_low = as_number_raw(filings_ci_95_lower),
    eviction_filings_ci_95_high = as_number_raw(filings_ci_95_upper),
    eviction_filings_court_issued_flag = as_number_raw(ind_filings_court_issued),
    eviction_filings_left_truncated_flag = as_number_raw(ind_filings_court_issued_LT),
    eviction_households_threatened_estimate = as_number_raw(hh_threat_estimate),
    eviction_households_threatened_ci_95_low = as_number_raw(hh_threat_95_lower),
    eviction_households_threatened_ci_95_high = as_number_raw(hh_threat_95_upper),
    eviction_households_threatened_observed_flag = as_number_raw(ind_hht_observed)
  ) |>
  filter(state_fips %in% names(target_states), year %in% target_years) |>
  mutate(
    eviction_filing_rate_per_100_renter_households = if_else(
      eviction_renting_households > 0,
      100 * eviction_filings_estimate / eviction_renting_households,
      NA_real_
    ),
    eviction_households_threatened_rate_per_100_renter_households = if_else(
      eviction_renting_households > 0,
      100 * eviction_households_threatened_estimate /
        eviction_renting_households,
      NA_real_
    )
  ) |>
  arrange(fips, year)

# ---------------------------------------------------------------------------
# 9. Census Gazetteer county land area
# ---------------------------------------------------------------------------

gazetteer_url <- paste0(
  "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/",
  "2024_Gazetteer/2024_Gaz_counties_national.zip"
)
gazetteer_file <- file.path(raw_dir, "census_2024_Gaz_counties_national.zip")
download_once(gazetteer_url, gazetteer_file)
gazetteer_member <- unzip(gazetteer_file, list = TRUE)$Name
gazetteer_member <- gazetteer_member[
  grepl("Gaz_counties_national\\.txt$", gazetteer_member)
][1]

gazetteer_raw <- read_tsv(
  unz(gazetteer_file, gazetteer_member),
  col_types = cols(.default = col_character()),
  show_col_types = FALSE,
  trim_ws = TRUE
) |>
  transmute(
    fips = sprintf("%05d", as.integer(GEOID)),
    state_fips = substr(fips, 1, 2),
    county_name = NAME,
    land_area_sq_miles = as_number_raw(ALAND_SQMI)
  ) |>
  filter(state_fips %in% names(target_states)) |>
  arrange(fips)

# ---------------------------------------------------------------------------
# 10. Selected county ACS 5-year measures distributed through FRED
# ---------------------------------------------------------------------------

fred_county_acs_metrics <- tribble(
  ~metric, ~series_prefix,
  "homeownership_rate_pct", "HOWNRATEACS0",
  "housing_cost_burdened_households_pct", "DP04ACS0",
  "income_inequality_top_bottom_quintile_ratio", "2020RATIO0",
  "high_school_graduate_or_higher_pct_age_18plus", "HC01ESTVC16"
)

fred_county_acs_series <- crossing(
  county_lookup |>
    select(state_fips, county_fips, fips, state, county_name),
  fred_county_acs_metrics
) |>
  mutate(series_id = paste0(series_prefix, fips))

fred_county_acs_files <- file.path(
  raw_dir,
  sprintf(
    "fred_county_acs_batch_%02d.csv",
    seq_len(ceiling(nrow(fred_county_acs_series) / 12))
  )
)

fred_county_acs_batches <- split(
  fred_county_acs_series,
  ceiling(seq_len(nrow(fred_county_acs_series)) / 12)
)
for (i in seq_along(fred_county_acs_batches)) {
  ids <- paste(fred_county_acs_batches[[i]]$series_id, collapse = "%2C")
  download_once(
    paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", ids),
    fred_county_acs_files[i]
  )
}

read_fred_county_acs <- function(path) {
  read_csv(
    path,
    col_types = cols(.default = col_character()),
    show_col_types = FALSE
  ) |>
    rename(observation_date = 1) |>
    pivot_longer(
      cols = -observation_date,
      names_to = "series_id",
      values_to = "value"
    ) |>
    mutate(
      year = as.integer(substr(observation_date, 1, 4)),
      value = as_number_raw(value)
    ) |>
    filter(year %in% target_years) |>
    left_join(
      fred_county_acs_series |>
        select(
          series_id, state_fips, county_fips, fips, state, county_name, metric
        ),
      by = "series_id"
    )
}

fred_county_acs_raw <- bind_rows(
  lapply(fred_county_acs_files, read_fred_county_acs)
) |>
  arrange(fips, metric, year)

fred_county_acs_panel <- fred_county_acs_raw |>
  select(fips, year, metric, value) |>
  pivot_wider(names_from = metric, values_from = value)

# ---------------------------------------------------------------------------
# 11. State policy measures replicated to counties
# ---------------------------------------------------------------------------

minimum_wage_url <- paste0(
  "https://fred.stlouisfed.org/graph/fredgraph.csv?",
  "id=STTMINWGCA%2CSTTMINWGFL"
)
minimum_wage_file <- file.path(raw_dir, "fred_state_minimum_wage_CA_FL.csv")
download_once(minimum_wage_url, minimum_wage_file)

minimum_wage_raw <- read_csv(
  minimum_wage_file,
  col_types = cols(.default = col_character()),
  show_col_types = FALSE
) |>
  rename(observation_date = 1) |>
  pivot_longer(
    cols = -observation_date,
    names_to = "series_id",
    values_to = "state_minimum_wage_usd_per_hour"
  ) |>
  mutate(
    year = as.integer(substr(observation_date, 1, 4)),
    state = recode(
      series_id,
      STTMINWGCA = "California",
      STTMINWGFL = "Florida"
    ),
    state_minimum_wage_usd_per_hour =
      as_number_raw(state_minimum_wage_usd_per_hour)
  ) |>
  filter(year %in% target_years) |>
  arrange(state, year)

medicaid_expansion_raw <- crossing(
  state = unname(target_states),
  year = target_years
) |>
  mutate(
    medicaid_expansion_status = as.integer(
      state == "California" & year >= 2014
    ),
    coding_basis = case_when(
      state == "California" ~
        "ACA expansion effective 2014-01-01; pre-2014 coded 0.",
      state == "Florida" ~
        "No ACA expansion implemented through 2025.",
      TRUE ~ NA_character_
    )
  )

# ---------------------------------------------------------------------------
# 12. BLS Local Area Unemployment Statistics (annual series via FRED)
# ---------------------------------------------------------------------------

bls_endpoint <- "https://api.bls.gov/publicAPI/v2/timeseries/data/"
fred_graph_endpoint <- "https://fred.stlouisfed.org/graph/fredgraph.csv"
bls_metrics <- tibble(
  metric_code = c(3L, 4L, 5L, 6L),
  metric = c(
    "unemployment_rate_pct", "unemployed_people",
    "employed_people", "civilian_labor_force"
  )
)

bls_series <- crossing(
  county_lookup |>
    select(state_fips, county_fips, fips, state, county_name),
  bls_metrics
) |>
  mutate(
    series_id = paste0("LAUCN", fips, sprintf("%010d", metric_code)),
    fred_series_id = paste0(series_id, "A")
  )

# FRED's graph CSV endpoint silently returns at most 12 series per request.
# A first verification run used 25-series requests and retained the returned
# 12-series subsets. Prefer a complete 12-series cache when present; otherwise
# use those retained files and fill 2010-2019 from the complete BLS API cache.
fred_new_files <- file.path(
  raw_dir,
  sprintf("fred_bls_laus12_annual_batch_%02d.csv", seq_len(ceiling(nrow(bls_series) / 12)))
)
fred_old_files <- file.path(
  raw_dir,
  sprintf("fred_bls_laus_annual_batch_%02d.csv", seq_len(ceiling(nrow(bls_series) / 25)))
)

bls_batches <- split(bls_series, ceiling(seq_len(nrow(bls_series)) / 12))
for (i in seq_along(bls_batches)) {
  message("BLS/FRED annual batch ", i, "/", length(bls_batches))
  series_batch <- bls_batches[[i]]
  destination <- fred_new_files[i]
  ids <- paste(series_batch$fred_series_id, collapse = "%2C")
  url <- paste0(fred_graph_endpoint, "?id=", ids)
  download_once(url, destination)
}
fred_files <- fred_new_files

read_fred_laus <- function(path) {
  read_csv(
    path,
    col_types = cols(.default = col_character()),
    show_col_types = FALSE
  ) |>
    rename(observation_date = 1) |>
    pivot_longer(
      cols = -observation_date,
      names_to = "fred_series_id",
      values_to = "value"
    ) |>
    mutate(
      year = as.integer(substr(observation_date, 1, 4)),
      value = as_number_raw(value)
    ) |>
    filter(year %in% target_years) |>
    left_join(
      bls_series |>
        select(
          fred_series_id, series_id, state_fips, county_fips, fips,
          state, county_name, metric
        ),
      by = "fred_series_id"
    ) |>
    mutate(
      access_path = "FRED annual series CSV",
      footnote_codes = ifelse(year == 2025, "G;T", NA_character_),
      footnote_text = ifelse(
        year == 2025,
        paste0(
          "BLS annual estimates for 2025 are 11-month averages excluding October; ",
          "October data were unavailable due to the federal government shutdown. ",
          "Data were subject to revision May 19, 2026."
        ),
        NA_character_
      )
    )
}

fred_laus <- bind_rows(lapply(fred_files, read_fred_laus))

read_cached_bls_api <- function(path) {
  payload <- fromJSON(path, simplifyVector = FALSE)
  bind_rows(lapply(payload$Results$series, function(s) {
    annual <- Filter(function(x) identical(x$period, "M13"), s$data)
    bind_rows(lapply(annual, function(x) {
      footnotes <- x$footnotes
      tibble(
        series_id = s$seriesID,
        year = as.integer(x$year),
        value = as_number_raw(x$value),
        access_path = "BLS public API v2",
        footnote_codes = paste(
          vapply(footnotes, function(z) if (is.null(z$code)) "" else z$code, character(1)),
          collapse = ";"
        ),
        footnote_text = paste(
          vapply(footnotes, function(z) if (is.null(z$text)) "" else z$text, character(1)),
          collapse = " | "
        )
      )
    }))
  })) |>
    left_join(
      bls_series |>
        select(series_id, state_fips, county_fips, fips, state, county_name, metric),
      by = "series_id"
    )
}

historical_api_files <- list.files(
  raw_dir,
  pattern = "^bls_laus_2010_2019_batch_[0-9]+\\.json$",
  full.names = TRUE
)
historical_laus <- bind_rows(lapply(historical_api_files, read_cached_bls_api))

bls_raw <- bind_rows(
  historical_laus |> mutate(source_priority = 1L),
  fred_laus |> mutate(source_priority = 2L)
) |>
  arrange(source_priority) |>
  distinct(fips, year, metric, .keep_all = TRUE) |>
  select(
    state_fips, county_fips, fips, state, county_name, year,
    series_id, metric, value, access_path, footnote_codes, footnote_text
  ) |>
  arrange(fips, metric, year)

# ---------------------------------------------------------------------------
# 13. Build the raw compiled panel (keyed join plus documented derivations)
# ---------------------------------------------------------------------------

panel_key <- crossing(
  county_lookup |>
    select(state_fips, county_fips, fips, state, county_name),
  year = target_years
) |>
  arrange(fips, year)

pep_panel <- pep_raw |>
  select(-state_fips, -county_fips, -state, -county_name)

housing_panel <- housing_raw |>
  select(fips, year, housing_units)

bps_panel <- bps_raw |>
  transmute(
    fips, year,
    permits_one_unit_units = one_unit_units,
    permits_two_unit_units = two_unit_units,
    permits_three_four_unit_units = three_four_unit_units,
    permits_five_plus_unit_units = five_plus_unit_units,
    permits_total_units_authorized = total_units_authorized,
    permits_total_value_authorized = total_value_authorized,
    permits_total_reported_units = total_reported_units
  )

saipe_panel <- saipe_raw |>
  select(
    fips, year,
    poverty_all_estimate, poverty_all_ci_low, poverty_all_ci_high,
    poverty_all_pct, poverty_all_pct_ci_low, poverty_all_pct_ci_high,
    poverty_child_estimate, poverty_child_ci_low, poverty_child_ci_high,
    poverty_child_pct, poverty_child_pct_ci_low, poverty_child_pct_ci_high,
    poverty_age_5_17_estimate, poverty_age_5_17_pct,
    median_household_income, median_household_income_ci_low,
    median_household_income_ci_high
  )

bls_panel <- bls_raw |>
  select(fips, year, metric, value) |>
  pivot_wider(names_from = metric, values_from = value)

income_panel <- bea_income_raw |>
  mutate(variable = recode(
    as.character(line_code),
    `1` = "bea_personal_income_thousands_usd",
    `2` = "bea_population",
    `3` = "bea_per_capita_personal_income_usd"
  )) |>
  select(fips, year, variable, value) |>
  pivot_wider(names_from = variable, values_from = value)

gdp_panel <- bea_gdp_raw |>
  mutate(variable = recode(
    as.character(line_code),
    `1` = "bea_real_gdp_thousands_2017_usd",
    `2` = "bea_real_gdp_quantity_index",
    `3` = "bea_current_gdp_thousands_usd"
  )) |>
  select(fips, year, variable, value) |>
  pivot_wider(names_from = variable, values_from = value)

fhfa_panel <- fhfa_raw |>
  select(fips, year, annual_hpi_change_pct, hpi, hpi_1990_base, hpi_2000_base)

eviction_panel <- eviction_raw |>
  select(
    fips, year,
    eviction_renting_households,
    eviction_filings_estimate,
    eviction_filings_ci_95_low,
    eviction_filings_ci_95_high,
    eviction_filings_court_issued_flag,
    eviction_filings_left_truncated_flag,
    eviction_filing_rate_per_100_renter_households,
    eviction_households_threatened_estimate,
    eviction_households_threatened_ci_95_low,
    eviction_households_threatened_ci_95_high,
    eviction_households_threatened_observed_flag,
    eviction_households_threatened_rate_per_100_renter_households
  )

minimum_wage_panel <- minimum_wage_raw |>
  select(state, year, state_minimum_wage_usd_per_hour)

medicaid_expansion_panel <- medicaid_expansion_raw |>
  select(state, year, medicaid_expansion_status)

compiled_panel <- panel_key |>
  left_join(pep_panel, by = c("fips", "year")) |>
  left_join(housing_panel, by = c("fips", "year")) |>
  left_join(bps_panel, by = c("fips", "year")) |>
  left_join(saipe_panel, by = c("fips", "year")) |>
  left_join(bls_panel, by = c("fips", "year")) |>
  left_join(income_panel, by = c("fips", "year")) |>
  left_join(gdp_panel, by = c("fips", "year")) |>
  left_join(fhfa_panel, by = c("fips", "year")) |>
  left_join(zillow_sale_price_panel, by = c("fips", "year")) |>
  left_join(zillow_zori_panel, by = c("fips", "year")) |>
  left_join(eviction_panel, by = c("fips", "year")) |>
  left_join(
    gazetteer_raw |> select(fips, land_area_sq_miles),
    by = "fips"
  ) |>
  left_join(fred_county_acs_panel, by = c("fips", "year")) |>
  left_join(minimum_wage_panel, by = c("state", "year")) |>
  left_join(medicaid_expansion_panel, by = c("state", "year")) |>
  arrange(fips, year) |>
  group_by(fips) |>
  mutate(
    housing_units_per_capita = if_else(
      population > 0,
      housing_units / population,
      NA_real_
    ),
    population_density_per_sq_mile = if_else(
      land_area_sq_miles > 0,
      population / land_area_sq_miles,
      NA_real_
    ),
    permits_total_units_per_1000_population = if_else(
      population > 0,
      1000 * permits_total_units_authorized / population,
      NA_real_
    ),
    population_growth_rate_pct = if_else(
      year %in% c(2010L, 2020L) | is.na(lag(population)) |
        lag(population) <= 0,
      NA_real_,
      100 * (population / lag(population) - 1)
    ),
    housing_supply_growth_rate_pct = if_else(
      year %in% c(2010L, 2020L) | is.na(lag(housing_units)) |
        lag(housing_units) <= 0,
      NA_real_,
      100 * (housing_units / lag(housing_units) - 1)
    ),
    foreclosure_rate_per_100_mortgages = NA_real_
  ) |>
  ungroup() |>
  mutate(
    state_year_county = paste(state, county_name, year, sep = " | "),
    data_status_note = case_when(
      year == 2025 ~ paste0(
        "2025 is complete only for sources that had published county data by ",
        retrieval_date, "; blanks from lagged sources are not zero."
      ),
      TRUE ~ NA_character_
    ),
    .before = 1
  )

# ---------------------------------------------------------------------------
# 14. Dictionary, source log, assumptions, coverage, and checks
# ---------------------------------------------------------------------------

identifier_vars <- c(
  "state_year_county", "data_status_note", "state_fips", "county_fips",
  "fips", "state", "county_name", "year"
)

variable_dictionary <- tribble(
  ~variable, ~category, ~definition, ~unit, ~source, ~candidate_role,
  "population", "Demographics", "July 1 resident population estimate", "people", "Census PEP", "scale/control",
  "population_change", "Demographics", "Annual population change", "people", "Census PEP", "candidate covariate",
  "births", "Demographics", "Births component of population change", "people", "Census PEP", "candidate covariate",
  "deaths", "Demographics", "Deaths component of population change", "people", "Census PEP", "candidate covariate",
  "natural_change", "Demographics", "Births minus deaths component", "people", "Census PEP", "candidate covariate",
  "international_migration", "Demographics", "International migration component", "people", "Census PEP", "candidate covariate",
  "domestic_migration", "Demographics", "Domestic migration component", "people", "Census PEP", "candidate covariate",
  "net_migration", "Demographics", "Net migration component", "people", "Census PEP", "candidate covariate",
  "group_quarters_population", "Demographics", "Population living in group quarters", "people", "Census PEP", "candidate covariate",
  "birth_rate_per_1000", "Demographics", "Birth rate", "per 1,000 population", "Census PEP", "candidate covariate",
  "death_rate_per_1000", "Demographics", "Death rate", "per 1,000 population", "Census PEP", "candidate covariate",
  "natural_change_rate_per_1000", "Demographics", "Natural change rate", "per 1,000 population", "Census PEP", "candidate covariate",
  "international_migration_rate_per_1000", "Demographics", "International migration rate", "per 1,000 population", "Census PEP", "candidate covariate",
  "domestic_migration_rate_per_1000", "Demographics", "Domestic migration rate", "per 1,000 population", "Census PEP", "candidate covariate",
  "net_migration_rate_per_1000", "Demographics", "Net migration rate", "per 1,000 population", "Census PEP", "candidate covariate",
  "population_growth_rate_pct", "Demographics", "Year-over-year population growth rate; 2010 and the 2020 Census-vintage boundary are suppressed", "percent", "Derived from Census PEP", "candidate covariate",
  "land_area_sq_miles", "Demographics", "2024 Gazetteer land area used as a time-invariant county denominator", "square miles", "Census Gazetteer", "scale/control",
  "population_density_per_sq_mile", "Demographics", "Resident population divided by 2024 Gazetteer land area", "people per square mile", "Derived from Census PEP and Gazetteer", "candidate covariate",
  "housing_units", "Housing supply", "July 1 housing-unit estimate", "housing units", "Census PEP housing estimates", "candidate covariate",
  "housing_units_per_capita", "Housing supply", "Housing units divided by resident population", "housing units per person", "Derived from Census PEP", "candidate covariate",
  "housing_supply_growth_rate_pct", "Housing supply", "Year-over-year housing-unit growth rate; 2010 and the 2020 Census-vintage boundary are suppressed", "percent", "Derived from Census PEP housing estimates", "candidate covariate",
  "permits_one_unit_units", "Housing supply", "One-unit housing units authorized", "housing units", "Census/HUD BPS", "candidate covariate",
  "permits_two_unit_units", "Housing supply", "Units authorized in two-unit structures", "housing units", "Census/HUD BPS", "candidate covariate",
  "permits_three_four_unit_units", "Housing supply", "Units authorized in 3-4 unit structures", "housing units", "Census/HUD BPS", "candidate covariate",
  "permits_five_plus_unit_units", "Housing supply", "Units authorized in 5+ unit structures", "housing units", "Census/HUD BPS", "candidate covariate",
  "permits_total_units_authorized", "Housing supply", "Mechanical sum of published authorized-unit categories", "housing units", "Census/HUD BPS", "candidate covariate",
  "permits_total_units_per_1000_population", "Housing supply", "Authorized housing units per 1,000 residents", "housing units per 1,000 people", "Derived from Census/HUD BPS and Census PEP", "candidate covariate",
  "permits_total_value_authorized", "Housing supply", "Mechanical sum of published construction-value categories", "nominal dollars", "Census/HUD BPS", "candidate covariate",
  "permits_total_reported_units", "Housing supply", "Mechanical sum of published units represented by reporting places", "housing units", "Census/HUD BPS", "coverage/quality",
  "poverty_all_estimate", "Income and poverty", "Estimated people in poverty, all ages", "people", "Census SAIPE", "candidate covariate",
  "poverty_all_ci_low", "Income and poverty", "Lower 90% confidence bound for all-age poverty estimate", "people", "Census SAIPE", "uncertainty",
  "poverty_all_ci_high", "Income and poverty", "Upper 90% confidence bound for all-age poverty estimate", "people", "Census SAIPE", "uncertainty",
  "poverty_all_pct", "Income and poverty", "Estimated all-age poverty percent", "percent", "Census SAIPE", "candidate covariate",
  "poverty_all_pct_ci_low", "Income and poverty", "Lower 90% confidence bound for poverty percent", "percent", "Census SAIPE", "uncertainty",
  "poverty_all_pct_ci_high", "Income and poverty", "Upper 90% confidence bound for poverty percent", "percent", "Census SAIPE", "uncertainty",
  "poverty_child_estimate", "Income and poverty", "Estimated children under 18 in poverty", "people", "Census SAIPE", "candidate covariate",
  "poverty_child_ci_low", "Income and poverty", "Lower 90% confidence bound for child poverty estimate", "people", "Census SAIPE", "uncertainty",
  "poverty_child_ci_high", "Income and poverty", "Upper 90% confidence bound for child poverty estimate", "people", "Census SAIPE", "uncertainty",
  "poverty_child_pct", "Income and poverty", "Estimated child poverty percent", "percent", "Census SAIPE", "candidate covariate",
  "poverty_child_pct_ci_low", "Income and poverty", "Lower 90% confidence bound for child poverty percent", "percent", "Census SAIPE", "uncertainty",
  "poverty_child_pct_ci_high", "Income and poverty", "Upper 90% confidence bound for child poverty percent", "percent", "Census SAIPE", "uncertainty",
  "poverty_age_5_17_estimate", "Income and poverty", "Estimated related children age 5-17 in families in poverty", "people", "Census SAIPE", "candidate covariate",
  "poverty_age_5_17_pct", "Income and poverty", "Estimated poverty percent for related children age 5-17 in families", "percent", "Census SAIPE", "candidate covariate",
  "median_household_income", "Income and poverty", "Estimated median household income", "nominal dollars", "Census SAIPE", "candidate covariate",
  "median_household_income_ci_low", "Income and poverty", "Lower 90% confidence bound for median household income", "nominal dollars", "Census SAIPE", "uncertainty",
  "median_household_income_ci_high", "Income and poverty", "Upper 90% confidence bound for median household income", "nominal dollars", "Census SAIPE", "uncertainty",
  "unemployment_rate_pct", "Labor market", "Annual county unemployment rate", "percent", "BLS LAUS", "candidate covariate",
  "unemployed_people", "Labor market", "Annual unemployed persons estimate", "people", "BLS LAUS", "candidate covariate",
  "employed_people", "Labor market", "Annual employed persons estimate", "people", "BLS LAUS", "candidate covariate",
  "civilian_labor_force", "Labor market", "Annual civilian labor force estimate", "people", "BLS LAUS", "candidate covariate",
  "bea_personal_income_thousands_usd", "Economic output and income", "Personal income", "thousands of nominal dollars", "BEA CAINC1", "candidate covariate",
  "bea_population", "Economic output and income", "Population used by BEA", "people", "BEA CAINC1", "scale/control",
  "bea_per_capita_personal_income_usd", "Economic output and income", "Per capita personal income", "nominal dollars", "BEA CAINC1", "candidate covariate",
  "bea_real_gdp_thousands_2017_usd", "Economic output and income", "Real county GDP", "thousands of chained 2017 dollars", "BEA CAGDP1", "candidate covariate",
  "bea_real_gdp_quantity_index", "Economic output and income", "Real GDP chain-type quantity index", "index", "BEA CAGDP1", "candidate covariate",
  "bea_current_gdp_thousands_usd", "Economic output and income", "Current-dollar county GDP", "thousands of nominal dollars", "BEA CAGDP1", "candidate covariate",
  "annual_hpi_change_pct", "Housing market", "Annual change in developmental county all-transactions HPI", "percent", "FHFA HPI", "candidate covariate",
  "hpi", "Housing market", "Developmental county all-transactions HPI", "index", "FHFA HPI", "candidate covariate",
  "hpi_1990_base", "Housing market", "HPI rebased to 1990", "index, 1990=100", "FHFA HPI", "candidate covariate",
  "hpi_2000_base", "Housing market", "HPI rebased to 2000", "index, 2000=100", "FHFA HPI", "candidate covariate",
  "median_home_sale_price_annual_avg_usd", "Housing market", "Arithmetic mean of Zillow monthly county median sale prices for all homes", "nominal dollars", "Zillow Research", "candidate covariate",
  "median_home_sale_price_months_observed", "Housing market", "Months contributing to the annual average of monthly median sale price", "months", "Zillow Research", "coverage/quality",
  "zori_annual_avg_usd", "Housing market", "Arithmetic mean of monthly Zillow Observed Rent Index values; this is a typical market rent index, not ACS median gross rent", "nominal dollars", "Zillow Research", "candidate covariate",
  "zori_months_observed", "Housing market", "Months contributing to the annual average Zillow Observed Rent Index", "months", "Zillow Research", "coverage/quality",
  "homeownership_rate_pct", "Housing market", "ACS 5-year homeownership rate distributed through FRED", "percent", "Census ACS via FRED", "candidate covariate",
  "housing_cost_burdened_households_pct", "Housing affordability", "Households spending at least 30 percent of income on selected owner costs or gross rent; not a renter-only burden measure", "percent", "Census ACS via FRED", "candidate covariate",
  "foreclosure_rate_per_100_mortgages", "Housing market", "Reserved foreclosure-rate field; blank because no free comparable county-year series for 2010-2025 was verified", "per 100 mortgages", "Not populated", "requested gap",
  "eviction_renting_households", "Eviction", "Estimated renter-occupied households used as the Eviction Lab denominator", "renter households", "Eviction Lab", "scale/control",
  "eviction_filings_estimate", "Eviction", "Modeled annual eviction filing estimate", "filings", "Eviction Lab", "candidate covariate",
  "eviction_filings_ci_95_low", "Eviction", "Lower 95 percent uncertainty bound for modeled eviction filings", "filings", "Eviction Lab", "uncertainty",
  "eviction_filings_ci_95_high", "Eviction", "Upper 95 percent uncertainty bound for modeled eviction filings", "filings", "Eviction Lab", "uncertainty",
  "eviction_filings_court_issued_flag", "Eviction", "Indicator supplied by Eviction Lab for a court-issued filings observation", "0/1 flag", "Eviction Lab", "coverage/quality",
  "eviction_filings_left_truncated_flag", "Eviction", "Indicator supplied by Eviction Lab for left-truncated court-issued filings", "0/1 flag", "Eviction Lab", "coverage/quality",
  "eviction_filing_rate_per_100_renter_households", "Eviction", "Modeled eviction filings divided by renter-occupied households and multiplied by 100", "filings per 100 renter households", "Derived from Eviction Lab", "candidate covariate",
  "eviction_households_threatened_estimate", "Eviction", "Modeled renter households threatened with eviction", "renter households", "Eviction Lab", "candidate covariate",
  "eviction_households_threatened_ci_95_low", "Eviction", "Lower 95 percent uncertainty bound for households threatened", "renter households", "Eviction Lab", "uncertainty",
  "eviction_households_threatened_ci_95_high", "Eviction", "Upper 95 percent uncertainty bound for households threatened", "renter households", "Eviction Lab", "uncertainty",
  "eviction_households_threatened_observed_flag", "Eviction", "Indicator supplied by Eviction Lab for observed households threatened", "0/1 flag", "Eviction Lab", "coverage/quality",
  "eviction_households_threatened_rate_per_100_renter_households", "Eviction", "Modeled households threatened divided by renter-occupied households and multiplied by 100", "households per 100 renter households", "Derived from Eviction Lab", "candidate covariate",
  "income_inequality_top_bottom_quintile_ratio", "Income and poverty", "Mean income of the highest household-income quintile divided by mean income of the lowest quintile; not a Gini coefficient", "ratio", "Census ACS via FRED", "candidate covariate",
  "high_school_graduate_or_higher_pct_age_18plus", "Education", "Population age 18 and older with a high-school diploma or higher; this is attainment, not a cohort graduation rate", "percent", "Census ACS via FRED", "candidate covariate",
  "state_minimum_wage_usd_per_hour", "Policy and safety net", "Published state minimum wage assigned to every county in that state-year", "nominal dollars per hour", "U.S. Department of Labor via FRED", "state-level covariate",
  "medicaid_expansion_status", "Policy and safety net", "ACA Medicaid expansion implemented in the state by that year", "0/1 flag", "CMS/KFF documented coding", "state-level covariate"
) |>
  mutate(
    transformation_status = case_when(
      variable == "foreclosure_rate_per_100_mortgages" ~
        "Reserved blank field; no verified series",
      variable %in% c(
        "housing_units_per_capita", "population_density_per_sq_mile",
        "permits_total_units_per_1000_population",
        "population_growth_rate_pct", "housing_supply_growth_rate_pct",
        "eviction_filing_rate_per_100_renter_households",
        "eviction_households_threatened_rate_per_100_renter_households"
      ) ~ "Mechanical derivation; component fields retained",
      variable %in% c(
        "median_home_sale_price_annual_avg_usd", "zori_annual_avg_usd"
      ) ~ "Arithmetic mean of available monthly values; month count retained",
      variable == "medicaid_expansion_status" ~
        "Deterministic state-year coding from documented implementation status",
      grepl("^permits_total", variable) ~ "Mechanical row sum; components retained",
      TRUE ~ "Published value; reshaped only"
    ),
    cleaning_status = "Uncleaned; missing values retained"
  )

source_log <- tribble(
  ~database, ~producer, ~category, ~geography, ~published_coverage_used,
  ~retrieval_date, ~access_method, ~exact_url_or_pattern, ~raw_files, ~important_limitation,
  "County Population Estimates", "U.S. Census Bureau PEP", "Demographics", "County",
  "2010-2025", as.character(retrieval_date), "Bulk CSV",
  paste(pep_urls, collapse = " | "),
  paste(basename(pep_files), collapse = " | "),
  "2010-2019 and 2020-2025 come from different Census vintages; do not compute a 2020 change across vintages without review.",
  "County Housing Unit Estimates", "U.S. Census Bureau PEP", "Housing supply", "County",
  "2010-2025", as.character(retrieval_date), "Bulk XLSX",
  paste(housing_urls, collapse = " | "),
  paste(basename(housing_files), collapse = " | "),
  "Same Census-vintage boundary as population estimates.",
  "Building Permits Survey", "U.S. Census Bureau and HUD", "Housing supply", "County",
  "2010-2025", as.character(retrieval_date), "Annual bulk text files",
  "https://www2.census.gov/econ/bps/County/coYYYYa.txt",
  "census_bps_co2010a.txt through census_bps_co2025a.txt",
  "Permits are authorizations, not starts or completions; reported-place coverage fields are retained.",
  "Small Area Income and Poverty Estimates", "U.S. Census Bureau", "Income and poverty", "County",
  "2010-2024", as.character(retrieval_date), "Annual bulk XLS workbooks",
  "https://www2.census.gov/programs-surveys/saipe/datasets/YYYY/YYYY-state-and-county/estYYall.xls",
  "census_saipe_est10all.xls through census_saipe_est24all.xls",
  "2025 estimates were not published by retrieval date; 90% confidence bounds are retained.",
  "Local Area Unemployment Statistics", "U.S. Bureau of Labor Statistics", "Labor market", "County",
  "2010-2025 all counties", as.character(retrieval_date), "BLS public API v2 plus annual BLS series distributed through FRED graph CSV",
  paste0(fred_graph_endpoint, "?id=LAUCN[county-series]A"),
  "fred_bls_laus12_annual_batch_*.csv; earlier partial verification files are also preserved",
  "BLS is the producer and FRED is only the distributor. The 2025 annual estimate is an 11-month average excluding October due to the federal shutdown.",
  "CAINC1 County Personal Income", "U.S. Bureau of Economic Analysis", "Economic output and income", "County",
  "2010-2024", as.character(retrieval_date), "Regional bulk ZIP",
  bea_urls[["CAINC1"]], basename(bea_files[["CAINC1"]]),
  "Nominal dollars unless the BEA unit explicitly says chained dollars; 2025 not published in this vintage.",
  "CAGDP1 County GDP", "U.S. Bureau of Economic Analysis", "Economic output and income", "County",
  "2010-2024", as.character(retrieval_date), "Regional bulk ZIP",
  bea_urls[["CAGDP1"]], basename(bea_files[["CAGDP1"]]),
  "Real GDP is in chained 2017 dollars and is not additive across detailed components; 2025 not published in this vintage.",
  "Annual County House Price Index", "Federal Housing Finance Agency", "Housing market", "County",
  "2010-2025 where published", as.character(retrieval_date), "Bulk XLSX",
  fhfa_url, basename(fhfa_file),
  "County indexes are developmental, repeat-sales indexes; they are not median sale prices and some small counties are unavailable.",
  "County Median Sale Price", "Zillow Research", "Housing market", "County",
  "2010-2025 where published", as.character(retrieval_date), "Bulk monthly CSV",
  zillow_urls[["median_sale_price"]],
  basename(zillow_files[["median_sale_price"]]),
  "Monthly median sale prices are summarized as an annual arithmetic mean; this is not a median over all annual transactions. County coverage varies.",
  "Zillow Observed Rent Index", "Zillow Research", "Housing market", "County",
  "2015-2025 where published", as.character(retrieval_date), "Bulk monthly CSV",
  zillow_urls[["zori"]],
  basename(zillow_files[["zori"]]),
  "ZORI is a smoothed typical observed market rent measure and is not ACS median gross rent; county coverage varies.",
  "County Eviction Estimates", "Princeton University Eviction Lab", "Eviction", "County",
  "2010-2018", as.character(retrieval_date), "Public bulk CSV",
  eviction_url, basename(eviction_file),
  "Estimates combine observed and modeled data; uncertainty bounds and source flags are retained. Do not splice these estimates to the post-2020 tracking system.",
  "2024 County Gazetteer", "U.S. Census Bureau", "Demographics", "County",
  "Time-invariant denominator", as.character(retrieval_date), "Bulk ZIP/TXT",
  gazetteer_url, basename(gazetteer_file),
  "2024 land area is applied to every panel year; boundary changes are not modeled.",
  "Selected ACS County Indicators", "U.S. Census Bureau", "Housing affordability; income; education", "County",
  "2009/2010-2024 depending on series", as.character(retrieval_date), "FRED graph CSV batches",
  "https://fred.stlouisfed.org/graph/fredgraph.csv?id=[series IDs]",
  "fred_county_acs_batch_*.csv",
  "ACS 5-year period estimates overlap across adjacent years. Homeownership, burden, inequality ratio, and educational attainment have distinct definitions; none is relabeled as a requested but different measure.",
  "State Minimum Wage", "U.S. Department of Labor Wage and Hour Division", "Policy and safety net", "State replicated to counties",
  "2010-2025", as.character(retrieval_date), "FRED graph CSV",
  minimum_wage_url, basename(minimum_wage_file),
  "A state-level value is repeated for every county in the state-year; it does not capture local minimum-wage ordinances.",
  "ACA Medicaid Expansion Status", "CMS; implementation dates compiled by KFF", "Policy and safety net", "State replicated to counties",
  "2010-2025", as.character(retrieval_date), "Documented state-year coding",
  "https://www.kff.org/affordable-care-act/state-indicator/state-activity-around-expanding-medicaid-under-the-affordable-care-act/",
  "No external raw table; coding is generated in build_county_raw_panel.R",
  "California is coded 1 beginning in 2014; Florida is coded 0 throughout. This is state policy exposure, not county implementation intensity."
)

assumptions <- tribble(
  ~assumption_id, ~topic, ~decision_or_assumption, ~reason, ~modeling_consequence,
  "A01", "Unit of observation", "One county-year; 58 California counties and 67 Florida counties for 2010-2025.", "Matches requested geography and period.", "Expected panel has 2,000 rows.",
  "A02", "Meaning of coefficients", "Interpreted as candidate covariates grouped by substantive category, not fitted regression coefficients.", "No target or model has yet been selected.", "Do not rank variables as effects until a target and validation plan exist.",
  "A03", "Rawness", "Published values are retained alongside a limited set of transparent arithmetic rates, annual averages, and policy codings documented in the dictionary.", "Keeps provenance while making the workbook graphable and immediately usable.", "Further learned cleaning or imputation must occur in a separate derivative file.",
  "A04", "Missing data", "Missing, suppressed, and not-yet-published values remain blank; none are converted to zero.", "A blank is not evidence of no event.", "Coverage must be checked before every chart/model.",
  "A05", "2025", "Rows exist for 2025 even when a lagged source ends in 2024.", "The user requested an inclusive 2010-2025 panel.", "Restrict models to common coverage or use source-aware missingness methods.",
  "A06", "Census vintage boundary", "PEP population/housing use 2019 vintage through 2019 and 2025 vintage from 2020 onward.", "These are the official files spanning the requested period.", "Do not treat the 2019-to-2020 difference as a pure annual change without sensitivity checks.",
  "A07", "SAIPE uncertainty", "SAIPE 90% confidence intervals are retained alongside point estimates.", "County estimates have uncertainty.", "Use uncertainty in interpretation; avoid over-ranking small differences.",
  "A08", "BLS annual measure", "Only M13 annual-average LAUS observations are compiled; monthly records remain in raw API JSON.", "Creates one value per county-year.", "2025 excludes October and needs a chart/model caution.",
  "A09", "Permits", "Total authorized units/value are mechanical sums of the four published structure-size categories.", "The annual county file has components rather than one total column.", "Treat reported-place coverage as a quality field.",
  "A10", "FHFA HPI", "HPI is an index, not a dollar price; unavailable small-county values remain missing.", "Prevents false price interpretation.", "Do not combine it directly with dollar outcomes without defining the transformation.",
  "A11", "BEA measures", "BEA population is retained even though Census PEP population also exists.", "It documents the denominator underlying BEA per-capita income.", "Choose one population definition per model and run a sensitivity check.",
  "A12", "Homelessness outcome", "No county homelessness outcome is inserted in this build.", "HUD PIT data are primarily Continuum-of-Care geography, not a consistent county-year measure.", "A documented CoC-to-county allocation decision is required before county homelessness modeling.",
  "A13", "Causality", "All variables are observational candidate predictors.", "The panel does not identify causal effects by itself.", "Use time controls, county effects, lags, and time-based validation; avoid causal language.",
  "A14", "Leakage", "Same-year measures are not automatically safe predictors.", "Some economic releases are revised and outcomes may be contemporaneous.", "Define the prediction date and lag predictors before predictive modeling.",
  "A15", "Scale", "Raw totals and published rates are both retained; selected population-normalized rates are mechanical derivations.", "Totals preserve source data; rates improve comparability.", "Keep the raw numerator and denominator in any model audit.",
  "A16", "Labor coverage", "BLS annual LAUS measures are retrieved in FRED batches of no more than 12 series and cover all counties and years.", "FRED silently truncates larger graph-CSV requests; the 12-series limit was verified and enforced.", "The 2025 annual estimate remains an 11-month BLS average excluding October.",
  "A17", "Zillow annualization", "Annual Zillow values are arithmetic means of the available monthly county values; month counts are retained.", "The source is monthly and the panel is annual.", "Do not describe the annual sale-price value as a median over all transactions in the year.",
  "A18", "ZORI meaning", "ZORI is retained as a typical observed market-rent index and is not renamed median rent.", "ZORI and ACS median gross rent have different concepts and coverage.", "Do not combine or coalesce ZORI with ACS rent measures.",
  "A19", "Eviction estimates", "Eviction Lab modeled counts, uncertainty bounds, and source flags are retained through 2018.", "The national county series is the only consistent source covering every county in the requested states before 2019.", "Do not append post-2020 tracking data without a comparability study.",
  "A20", "Density denominator", "2024 Gazetteer land area is applied to every county-year.", "A single official land-area denominator permits a consistent density calculation.", "Density changes reflect population changes, not boundary revisions.",
  "A21", "Growth rates", "Population and housing growth are suppressed for 2010 and 2020.", "2010 lacks a prior panel year; 2020 crosses the Census estimate-vintage boundary.", "Do not fill the suppressed growth cells from adjacent years.",
  "A22", "State variables", "Minimum wage and Medicaid expansion status are state-year measures repeated across counties.", "The requested concepts are state policies rather than county measures.", "They contain no within-state cross-county variation and require state-clustered interpretation.",
  "A23", "Medicaid coding", "California is coded expanded beginning in 2014 and Florida is coded not expanded through 2025.", "California implemented ACA expansion on 2014-01-01; Florida had not implemented it by the panel end.", "The binary flag does not measure enrollment, generosity, or county implementation intensity.",
  "A24", "Requested substitutes", "Conceptually different but relevant measures are included only under precise names: ZORI is not median rent, overall housing-cost burden is not renter-only burden, the quintile ratio is not Gini, and high-school attainment is not a graduation rate.", "Prevents definition drift while retaining useful predictors.", "Use requested_variable_status.csv before selecting variables.",
  "A25", "Foreclosure", "The foreclosure-rate field is reserved and blank.", "No free comparable county-year foreclosure-rate series covering 2010-2025 was verified.", "Do not substitute mortgage delinquency or foreclosure starts without renaming and documenting the new concept."
)

requested_variable_status <- tribble(
  ~request_number, ~requested_variable, ~status, ~panel_variable_or_decision, ~source_or_reason,
  1L, "Median rent", "Closest non-equivalent added", "zori_annual_avg_usd", "Zillow ZORI is a typical observed market-rent index, not ACS median gross rent; it remains separately named.",
  2L, "Median home price", "Added with explicit annualization", "median_home_sale_price_annual_avg_usd", "Annual arithmetic mean of Zillow monthly county median sale prices; month coverage is retained.",
  3L, "Rent as % of income / rent burden", "Closest non-equivalent added", "housing_cost_burdened_households_pct", "FRED-distributed ACS measure covers all households with owner or renter costs; it is not renter-only median rent as percent of income.",
  4L, "Rental vacancy rate", "Not added", "", "No key-free, verified county-year series spanning the requested period was available during this build.",
  5L, "Homeownership rate", "Added", "homeownership_rate_pct", "Census ACS 5-year homeownership rate distributed through FRED.",
  6L, "Housing units per capita", "Added derived", "housing_units_per_capita", "Census housing units divided by Census PEP population.",
  7L, "New housing permits issued", "Already present", "permits_total_units_authorized and structure-size components", "Census/HUD Building Permits Survey.",
  8L, "Housing supply growth rate", "Added derived", "housing_supply_growth_rate_pct", "Year-over-year Census housing-unit growth; 2010 and 2020 suppressed.",
  9L, "Eviction filing rate", "Added", "eviction_filing_rate_per_100_renter_households", "Eviction Lab modeled county estimates, 2010-2018.",
  10L, "Foreclosure rate", "Reserved blank", "foreclosure_rate_per_100_mortgages", "No free comparable county-year series for 2010-2025 was verified; delinquency was not substituted.",
  11L, "Unemployment rate", "Already present and coverage completed", "unemployment_rate_pct", "BLS LAUS annual county series distributed through FRED.",
  12L, "Per capita personal income", "Already present", "bea_per_capita_personal_income_usd", "BEA CAINC1.",
  13L, "Median household income", "Already present", "median_household_income", "Census SAIPE.",
  14L, "Poverty rate", "Already present", "poverty_all_pct", "Census SAIPE.",
  15L, "Income inequality / Gini coefficient", "Closest non-equivalent added", "income_inequality_top_bottom_quintile_ratio", "ACS highest-to-lowest income-quintile ratio; it is explicitly not labeled Gini.",
  16L, "Minimum wage", "Added at state-year level", "state_minimum_wage_usd_per_hour", "U.S. Department of Labor series distributed through FRED and repeated across counties.",
  17L, "Cost of living index", "Not added", "", "No comparable annual county index covering all 125 counties was verified; metropolitan RPPs were not assigned to counties.",
  18L, "Labor force participation rate", "Not added", "", "BLS county LAUS lacks the civilian noninstitutional population denominator needed for the standard rate.",
  19L, "Population density", "Added derived", "population_density_per_sq_mile", "Census PEP population divided by 2024 Gazetteer land area.",
  20L, "Population growth rate", "Added derived", "population_growth_rate_pct", "Year-over-year Census PEP population growth; 2010 and 2020 suppressed.",
  21L, "Net migration rate", "Already present", "net_migration_rate_per_1000", "Census PEP.",
  22L, "Percent age 18-24", "Not added", "", "The Census API began requiring a key on 2026-07-09; a key-free complete historical county extract was not available.",
  23L, "Percent age 65+", "Not added", "", "The Census API began requiring a key on 2026-07-09; a key-free complete historical county extract was not available.",
  24L, "Average household size", "Not added", "", "The Census API began requiring a key on 2026-07-09; a key-free complete historical county extract was not available.",
  25L, "Urbanization rate", "Not added", "", "County urban/rural shares are decennial, not a comparable annual county series; values were not interpolated.",
  26L, "Average January temperature", "Not added", "", "A consistent station-to-county aggregation and coverage rule was not established in this raw build.",
  27L, "Days below freezing", "Not added", "", "A consistent station-to-county aggregation and coverage rule was not established in this raw build.",
  28L, "Extreme heat days", "Not added", "", "A consistent station-to-county aggregation and threshold rule was not established in this raw build.",
  29L, "January precipitation", "Not added", "", "A consistent station-to-county aggregation and coverage rule was not established in this raw build.",
  30L, "Cooling degree days", "Not added", "", "A consistent station-to-county aggregation and base-temperature rule was not established in this raw build.",
  31L, "Medicaid expansion status", "Added at state-year level", "medicaid_expansion_status", "California expanded in 2014; Florida remained non-expansion through 2025.",
  32L, "TANF benefit levels", "Not added", "", "A verified annual state series with a stable family-size definition was not acquired.",
  33L, "SSI supplement level", "Not added", "", "State supplements vary by living arrangement and eligibility category; no single comparable annual amount was selected.",
  34L, "Anti-camping ordinance presence / strictness", "Not added", "", "No authoritative annual county coding exists; manual legal coding would require a separate protocol.",
  35L, "Shelter beds per capita", "Not added", "", "HUD HIC beds use Continuum-of-Care geography; no county allocation rule was authorized.",
  36L, "PSH units per capita", "Not added", "", "HUD HIC PSH units use Continuum-of-Care geography; no county allocation rule was authorized.",
  37L, "State homelessness program funding per capita", "Not added", "", "No consistently defined annual state funding series covering both states was verified.",
  38L, "Substance use disorder rate", "Not added", "", "NSDUH small-area estimates are not annual county estimates for all counties.",
  39L, "Serious mental illness rate", "Not added", "", "NSDUH small-area estimates are not annual county estimates for all counties.",
  40L, "Uninsured rate", "Not added", "", "A complete key-free historical ACS county extraction was unavailable after the Census API key change.",
  41L, "High school graduation rate", "Closest non-equivalent added", "high_school_graduate_or_higher_pct_age_18plus", "ACS adult educational attainment is retained under its exact name; it is not a cohort graduation rate.",
  42L, "Average student debt per borrower", "Not added", "", "No public annual county series with consistent borrower coverage was verified.",
  43L, "Average in-state tuition", "Not added", "", "Tuition is institution- or state-level; a county aggregation rule and enrollment weighting scheme were not selected."
)

coverage <- compiled_panel |>
  select(-all_of(identifier_vars)) |>
  summarise(across(
    everything(),
    list(
      nonmissing = ~sum(!is.na(.)),
      missing = ~sum(is.na(.)),
      min_year = ~ifelse(any(!is.na(.)), min(compiled_panel$year[!is.na(.)]), NA_integer_),
      max_year = ~ifelse(any(!is.na(.)), max(compiled_panel$year[!is.na(.)]), NA_integer_)
    )
  )) |>
  pivot_longer(
    everything(),
    names_to = c("variable", ".value"),
    names_pattern = "^(.*)_(nonmissing|missing|min_year|max_year)$"
  ) |>
  left_join(variable_dictionary |> select(variable, category, source), by = "variable") |>
  mutate(coverage_pct = round(100 * nonmissing / nrow(compiled_panel), 1)) |>
  select(category, variable, source, nonmissing, missing, coverage_pct, min_year, max_year) |>
  arrange(category, variable)

validation <- tibble(
  check = c(
    "Compiled row count equals 125 counties x 16 years",
    "Exactly 125 unique counties",
    "California has 58 counties",
    "Florida has 67 counties",
    "Years are exactly 2010 through 2025",
    "County-year key is unique",
    "No population values are negative",
    "No housing-unit values are negative",
    "All SAIPE poverty percentages are between 0 and 100 when observed",
    "All BLS unemployment rates are between 0 and 100 when observed",
    "BLS labor measures cover all 2,000 county-years",
    "2025 rows retained for every county"
  ),
  expected = c(
    "2000", "125", "58", "67", paste(target_years, collapse = ":"), "0",
    "TRUE", "TRUE", "TRUE", "TRUE", "TRUE", "125"
  ),
  observed = c(
    as.character(nrow(compiled_panel)),
    as.character(n_distinct(compiled_panel$fips)),
    as.character(n_distinct(compiled_panel$fips[compiled_panel$state == "California"])),
    as.character(n_distinct(compiled_panel$fips[compiled_panel$state == "Florida"])),
    paste(sort(unique(compiled_panel$year)), collapse = ":"),
    as.character(sum(duplicated(compiled_panel[c("fips", "year")]))),
    as.character(all(compiled_panel$population >= 0, na.rm = TRUE)),
    as.character(all(compiled_panel$housing_units >= 0, na.rm = TRUE)),
    as.character(all(
      compiled_panel$poverty_all_pct >= 0 & compiled_panel$poverty_all_pct <= 100,
      na.rm = TRUE
    )),
    as.character(all(
      compiled_panel$unemployment_rate_pct >= 0 &
        compiled_panel$unemployment_rate_pct <= 100,
      na.rm = TRUE
    )),
    as.character(all(c(
      sum(!is.na(compiled_panel$unemployment_rate_pct)),
      sum(!is.na(compiled_panel$unemployed_people)),
      sum(!is.na(compiled_panel$employed_people)),
      sum(!is.na(compiled_panel$civilian_labor_force))
    ) == 2000L)),
    as.character(sum(compiled_panel$year == 2025))
  )
) |>
  mutate(pass = expected == observed)

validation <- bind_rows(
  validation,
  tibble(
    check = c(
      "2024 Gazetteer land area covers all counties",
      "Homeownership rates are between 0 and 100 when observed",
      "Eviction filing rates are nonnegative when observed",
      "Population growth is suppressed for 2010 and 2020",
      "Housing supply growth is suppressed for 2010 and 2020",
      "Foreclosure rate remains entirely blank pending a verified source",
      "Requested-variable status log contains all 43 requested concepts"
    ),
    expected = c("125", "TRUE", "TRUE", "TRUE", "TRUE", "TRUE", "43"),
    observed = c(
      as.character(n_distinct(gazetteer_raw$fips)),
      as.character(all(
        compiled_panel$homeownership_rate_pct >= 0 &
          compiled_panel$homeownership_rate_pct <= 100,
        na.rm = TRUE
      )),
      as.character(all(
        compiled_panel$eviction_filing_rate_per_100_renter_households >= 0,
        na.rm = TRUE
      )),
      as.character(all(is.na(
        compiled_panel$population_growth_rate_pct[
          compiled_panel$year %in% c(2010L, 2020L)
        ]
      ))),
      as.character(all(is.na(
        compiled_panel$housing_supply_growth_rate_pct[
          compiled_panel$year %in% c(2010L, 2020L)
        ]
      ))),
      as.character(all(is.na(
        compiled_panel$foreclosure_rate_per_100_mortgages
      ))),
      as.character(nrow(requested_variable_status))
    )
  ) |>
    mutate(pass = expected == observed)
)

raw_file_index <- tibble(
  raw_file = list.files(raw_dir, full.names = TRUE, recursive = FALSE)
) |>
  mutate(
    filename = basename(raw_file),
    bytes = file.info(raw_file)$size,
    md5 = unname(tools::md5sum(raw_file)),
    modified_utc = format(file.info(raw_file)$mtime, tz = "UTC", usetz = TRUE)
  ) |>
  select(filename, bytes, md5, modified_utc) |>
  arrange(filename)

readme <- tibble(
  item = c(
    "Purpose", "Unit of observation", "Expected rows", "States", "Years",
    "Raw-data rule", "Missing-data rule", "Primary key", "Modeling warning",
    "Requested-variable audit", "Labor coverage", "Census API constraint",
    "Retrieval date"
  ),
  value = c(
    "Uncleaned, source-preserving county covariate panel for exploratory analysis.",
    "One county-year.",
    "2,000 (125 counties x 16 years).",
    "California (58 counties) and Florida (67 counties).",
    "2010-2025 inclusive.",
    "Published estimates are retained with documented mechanical rates, annual monthly averages, and state-policy codings.",
    "Blank means missing, suppressed, or not published; never assume blank equals zero.",
    "fips + year.",
    "No outcome is selected; categories are candidate covariates, not estimated coefficients.",
    "See Request Status for all 43 requested concepts, exact matches, non-equivalent additions, and unresolved gaps.",
    "BLS annual labor data cover all 2,000 county-years; 2025 is an 11-month average excluding October.",
    "The Census Data API began requiring a key on 2026-07-09. Requested ACS fields not available through verified key-free sources remain unfilled.",
    as.character(retrieval_date)
  )
)

# ---------------------------------------------------------------------------
# 15. Export CSVs and workbook
# ---------------------------------------------------------------------------

write_csv(compiled_panel, file.path(output_dir, "county_year_raw_panel_CA_FL_2010_2025.csv"), na = "")
write_csv(variable_dictionary, file.path(output_dir, "variable_dictionary.csv"), na = "")
write_csv(source_log, file.path(output_dir, "source_log.csv"), na = "")
write_csv(assumptions, file.path(output_dir, "assumptions_log.csv"), na = "")
write_csv(
  requested_variable_status,
  file.path(output_dir, "requested_variable_status.csv"),
  na = ""
)
write_csv(coverage, file.path(output_dir, "coverage_summary.csv"), na = "")
write_csv(validation, file.path(output_dir, "validation_checks.csv"), na = "")
write_csv(raw_file_index, file.path(output_dir, "raw_file_index.csv"), na = "")

workbook_path <- file.path(output_dir, "county_year_raw_panel_CA_FL_2010_2025.xlsx")
wb <- createWorkbook(creator = "WDS Course TA Agent")

sheet_data <- list(
  "README" = readme,
  "County-Year Raw" = compiled_panel,
  "Variable Dictionary" = variable_dictionary,
  "Source Log" = source_log,
  "Assumptions" = assumptions,
  "Request Status" = requested_variable_status,
  "Coverage" = coverage,
  "Validation" = validation,
  "Raw File Index" = raw_file_index,
  "PEP Raw" = pep_raw,
  "Housing Units Raw" = housing_raw,
  "Permits Raw" = bps_raw,
  "SAIPE Raw" = saipe_raw,
  "BLS LAUS Raw" = bls_raw,
  "BEA Income Raw" = bea_income_raw,
  "BEA GDP Raw" = bea_gdp_raw,
  "FHFA HPI Raw" = fhfa_raw,
  "Zillow Sale Raw" = zillow_sale_price_raw,
  "Zillow ZORI Raw" = zillow_zori_raw,
  "Eviction Lab Raw" = eviction_raw,
  "Gazetteer Raw" = gazetteer_raw,
  "ACS FRED Raw" = fred_county_acs_raw,
  "Minimum Wage Raw" = minimum_wage_raw,
  "Medicaid Coding" = medicaid_expansion_raw
)

header_style <- createStyle(
  fgFill = "#1F4E78", fontColour = "#FFFFFF", textDecoration = "bold",
  halign = "center", valign = "center", wrapText = TRUE
)
subtle_style <- createStyle(fgFill = "#D9EAF7")
missing_style <- createStyle(fgFill = "#FFF2CC")
pass_style <- createStyle(fgFill = "#E2F0D9")
fail_style <- createStyle(fgFill = "#F4CCCC")

for (sheet_name in names(sheet_data)) {
  addWorksheet(wb, sheet_name)
  dat <- sheet_data[[sheet_name]]
  writeData(wb, sheet_name, dat, withFilter = nrow(dat) > 1)
  freezePane(wb, sheet_name, firstRow = TRUE)
  addStyle(
    wb, sheet_name, header_style,
    rows = 1, cols = seq_len(ncol(dat)), gridExpand = TRUE
  )
  setColWidths(wb, sheet_name, cols = seq_len(ncol(dat)), widths = "auto")
  wide_cols <- which(nchar(names(dat)) > 20)
  if (length(wide_cols)) {
    setColWidths(wb, sheet_name, cols = wide_cols, widths = pmin(28, nchar(names(dat)[wide_cols]) + 3))
  }
}

setColWidths(wb, "README", cols = 1:2, widths = c(24, 95))
setColWidths(wb, "Variable Dictionary", cols = 1:8, widths = c(36, 24, 70, 24, 28, 24, 38, 32))
setColWidths(wb, "Source Log", cols = 1:ncol(source_log), widths = c(30, 30, 25, 14, 24, 14, 24, 90, 55, 85))
setColWidths(wb, "Assumptions", cols = 1:5, widths = c(12, 25, 85, 70, 75))
setColWidths(wb, "Request Status", cols = 1:5, widths = c(12, 34, 28, 58, 95))
setColWidths(wb, "Raw File Index", cols = 1:4, widths = c(48, 16, 36, 28))

conditionalFormatting(
  wb, "County-Year Raw",
  cols = seq_len(ncol(compiled_panel)),
  rows = 2:(nrow(compiled_panel) + 1),
  type = "blanks",
  style = missing_style
)
conditionalFormatting(
  wb, "Validation", cols = which(names(validation) == "pass"),
  rows = 2:(nrow(validation) + 1),
  rule = "TRUE", style = pass_style
)
conditionalFormatting(
  wb, "Validation", cols = which(names(validation) == "pass"),
  rows = 2:(nrow(validation) + 1),
  rule = "FALSE", style = fail_style
)

saveWorkbook(wb, workbook_path, overwrite = TRUE)

message("Wrote: ", workbook_path)
message("Rows: ", nrow(compiled_panel), "; columns: ", ncol(compiled_panel))
message("Validation checks passed: ", sum(validation$pass), "/", nrow(validation))

if (!all(validation$pass)) {
  print(validation |> filter(!pass))
  stop("One or more validation checks failed.")
}
