#!/usr/bin/env Rscript

# Reproducible state-year housing panel for California and Florida, 2010-2025.
# All downloads are preserved under raw_data/. The final workbook is written
# to housing_metrics_CA_FL_2010_2025.xlsx.

options(timeout = 300)

project_dir <- normalizePath(getwd(), mustWork = TRUE)
if (basename(project_dir) != "Final Project") {
  candidate <- file.path(project_dir, "Final Project")
  if (dir.exists(candidate)) project_dir <- normalizePath(candidate)
}

raw_dir <- file.path(project_dir, "raw_data")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

local_lib <- file.path(project_dir, "_r_libs")
dir.create(local_lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(local_lib, .libPaths()))

required <- c("dplyr", "tidyr", "readr", "readxl", "sf", "openxlsx")
missing_pkgs <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs)) {
  install.packages(missing_pkgs, lib = local_lib, repos = "https://cloud.r-project.org")
}

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(readxl)
  library(sf)
  library(openxlsx)
})

download_once <- function(url, destination) {
  if (!file.exists(destination) || file.info(destination)$size == 0) {
    message("Downloading ", basename(destination))
    download.file(url, destination, mode = "wb", quiet = TRUE)
  }
  destination
}

states <- tibble(
  state = c("California", "Florida"),
  state_fips = c("06", "12"),
  fred_prefix = c("CA", "FL")
)

# ---------------------------------------------------------------------------
# 1. Eviction Lab v2 vector tiles (modeled filing rate; raw Census covariates)
# ---------------------------------------------------------------------------

tile_specs <- tribble(
  ~mode,      ~decade, ~x, ~filename,
  "raw",     "10",    0,  "evictionlab_raw_states_10_x0_y1.pbf",
  "raw",     "10",    1,  "evictionlab_raw_states_10_x1_y1.pbf",
  "modeled", "10",    0,  "evictionlab_modeled_states_10_x0_y1.pbf",
  "modeled", "10",    1,  "evictionlab_modeled_states_10_x1_y1.pbf"
)

for (i in seq_len(nrow(tile_specs))) {
  spec <- tile_specs[i, ]
  url <- sprintf(
    "https://tiles.evictionlab.org/v2/%s/states-%s/2/%s/1.pbf",
    spec$mode, spec$decade, spec$x
  )
  download_once(url, file.path(raw_dir, spec$filename))
}

read_state_tile <- function(mode, fips) {
  tile_x <- ifelse(fips == "06", 0, 1)
  tile_file <- file.path(
    raw_dir,
    sprintf("evictionlab_%s_states_10_x%s_y1.pbf", mode, tile_x)
  )
  sf::st_read(tile_file, layer = "states", quiet = TRUE) |>
    sf::st_drop_geometry() |>
    filter(GEOID == fips)
}

eviction_covariates <- bind_rows(lapply(seq_len(nrow(states)), function(i) {
  state_row <- states[i, ]
  tile <- read_state_tile("raw", state_row$state_fips)
  years <- 2010:2018
  tibble(
    state = state_row$state,
    year = years,
    median_rent_evictionlab = as.numeric(unlist(tile[1, paste0("mgr.", substr(years, 3, 4))], use.names = FALSE)),
    rent_pct_income_evictionlab = as.numeric(unlist(tile[1, paste0("rb.", substr(years, 3, 4))], use.names = FALSE))
  )
}))

eviction_filings <- bind_rows(lapply(seq_len(nrow(states)), function(i) {
  state_row <- states[i, ]
  tile <- read_state_tile("modeled", state_row$state_fips)
  years <- 2010:2018
  tibble(
    state = state_row$state,
    year = years,
    eviction_filing_rate = as.numeric(unlist(tile[1, paste0("efr.", substr(years, 3, 4))], use.names = FALSE))
  )
}))

# ---------------------------------------------------------------------------
# 2. ACS 5-year files, 2019-2024
# ---------------------------------------------------------------------------

acs_tables <- tribble(
  ~table_id, ~value_name,
  "b25064",  "median_rent_acs",
  "b25071",  "rent_pct_income_acs"
)

# The table-based files used below begin in 2021. For 2019-2020, extract the
# same two estimates from the official sequence-by-state summary archives.
# Sequence numbers and start positions are documented in the Census
# ACS_5yr_Seq_Table_Number_Lookup files, which are also preserved in raw_data.
acs_old_specs <- tribble(
  ~year, ~sequence, ~rent_position, ~burden_position,
  2019L, "0114", 60L, 124L,
  2020L, "0120", 60L, 124L
)

for (yr in acs_old_specs$year) {
  lookup_url <- sprintf(
    paste0(
      "https://www2.census.gov/programs-surveys/acs/summary_file/%d/",
      "documentation/user_tools/ACS_5yr_Seq_Table_Number_Lookup.txt"
    ),
    yr
  )
  download_once(
    lookup_url,
    file.path(raw_dir, sprintf("acs5_%d_sequence_table_lookup.txt", yr))
  )
}

acs_old_panel <- bind_rows(lapply(seq_len(nrow(acs_old_specs)), function(i) {
  spec <- acs_old_specs[i, ]
  bind_rows(lapply(seq_len(nrow(states)), function(j) {
    state_row <- states[j, ]
    state_abbr <- ifelse(state_row$state == "California", "ca", "fl")
    archive_name <- sprintf(
      "%d5%s%s000.zip",
      spec$year,
      state_abbr,
      spec$sequence
    )
    archive_url <- sprintf(
      paste0(
        "https://www2.census.gov/programs-surveys/acs/summary_file/%d/data/",
        "5_year_seq_by_state/%s/All_Geographies_Not_Tracts_Block_Groups/%s"
      ),
      spec$year,
      state_row$state,
      archive_name
    )
    archive_file <- download_once(
      archive_url,
      file.path(raw_dir, paste0("acs5_", archive_name))
    )

    archive_index <- unzip(archive_file, list = TRUE)
    estimate_member <- archive_index$Name[
      grepl("^e", archive_index$Name, ignore.case = TRUE)
    ][1]
    extraction_dir <- tempfile("acs_sequence_")
    dir.create(extraction_dir)
    unzip(archive_file, files = estimate_member, exdir = extraction_dir)
    estimate_file <- file.path(extraction_dir, estimate_member)
    sequence_data <- read_csv(
      estimate_file,
      col_names = FALSE,
      col_types = cols(.default = col_character()),
      show_col_types = FALSE
    )

    # LOGRECNO 0000001 is the state summary row in each state archive.
    state_summary <- sequence_data |>
      filter(X6 == "0000001")
    stopifnot(nrow(state_summary) == 1)

    tibble(
      state = state_row$state,
      year = spec$year,
      median_rent_acs =
        as.numeric(state_summary[[spec$rent_position]]),
      rent_pct_income_acs =
        as.numeric(state_summary[[spec$burden_position]])
    )
  }))
}))

acs_values <- list()
for (yr in 2021:2024) {
  for (j in seq_len(nrow(acs_tables))) {
    table_id <- acs_tables$table_id[j]
    value_name <- acs_tables$value_name[j]
    filename <- sprintf("acs5_%s_%s.dat", yr, table_id)
    url <- sprintf(
      paste0("https://www2.census.gov/programs-surveys/acs/summary_file/", yr,
             "/table-based-SF/data/5YRData/acsdt5y", yr, "-", table_id, ".dat")
    )
    source_file <- download_once(url, file.path(raw_dir, filename))
    dat <- read_delim(source_file, delim = "|", show_col_types = FALSE)
    estimate_col <- names(dat)[grepl("_E001$", names(dat))][1]
    extracted <- dat |>
      filter(GEO_ID %in% c("0400000US06", "0400000US12")) |>
      transmute(
        state_fips = sub("0400000US", "", GEO_ID),
        year = yr,
        value = as.numeric(.data[[estimate_col]])
      ) |>
      left_join(states, by = "state_fips") |>
      select(state, year, value)
    names(extracted)[3] <- value_name
    acs_values[[paste(yr, table_id)]] <- extracted
  }
}

acs_panel <- bind_rows(acs_old_panel, bind_rows(acs_values)) |>
  group_by(state, year) |>
  summarise(
    median_rent_acs = first(na.omit(median_rent_acs)),
    rent_pct_income_acs = first(na.omit(rent_pct_income_acs)),
    .groups = "drop"
  )

# ---------------------------------------------------------------------------
# 3. FRED CSV exports (underlying sources: Census HVS and Census/HUD BPS)
# ---------------------------------------------------------------------------

fred_series <- tribble(
  ~series_id, ~state,       ~metric,
  "CAHOWN",   "California", "homeownership_rate",
  "FLHOWN",   "Florida",    "homeownership_rate",
  "CARVAC",   "California", "rental_vacancy_rate",
  "FLRVAC",   "Florida",    "rental_vacancy_rate",
  "CABPPRIV", "California", "permits_monthly",
  "FLBPPRIV", "Florida",    "permits_monthly"
)

fred_long <- bind_rows(lapply(seq_len(nrow(fred_series)), function(i) {
  spec <- fred_series[i, ]
  filename <- paste0("fred_", spec$series_id, ".csv")
  source_file <- download_once(
    paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", spec$series_id),
    file.path(raw_dir, filename)
  )
  dat <- read_csv(source_file, show_col_types = FALSE)
  names(dat) <- c("date", "value")
  dat |>
    mutate(
      date = as.Date(date),
      state = spec$state,
      metric = spec$metric,
      value = as.numeric(value)
    ) |>
    select(state, date, metric, value)
}))

fred_annual_rates <- fred_long |>
  filter(metric != "permits_monthly") |>
  mutate(year = as.integer(format(date, "%Y"))) |>
  filter(year >= 2010, year <= 2025) |>
  select(state, year, metric, value) |>
  pivot_wider(names_from = metric, values_from = value)

permits_annual <- fred_long |>
  filter(metric == "permits_monthly") |>
  mutate(year = as.integer(format(date, "%Y"))) |>
  filter(year >= 2010, year <= 2025) |>
  group_by(state, year) |>
  summarise(new_housing_permits = sum(value, na.rm = TRUE), .groups = "drop")

# ---------------------------------------------------------------------------
# 4. Zillow monthly median sale price; annual value = median of monthly values
# ---------------------------------------------------------------------------

zillow_url <- paste0(
  "https://files.zillowstatic.com/research/public_csvs/median_sale_price/",
  "State_median_sale_price_uc_sfrcondo_sm_month.csv"
)
zillow_file <- download_once(zillow_url, file.path(raw_dir, "zillow_state_median_sale_price_monthly.csv"))
zillow_wide <- read_csv(zillow_file, show_col_types = FALSE)

zillow_annual <- zillow_wide |>
  filter(RegionName %in% states$state) |>
  pivot_longer(
    cols = matches("^20[0-9]{2}-[0-9]{2}-[0-9]{2}$"),
    names_to = "date", values_to = "monthly_median_sale_price"
  ) |>
  mutate(
    date = as.Date(date),
    year = as.integer(format(date, "%Y"))
  ) |>
  filter(year >= 2010, year <= 2025) |>
  group_by(state = RegionName, year) |>
  summarise(
    median_home_price = median(monthly_median_sale_price, na.rm = TRUE),
    home_price_months_available = sum(!is.na(monthly_median_sale_price)),
    .groups = "drop"
  ) |>
  mutate(median_home_price = ifelse(is.nan(median_home_price), NA, median_home_price))

# ---------------------------------------------------------------------------
# 5. Census Population Estimates: housing units and population, 2010-2025
# ---------------------------------------------------------------------------

hu_old_file <- download_once(
  "https://www2.census.gov/programs-surveys/popest/tables/2010-2019/housing/totals/NST-EST2019-ANNHU.xlsx",
  file.path(raw_dir, "census_NST-EST2019-ANNHU.xlsx")
)
pop_old_file <- download_once(
  "https://www2.census.gov/programs-surveys/popest/tables/2010-2019/state/totals/nst-est2019-01.xlsx",
  file.path(raw_dir, "census_nst-est2019-01.xlsx")
)
hu_file <- download_once(
  "https://www2.census.gov/programs-surveys/popest/tables/2020-2025/housing/totals/NST-EST2025-HU.xlsx",
  file.path(raw_dir, "census_NST-EST2025-HU.xlsx")
)
pop_file <- download_once(
  "https://www2.census.gov/programs-surveys/popest/tables/2020-2025/state/totals/NST-EST2025-POP.xlsx",
  file.path(raw_dir, "census_NST-EST2025-POP.xlsx")
)

read_census_state_panel <- function(source_file, value_name, valid_years) {
  raw <- read_excel(source_file, col_names = FALSE)
  header_row <- which(apply(raw, 1, function(z) {
    parsed <- suppressWarnings(as.integer(as.character(z)))
    sum(parsed %in% valid_years, na.rm = TRUE) >= 4
  }))[1]
  parsed_years <- suppressWarnings(as.integer(unlist(raw[header_row, ])))
  year_cols <- which(parsed_years %in% valid_years)
  name_col <- names(raw)[1]

  panel <- raw |>
    slice((header_row + 1):n()) |>
    filter(gsub("^\\.", "", as.character(.data[[name_col]])) %in% states$state) |>
    select(all_of(c(name_col, names(raw)[year_cols])))
  names(panel) <- c("state", as.character(parsed_years[year_cols]))
  panel |>
    mutate(
      state = gsub("^\\.", "", state),
      across(-state, as.numeric)
    ) |>
    pivot_longer(-state, names_to = "year", values_to = value_name) |>
    mutate(year = as.integer(year))
}

hu_panel <- bind_rows(
  read_census_state_panel(hu_old_file, "housing_units", 2010:2019),
  read_census_state_panel(hu_file, "housing_units", 2020:2025)
)

pop_panel <- bind_rows(
  read_census_state_panel(pop_old_file, "population", 2010:2019),
  read_census_state_panel(pop_file, "population", 2020:2025)
) |>
  mutate(
    population = as.numeric(population)
  )

housing_supply <- full_join(hu_panel, pop_panel, by = c("state", "year")) |>
  arrange(state, year) |>
  group_by(state) |>
  mutate(
    housing_units_per_capita = housing_units / population,
    housing_supply_growth_rate = if_else(
      year == 2020L,
      NA_real_,
      100 * (housing_units / lag(housing_units) - 1)
    )
  ) |>
  ungroup()

# ---------------------------------------------------------------------------
# 6. Assemble panel, preserve missing values, and export
# ---------------------------------------------------------------------------

panel <- tidyr::expand_grid(state = states$state, year = 2010:2025) |>
  left_join(eviction_covariates, by = c("state", "year")) |>
  left_join(acs_panel, by = c("state", "year")) |>
  left_join(eviction_filings, by = c("state", "year")) |>
  left_join(fred_annual_rates, by = c("state", "year")) |>
  left_join(permits_annual, by = c("state", "year")) |>
  left_join(zillow_annual, by = c("state", "year")) |>
  left_join(housing_supply, by = c("state", "year")) |>
  mutate(
    state_year = paste(state, year),
    median_rent = coalesce(median_rent_acs, median_rent_evictionlab),
    # These are distinct concepts and must not be coalesced.
    rent_as_pct_income = rent_pct_income_acs,
    rent_burden_share = rent_pct_income_evictionlab,
    foreclosure_rate = NA_real_
  ) |>
  select(
    state_year, state, year,
    median_rent,
    median_home_price,
    rent_as_pct_income,
    rent_burden_share,
    rental_vacancy_rate,
    homeownership_rate,
    housing_units_per_capita,
    new_housing_permits,
    housing_supply_growth_rate,
    eviction_filing_rate,
    foreclosure_rate
  ) |>
  arrange(factor(state, levels = states$state), year)

write_csv(panel, file.path(project_dir, "housing_metrics_CA_FL_2010_2025.csv"), na = "")

coverage <- tribble(
  ~metric, ~definition, ~source, ~coverage_in_workbook, ~important_note,
  "median_rent", "Median gross rent (USD/month)", "Eviction Lab raw v2 tiles (Census covariate); ACS 5-year B25064", "2010-2024", "2011-2015 and 2016-2018 values in the Eviction Lab tile may repeat because covariates are carried between benchmark updates.",
  "median_home_price", "Annual median of Zillow monthly state median sale price (USD)", "Zillow Research", "2010-2025", "This is a sale-price series, not ACS owner-occupied property value.",
  "rent_as_pct_income", "Median gross rent as percent of household income", "ACS 5-year B25071", "2019-2024", "This is a median percentage and must not be combined with the share of cost-burdened renters.",
  "rent_burden_share", "Share of renter households meeting the Eviction Lab rent-burden definition (%)", "Eviction Lab raw v2 tiles (Census covariate)", "2010-2018", "This is a renter-household share, not median gross rent as a percentage of income.",
  "rental_vacancy_rate", "Annual rental vacancy rate (%)", "Census Housing Vacancy Survey via FRED", "2010-2025", "State estimates have sampling uncertainty.",
  "homeownership_rate", "Annual homeownership rate (%)", "Census Housing Vacancy Survey via FRED", "2010-2025", "State estimates have sampling uncertainty.",
  "housing_units_per_capita", "Total housing units divided by resident population", "Census Population Estimates Program", "2010-2025", "Computed ratio; not multiplied by 1,000. Uses 2019 vintage through 2019 and 2025 vintage from 2020 onward.",
  "new_housing_permits", "Sum of monthly private housing units authorized by building permits", "Census/HUD Building Permits Survey via FRED", "2010-2025", "Units authorized, not structures and not completed homes.",
  "housing_supply_growth_rate", "Year-over-year percent change in estimated housing units", "Computed from Census Population Estimates housing units", "2011-2019; 2021-2025", "2010 has no prior year. 2020 is blank to avoid calculating growth across Census vintage boundaries.",
  "eviction_filing_rate", "Modeled eviction filings per 100 renter homes", "Eviction Lab National Eviction Map v2", "2010-2018", "National historical panel ends in 2018; modeled estimates address incomplete court coverage.",
  "foreclosure_rate", "No value populated", "No single open, comparable state-year source identified", "None", "ATTOM/CoreLogic series are generally licensed; mortgage delinquency was not mislabeled as foreclosure."
)

missingness <- panel |>
  summarise(across(median_rent:foreclosure_rate, ~sum(is.na(.)))) |>
  pivot_longer(everything(), names_to = "metric", values_to = "missing_rows") |>
  mutate(total_rows = nrow(panel), available_rows = total_rows - missing_rows)

source_files <- tibble(
  file = basename(list.files(raw_dir, full.names = TRUE)),
  bytes = file.info(list.files(raw_dir, full.names = TRUE))$size,
  downloaded_or_verified = as.character(Sys.Date())
)

wb <- createWorkbook(creator = "WDS Final Project data pipeline")
addWorksheet(wb, "Housing Metrics")
addWorksheet(wb, "Metric Guide")
addWorksheet(wb, "Missingness")
addWorksheet(wb, "Raw File Index")

writeData(wb, "Housing Metrics", panel)
writeData(wb, "Metric Guide", coverage)
writeData(wb, "Missingness", missingness)
writeData(wb, "Raw File Index", source_files)

header_style <- createStyle(
  fontName = "Calibri", fontSize = 11, textDecoration = "bold",
  fgFill = "#F4B183", border = "Bottom", borderColour = "#7F6000",
  halign = "center", valign = "center", wrapText = TRUE
)
id_header_style <- createStyle(
  fontName = "Calibri", fontSize = 11, textDecoration = "bold",
  fgFill = "#D9EAD3", border = "Bottom", borderColour = "#38761D",
  halign = "center", valign = "center", wrapText = TRUE
)
missing_style <- createStyle(fgFill = "#FFF2CC", fontColour = "#7F6000")
currency_style <- createStyle(numFmt = "$#,##0")
percent_style <- createStyle(numFmt = "0.00")
ratio_style <- createStyle(numFmt = "0.0000")
integer_style <- createStyle(numFmt = "#,##0")

addStyle(wb, "Housing Metrics", id_header_style, rows = 1, cols = 1:3, gridExpand = TRUE)
addStyle(wb, "Housing Metrics", header_style, rows = 1, cols = 4:ncol(panel), gridExpand = TRUE)
addStyle(
  wb, "Housing Metrics", currency_style,
  rows = 2:(nrow(panel) + 1),
  cols = match(c("median_rent", "median_home_price"), names(panel)),
  gridExpand = TRUE
)
addStyle(
  wb, "Housing Metrics", percent_style,
  rows = 2:(nrow(panel) + 1),
  cols = match(
    c(
      "rent_as_pct_income", "rent_burden_share",
      "rental_vacancy_rate", "homeownership_rate",
      "housing_supply_growth_rate", "eviction_filing_rate",
      "foreclosure_rate"
    ),
    names(panel)
  ),
  gridExpand = TRUE
)
addStyle(
  wb, "Housing Metrics", ratio_style,
  rows = 2:(nrow(panel) + 1),
  cols = match("housing_units_per_capita", names(panel)),
  gridExpand = TRUE
)
addStyle(
  wb, "Housing Metrics", integer_style,
  rows = 2:(nrow(panel) + 1),
  cols = match("new_housing_permits", names(panel)),
  gridExpand = TRUE
)

for (col_idx in 4:ncol(panel)) {
  missing_rows <- which(is.na(panel[[col_idx]])) + 1
  if (length(missing_rows)) addStyle(wb, "Housing Metrics", missing_style, rows = missing_rows, cols = col_idx)
}

freezePane(wb, "Housing Metrics", firstRow = TRUE, firstCol = TRUE)
addFilter(wb, "Housing Metrics", rows = 1, cols = 1:ncol(panel))
setColWidths(wb, "Housing Metrics", cols = 1, widths = 20)
setColWidths(wb, "Housing Metrics", cols = 2, widths = 12)
setColWidths(wb, "Housing Metrics", cols = 3, widths = 8)
setColWidths(wb, "Housing Metrics", cols = 4:ncol(panel), widths = 19)
setRowHeights(wb, "Housing Metrics", rows = 1, heights = 42)

for (sheet in c("Metric Guide", "Missingness", "Raw File Index")) {
  dims <- dim(get(sheet |> switch(
    "Metric Guide" = "coverage",
    "Missingness" = "missingness",
    "Raw File Index" = "source_files"
  )))
  addStyle(wb, sheet, header_style, rows = 1, cols = 1:dims[2], gridExpand = TRUE)
  freezePane(wb, sheet, firstRow = TRUE)
  setColWidths(wb, sheet, cols = 1:dims[2], widths = "auto")
}
setColWidths(wb, "Metric Guide", cols = 2:5, widths = c(34, 38, 22, 70))

saveWorkbook(
  wb,
  file.path(project_dir, "housing_metrics_CA_FL_2010_2025.xlsx"),
  overwrite = TRUE
)

message("Created workbook and CSV in: ", project_dir)
message("Rows: ", nrow(panel), "; columns: ", ncol(panel))
