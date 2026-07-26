options(stringsAsFactors = FALSE)

project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) {
  .libPaths(c(local_r_lib, .libPaths()))
}

required_packages <- c("dplyr", "readxl", "openxlsx")
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

candidate_file <- file.path(
  project_root, "coc_analysis", "lasso_next_year_candidate_panel.csv"
)
state_file <- file.path(project_root, "DSA Group 10 - Sheet1.csv")
hic_file <- file.path(
  project_root, "raw_data", "2007-2025-HIC-Counts-by-CoC.xlsx"
)
output_dir <- file.path(project_root, "outputs", "lasso_model")
output_file <- file.path(
  output_dir, "CA_FL_LASSO_MODEL_INPUT.xlsx"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

required_files <- c(candidate_file, state_file, hic_file)
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

read_hic_year <- function(year) {
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
    "total year round beds es",
    "total year round es beds"
  ))[1]
  th_column <- which(normalized %in% c(
    "total year round beds th",
    "total year round th beds"
  ))[1]
  sh_column <- which(normalized %in% c(
    "total year round beds sh",
    "total year round sh beds"
  ))[1]
  psh_column <- which(
    normalized %in% c(
      "total year round beds psh",
      "total year round psh beds"
    )
  )[1]
  if (
    is.na(es_column) || is.na(th_column) ||
      is.na(sh_column) || is.na(psh_column)
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

hic_panel <- bind_rows(lapply(2010:2024, read_hic_year))
if (anyDuplicated(hic_panel[c("coc_number", "predictor_year")])) {
  stop("The HIC CoC-year key is not unique.")
}

candidates <- read.csv(candidate_file, check.names = FALSE)
state_panel <- read.csv(state_file, check.names = FALSE)

state_predictors <- state_panel |>
  transmute(
    state,
    predictor_year = year,
    state_homeless_funding_per_capita,
    state_anticamping_strictness = anticamping_strictness,
    state_tanf_max_benefit_3person = tanf_max_benefit_3person,
    state_ssi_state_supplement = ssi_state_supplement,
    state_labor_force_participation = labor_force_participation,
    state_substance_use_disorder_rate = substance_use_disorder_rate,
    state_serious_mental_illness_rate = serious_mental_illness_rate,
    state_uninsured_rate = uninsured_rate,
    state_average_student_debt_per_borrower =
      average_student_debt_per_borrower,
    state_avg_in_state_tuition = avg_in_state_tuition,
    state_pct_age_18_24 = pct_age_18_24,
    state_pct_age_65plus = pct_age_65plus,
    state_avg_household_size = avg_household_size,
    state_real_median_rent_2025_usd = real_median_rent_2025_usd,
    state_real_median_home_price_2025_usd =
      real_median_home_price_2025_usd,
    state_home_price_to_income_ratio = home_price_to_income_ratio,
    state_rental_vacancy_rate = rental_vacancy_rate,
    state_real_home_price_growth_pct = real_home_price_growth_pct
  )

expanded <- candidates |>
  left_join(
    hic_panel,
    by = c("coc_number", "predictor_year")
  ) |>
  left_join(
    state_predictors,
    by = c("state", "predictor_year")
  ) |>
  mutate(
    control_state_florida = as.integer(state == "Florida"),
    control_time_index = predictor_year - 2010L,
    coc_group_quarters_per_1000_residents =
      1000 * group_quarters_population / estimated_coc_population,
    coc_hic_temporary_beds_per_10k =
      10000 * hic_temporary_beds / estimated_coc_population,
    coc_hic_psh_beds_per_10k =
      10000 * hic_psh_beds / estimated_coc_population
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
    state_real_minimum_wage_2025_usd =
      real_state_minimum_wage_2025_usd,
    state_medicaid_expansion = medicaid_expansion_status,
    coc_hic_temporary_beds_per_10k,
    coc_hic_psh_beds_per_10k,
    state_homeless_funding_per_capita,
    state_anticamping_strictness,
    state_tanf_max_benefit_3person,
    state_ssi_state_supplement,
    state_labor_force_participation,
    state_substance_use_disorder_rate,
    state_serious_mental_illness_rate,
    state_uninsured_rate,
    state_average_student_debt_per_borrower,
    state_avg_in_state_tuition,
    state_pct_age_18_24,
    state_pct_age_65plus,
    state_avg_household_size,
    state_real_median_rent_2025_usd,
    state_real_median_home_price_2025_usd,
    state_home_price_to_income_ratio,
    state_rental_vacancy_rate,
    state_real_home_price_growth_pct
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

model_data <- expanded |>
  filter(if_all(all_of(model_fields), ~ !is.na(.x))) |>
  arrange(state, coc_number, predictor_year)

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
validation <- data.frame(
  check = c(
    "The CoC and predictor-year key is unique",
    "Every outcome is exactly one year after its predictors",
    "The disrupted 2021 PIT target is excluded",
    "The one-sheet model input has no missing values",
    "The target has positive variation",
    "Every control and predictor has variation",
    "No prohibited leakage field is present",
    "Both California and Florida are represented",
    "Official HIC capacity rates are nonnegative",
    "The expanded model includes 49 controls and predictors"
  ),
  pass = c(
    !anyDuplicated(model_key),
    all(model_data$target_year == model_data$predictor_year + 1),
    !any(model_data$target_year == 2021),
    !anyNA(model_data),
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
    length(c(control_columns, predictor_columns)) == 49
  ),
  stringsAsFactors = FALSE
)

if (!all(validation$pass)) {
  stop(
    "Expanded model-input validation failed:\n",
    paste(validation$check[!validation$pass], collapse = "\n")
  )
}

wb <- createWorkbook(creator = "California–Florida Homelessness Project")
addWorksheet(
  wb, "LASSO Model Data",
  gridLines = FALSE, zoom = 80
)
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
year_style <- createStyle(numFmt = "0")
integer_style <- createStyle(numFmt = "#,##0")
decimal_style <- createStyle(numFmt = "0.00")
currency_style <- createStyle(numFmt = "$#,##0")
currency_two_style <- createStyle(numFmt = "$#,##0.00")

id_indices <- match(id_columns, names(model_data))
target_index <- match(target_column, names(model_data))
control_indices <- match(control_columns, names(model_data))
predictor_indices <- match(predictor_columns, names(model_data))

addStyle(
  wb, "LASSO Model Data", id_header_style,
  rows = 1, cols = id_indices, gridExpand = TRUE
)
addStyle(
  wb, "LASSO Model Data", target_header_style,
  rows = 1, cols = target_index, gridExpand = TRUE
)
addStyle(
  wb, "LASSO Model Data", control_header_style,
  rows = 1, cols = control_indices, gridExpand = TRUE
)
addStyle(
  wb, "LASSO Model Data", predictor_header_style,
  rows = 1, cols = predictor_indices, gridExpand = TRUE
)

data_rows <- 2:(nrow(model_data) + 1)
headers <- names(model_data)
year_indices <- which(grepl("(^predictor_year$|^target_year$|time_index$)", headers))
currency_indices <- which(grepl(
  "usd|funding_per_capita|tanf|max_benefit|supplement|student_debt|tuition",
  headers,
  ignore.case = TRUE
))
currency_two_indices <- match(
  c(
    "state_homeless_funding_per_capita",
    "state_real_minimum_wage_2025_usd"
  ),
  headers
)
decimal_indices <- which(grepl(
  paste(
    "rate|pct|ratio|per_10|per_100|per_1000|density|growth|income|population",
    "participation|household_size",
    sep = "|"
  ),
  headers,
  ignore.case = TRUE
))
numeric_indices <- which(vapply(model_data, is.numeric, logical(1)))
integer_indices <- setdiff(
  numeric_indices,
  union(year_indices, union(currency_indices, decimal_indices))
)

if (length(integer_indices) > 0) {
  addStyle(
    wb, "LASSO Model Data", integer_style,
    rows = data_rows, cols = integer_indices,
    gridExpand = TRUE, stack = TRUE
  )
}
if (length(decimal_indices) > 0) {
  addStyle(
    wb, "LASSO Model Data", decimal_style,
    rows = data_rows, cols = decimal_indices,
    gridExpand = TRUE, stack = TRUE
  )
}
if (length(currency_indices) > 0) {
  addStyle(
    wb, "LASSO Model Data", currency_style,
    rows = data_rows, cols = currency_indices,
    gridExpand = TRUE, stack = TRUE
  )
}
addStyle(
  wb, "LASSO Model Data", currency_two_style,
  rows = data_rows, cols = currency_two_indices,
  gridExpand = TRUE, stack = TRUE
)
if (length(year_indices) > 0) {
  addStyle(
    wb, "LASSO Model Data", year_style,
    rows = data_rows, cols = year_indices,
    gridExpand = TRUE, stack = TRUE
  )
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
setColWidths(
  wb, "LASSO Model Data",
  cols = target_index, widths = 21
)
freezePane(
  wb, "LASSO Model Data",
  firstActiveRow = 2, firstActiveCol = 8
)
addFilter(
  wb, "LASSO Model Data",
  rows = 1, cols = 1:ncol(model_data)
)
pageSetup(
  wb, "LASSO Model Data",
  orientation = "landscape", fitToWidth = 3, fitToHeight = 0
)

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
  } else if (variable %in% c(
    "state_real_minimum_wage_2025_usd",
    "state_medicaid_expansion",
    "state_real_median_rent_2025_usd",
    "state_real_median_home_price_2025_usd",
    "state_home_price_to_income_ratio",
    "state_rental_vacancy_rate",
    "state_real_home_price_growth_pct"
  )) {
    paste(
      "ROLE: candidate predictor.",
      "SOURCE: documented or reproducibly derived state-year project series."
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
  "Built one-sheet LASSO input with ", nrow(model_data), " rows, ",
  ncol(model_data), " total columns, and ",
  length(c(control_columns, predictor_columns)),
  " controls/predictors; all ", nrow(validation), " checks passed."
)
