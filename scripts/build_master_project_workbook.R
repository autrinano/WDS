options(stringsAsFactors = FALSE)

project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) {
  .libPaths(c(local_r_lib, .libPaths()))
}

if (!requireNamespace("openxlsx", quietly = TRUE)) {
  stop("The folder-local openxlsx package is required.")
}
library(openxlsx)

output_dir <- file.path(project_root, "outputs", "homelessness_master")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_file <- file.path(
  output_dir,
  "FINAL_CA_FL_HOMELESSNESS_MODEL_DATA.xlsx"
)

source_specs <- data.frame(
  sheet = c(
    "State Year Team", "Housing Metrics",
    "Clean Full", "Clean Core", "Clean Eviction", "Clean Rent Burden",
    "Clean Rent Cost", "Clean Rent Income", "Cleaning Audit",
    "Clean Validation",
    "CoC Predictors", "CoC Outcomes", "County CoC Crosswalk",
    "CoC Coverage", "CoC LASSO Core Source", "CoC LASSO Candidates",
    "CoC Raw File Index", "CoC Source Notes", "CoC Validation",
    "CoC Variable Dictionary",
    "County Assumptions", "County Year Raw", "County Coverage",
    "County Raw File Index", "County Requested Variables",
    "County Source Log", "County Validation", "County Variable Dictionary",
    "Pairwise Sample Sizes", "Within State Correlations",
    "Factor Associations", "Category Associations", "Chart Manifest",
    "Key Chart Manifest", "Scatter Exclusions", "Scatter Inventory"
  ),
  source_file = c(
    "DSA Group 10 - Sheet1.csv",
    "housing_metrics_CA_FL_2010_2025.csv",
    "cleaned_data/analysis_panel_clean_full.csv",
    "cleaned_data/analysis_panel_core.csv",
    "cleaned_data/analysis_panel_eviction_2010_2018.csv",
    "cleaned_data/analysis_panel_rent_burden.csv",
    "cleaned_data/analysis_panel_rent_cost.csv",
    "cleaned_data/analysis_panel_rent_income.csv",
    "cleaned_data/cleaning_audit.csv",
    "cleaned_data/validation_checks.csv",
    "coc_analysis/coc_year_allocated_predictors_CA_FL_2010_2025.csv",
    "coc_analysis/coc_year_homelessness_outcomes_CA_FL_2010_2025.csv",
    "coc_analysis/county_to_coc_population_crosswalk_FY2024.csv",
    "coc_analysis/coverage_summary.csv",
    "coc_analysis/lasso_core_complete_panel.csv",
    "coc_analysis/lasso_next_year_candidate_panel.csv",
    "coc_analysis/raw_file_index.csv",
    "coc_analysis/source_notes.csv",
    "coc_analysis/validation_checks.csv",
    "coc_analysis/variable_dictionary.csv",
    "county_raw_panel/assumptions_log.csv",
    "county_raw_panel/county_year_raw_panel_CA_FL_2010_2025.csv",
    "county_raw_panel/coverage_summary.csv",
    "county_raw_panel/raw_file_index.csv",
    "county_raw_panel/requested_variable_status.csv",
    "county_raw_panel/source_log.csv",
    "county_raw_panel/validation_checks.csv",
    "county_raw_panel/variable_dictionary.csv",
    "charts/04_relationships/selected_pairwise_sample_sizes.csv",
    "charts/04_relationships/selected_within_state_correlations.csv",
    "charts/all_factor_associations.csv",
    "charts/category_association_summary.csv",
    "charts/chart_manifest.csv",
    "charts/key_chart_manifest.csv",
    "charts/scatterplot_exclusions.csv",
    "charts/scatterplot_inventory.csv"
  ),
  role = c(
    "Integrated state-year panel", "Processed housing state-year panel",
    "Cleaned state-year panel", "Core state-year analysis panel",
    "Eviction analysis panel", "Rent-burden analysis panel",
    "Rent-cost analysis panel", "Rent-to-income analysis panel",
    "Cleaning audit", "Cleaning validation",
    "Allocated CoC predictors", "Observed CoC homelessness outcomes",
    "County-to-CoC allocation crosswalk", "CoC coverage audit",
    "Source complete-case LASSO panel", "Broad LASSO candidate panel",
    "CoC raw-source index", "CoC source notes", "CoC validation",
    "CoC variable definitions",
    "County-panel assumptions", "County-year predictor panel",
    "County coverage audit", "County raw-source index",
    "Requested-variable status", "County source notes",
    "County validation", "County variable definitions",
    "Chart sample-size audit", "Within-state correlations",
    "Factor associations", "Association category summary",
    "Chart file index", "Key-chart index", "Scatterplot exclusions",
    "Scatterplot inventory"
  ),
  grain = c(
    "state-year", "state-year",
    "state-year", "state-year", "state-year", "state-year",
    "state-year", "state-year", "variable", "check",
    "CoC-year", "CoC-year", "county-CoC", "variable",
    "CoC-year", "CoC-year", "file", "source", "check", "variable",
    "assumption", "county-year", "variable", "file", "variable",
    "source", "check", "variable",
    "variable-pair", "variable-state", "variable", "category",
    "chart", "chart", "variable", "variable"
  ),
  stringsAsFactors = FALSE
)

if (any(nchar(source_specs$sheet) > 31) || anyDuplicated(source_specs$sheet)) {
  stop("Worksheet names must be unique and no longer than 31 characters.")
}

missing_sources <- source_specs$source_file[
  !file.exists(file.path(project_root, source_specs$source_file))
]
if (length(missing_sources) > 0) {
  stop(
    "Missing source CSV files:\n",
    paste(missing_sources, collapse = "\n")
  )
}

read_project_csv <- function(relative_path) {
  path <- file.path(project_root, relative_path)
  header <- names(read.csv(path, check.names = FALSE, nrows = 0))
  column_classes <- rep(NA_character_, length(header))
  identifier_columns <- grepl(
    "(^|_)(fips|coc_number|state_abbr|state_year|state_year_county|coc_year)$",
    header,
    ignore.case = TRUE
  )
  column_classes[identifier_columns] <- "character"
  read.csv(
    path,
    check.names = FALSE,
    colClasses = column_classes,
    na.strings = c("", "NA"),
    encoding = "UTF-8"
  )
}

source_data <- setNames(
  lapply(source_specs$source_file, read_project_csv),
  source_specs$sheet
)

core_source <- source_data[["CoC LASSO Core Source"]]
id_columns <- c(
  "state", "state_abbr", "coc_number", "coc_name",
  "predictor_year", "target_year"
)
target_column <- "target_homeless_rate_per_10k"
approved_predictors <- c(
  "state_florida",
  "time_index",
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
model_columns <- c(id_columns, target_column, approved_predictors)
missing_model_columns <- setdiff(model_columns, names(core_source))
if (length(missing_model_columns) > 0) {
  stop(
    "The core source panel is missing model fields: ",
    paste(missing_model_columns, collapse = ", ")
  )
}
model_data <- core_source[model_columns]

model_definitions <- c(
  state = "State name; identifier only and excluded from the design matrix.",
  state_abbr = "Two-letter state abbreviation; identifier only.",
  coc_number = "HUD Continuum of Care identifier; grouping key only.",
  coc_name = "HUD Continuum of Care name; identifier only.",
  predictor_year = "Year in which predictors are measured; used for temporal validation.",
  target_year = "Following year in which the PIT homelessness target is measured.",
  target_homeless_rate_per_10k =
    "Next-year HUD PIT total homelessness per 10,000 estimated CoC residents.",
  state_florida = "Binary state indicator: Florida = 1 and California = 0.",
  time_index = "Predictor year minus 2010; linear time-trend control.",
  log_estimated_coc_population =
    "Natural log of one plus estimated CoC population.",
  population_density_per_sq_mile_derived =
    "Estimated CoC population divided by CoC land area in square miles.",
  housing_units_per_1000_residents =
    "Allocated housing units per 1,000 estimated CoC residents.",
  permits_per_1000_housing_units =
    "Allocated permitted housing units per 1,000 existing housing units.",
  multifamily_permit_share_pct =
    "Five-plus-unit permits as a percentage of total authorized units.",
  net_migration_rate_per_1000 =
    "Allocated annual net migration per 1,000 residents.",
  poverty_all_pct = "Estimated share of people in poverty, in percentage points.",
  real_median_household_income_2025_usd =
    "Median household income expressed in 2025 dollars.",
  homeownership_rate_pct = "Homeownership rate, in percentage points.",
  housing_cost_burdened_households_pct =
    "Share of households with housing-cost burden, in percentage points.",
  income_inequality_top_bottom_quintile_ratio =
    "Ratio of aggregate income in the top income quintile to the bottom quintile.",
  annual_hpi_change_pct =
    "Annual change in the FHFA house-price index, in percentage points.",
  real_gdp_per_capita_2017_usd =
    "Real GDP per person in chained 2017 dollars.",
  real_state_minimum_wage_2025_usd =
    "State minimum wage expressed in 2025 dollars per hour.",
  medicaid_expansion_status =
    "Binary indicator for whether Medicaid expansion was in effect."
)

model_units <- c(
  state = "text", state_abbr = "text", coc_number = "text",
  coc_name = "text", predictor_year = "year", target_year = "year",
  target_homeless_rate_per_10k = "people per 10,000 residents",
  state_florida = "0/1", time_index = "years since 2010",
  log_estimated_coc_population = "log residents",
  population_density_per_sq_mile_derived = "residents per square mile",
  housing_units_per_1000_residents = "units per 1,000 residents",
  permits_per_1000_housing_units = "permits per 1,000 housing units",
  multifamily_permit_share_pct = "percentage points",
  net_migration_rate_per_1000 = "people per 1,000 residents",
  poverty_all_pct = "percentage points",
  real_median_household_income_2025_usd = "2025 dollars",
  homeownership_rate_pct = "percentage points",
  housing_cost_burdened_households_pct = "percentage points",
  income_inequality_top_bottom_quintile_ratio = "ratio",
  annual_hpi_change_pct = "percentage points",
  real_gdp_per_capita_2017_usd = "2017 dollars per person",
  real_state_minimum_wage_2025_usd = "2025 dollars per hour",
  medicaid_expansion_status = "0/1"
)

model_dictionary <- data.frame(
  variable = model_columns,
  role = c(
    rep("identifier / validation", length(id_columns)),
    "outcome",
    rep("predictor", length(approved_predictors))
  ),
  include_in_lasso_design_matrix = c(
    rep(FALSE, length(id_columns)),
    FALSE,
    rep(TRUE, length(approved_predictors))
  ),
  definition = unname(model_definitions[model_columns]),
  unit = unname(model_units[model_columns]),
  stringsAsFactors = FALSE
)

prohibited_leakage_columns <- c(
  "target_total_homeless",
  "target_estimated_coc_population",
  "target_definition",
  "target_pit_count_caution_flag"
)
model_key <- paste(model_data$coc_number, model_data$predictor_year, sep = "|")
master_validation <- data.frame(
  check = c(
    "Model Data row count matches the complete-case CoC source panel",
    "Model Data contains only identifiers, one target, and approved predictors",
    "No prohibited future-year audit fields appear in Model Data",
    "The CoC and predictor-year key is unique",
    "Every target year is exactly one year after its predictor year",
    "The disrupted 2021 PIT year is excluded as a target",
    "The outcome has no missing values",
    "All approved predictors have no missing values",
    "Both California and Florida are represented",
    "All 36 processed/support CSV files were loaded"
  ),
  pass = c(
    nrow(model_data) == nrow(core_source),
    identical(names(model_data), model_columns),
    length(intersect(names(model_data), prohibited_leakage_columns)) == 0,
    !anyDuplicated(model_key),
    all(model_data$target_year == model_data$predictor_year + 1),
    !any(model_data$target_year == 2021),
    !anyNA(model_data[[target_column]]),
    !anyNA(model_data[approved_predictors]),
    identical(sort(unique(model_data$state)), c("California", "Florida")),
    length(source_data) == 36
  ),
  details = c(
    paste(nrow(model_data), "rows in both tables"),
    paste(length(model_columns), "columns:", length(id_columns),
          "identifiers, 1 target, and", length(approved_predictors), "predictors"),
    "Target counts, future denominators, target flags, and narrative fields are excluded",
    paste(length(unique(model_key)), "unique CoC-predictor-year rows"),
    paste(min(model_data$target_year), "through", max(model_data$target_year)),
    "2021 does not appear in target_year",
    paste(sum(!is.na(model_data[[target_column]])), "observed outcomes"),
    paste(length(approved_predictors), "complete predictor columns"),
    paste(table(model_data$state), collapse = "; "),
    paste(length(source_data), "source sheets loaded")
  ),
  stringsAsFactors = FALSE
)

source_index <- data.frame(
  sheet = source_specs$sheet,
  source_file = source_specs$source_file,
  role = source_specs$role,
  grain = source_specs$grain,
  rows = vapply(source_data, nrow, integer(1)),
  columns = vapply(source_data, ncol, integer(1)),
  notes = ifelse(
    grepl("Raw File Index", source_specs$sheet),
    "Inventory only; the underlying raw downloads remain preserved in their source folders.",
    "Imported without changing source values."
  ),
  stringsAsFactors = FALSE
)

workbook_index <- rbind(
  data.frame(
    sheet = c(
      "README", "Workbook Index", "Model Data",
      "Model Dictionary", "Master Validation"
    ),
    source_file = c(
      "Generated", "Generated", "Derived from CoC LASSO Core Source",
      "Generated", "Generated"
    ),
    role = c(
      "Workbook guide", "Sheet inventory", "Only model-input table",
      "Model field definitions", "Master build checks"
    ),
    grain = c("item", "sheet", "CoC-year", "variable", "check"),
    rows = c(
      NA_integer_, NA_integer_, nrow(model_data),
      nrow(model_dictionary), nrow(master_validation)
    ),
    columns = c(
      2L, 7L, ncol(model_data),
      ncol(model_dictionary), ncol(master_validation)
    ),
    notes = c(
      "Start here.",
      "Lists every sheet and its source.",
      "The LASSO script should read this sheet only.",
      "Only fields marked TRUE enter the design matrix.",
      "All checks must be TRUE."
    ),
    stringsAsFactors = FALSE
  ),
  source_index
)

readme <- data.frame(
  Item = c(
    "Purpose",
    "Model input",
    "Outcome",
    "Prediction timing",
    "Model-data rows",
    "Model-data predictors",
    "Identifiers",
    "Leakage prevention",
    "Validation strategy",
    "2021 treatment",
    "Other worksheets",
    "Raw downloads",
    "Missing values",
    "Rebuild script"
  ),
  Value = c(
    "One consolidated workbook for the California–Florida homelessness project.",
    "The model should read only the sheet named Model Data.",
    "target_homeless_rate_per_10k: next-year HUD PIT homelessness per 10,000 estimated CoC residents.",
    "Predictors from year t are matched to the PIT outcome in year t + 1.",
    format(nrow(model_data), big.mark = ","),
    paste(length(approved_predictors), "approved predictors"),
    "State, CoC, predictor year, and target year are retained for grouped and time-based validation but excluded from the LASSO design matrix.",
    "Future-year total counts, future-year population denominators, target flags, and narrative fields are excluded from Model Data.",
    "Use rolling-origin or forward-chaining validation; do not randomly split rows.",
    "The 2021 PIT target is excluded because COVID disrupted unsheltered enumeration.",
    "All 36 processed and supporting CSVs are included as separate sheets so state-year, county-year, and CoC-year grains are never mixed.",
    "Raw download batches are preserved in their folders and represented by the CoC Raw File Index and County Raw File Index sheets.",
    "Blank cells remain unavailable values; they are never silently replaced with zero or interpolated.",
    "build_master_project_workbook.R"
  ),
  stringsAsFactors = FALSE
)

all_sheet_data <- c(
  list(
    "Workbook Index" = workbook_index,
    "Model Data" = model_data,
    "Model Dictionary" = model_dictionary,
    "Master Validation" = master_validation
  ),
  source_data
)

wb <- createWorkbook(creator = "California–Florida Homelessness Project")
addWorksheet(wb, "README", gridLines = FALSE, zoom = 90)
for (sheet in names(all_sheet_data)) {
  addWorksheet(wb, sheet, gridLines = FALSE, zoom = 85)
}

title_style <- createStyle(
  fgFill = "#17365D", fontColour = "#FFFFFF",
  textDecoration = "bold", fontSize = 16,
  halign = "left", valign = "center"
)
header_style <- createStyle(
  fgFill = "#1F4E78", fontColour = "#FFFFFF",
  textDecoration = "bold", halign = "center",
  valign = "center", wrapText = TRUE,
  border = "bottom", borderColour = "#17365D"
)
label_style <- createStyle(
  fgFill = "#D9EAF7", textDecoration = "bold", valign = "top"
)
value_style <- createStyle(wrapText = TRUE, valign = "top")
year_style <- createStyle(numFmt = "0")
integer_style <- createStyle(numFmt = "#,##0")
decimal_style <- createStyle(numFmt = "0.00")
currency_style <- createStyle(numFmt = "$#,##0")
wrap_style <- createStyle(wrapText = TRUE, valign = "top")
pass_style <- createStyle(
  fgFill = "#E2F0D9", fontColour = "#006100", textDecoration = "bold"
)
fail_style <- createStyle(
  fgFill = "#FCE4D6", fontColour = "#9C0006", textDecoration = "bold"
)

mergeCells(wb, "README", cols = 1:2, rows = 1)
writeData(
  wb, "README",
  "California–Florida Homelessness Project — Consolidated Data Workbook",
  startRow = 1, startCol = 1
)
writeData(wb, "README", readme, startRow = 3, startCol = 1)
addStyle(wb, "README", title_style, rows = 1, cols = 1:2, gridExpand = TRUE)
addStyle(wb, "README", header_style, rows = 3, cols = 1:2, gridExpand = TRUE)
addStyle(
  wb, "README", label_style,
  rows = 4:(nrow(readme) + 3), cols = 1, gridExpand = TRUE
)
addStyle(
  wb, "README", value_style,
  rows = 4:(nrow(readme) + 3), cols = 2, gridExpand = TRUE
)
setColWidths(wb, "README", cols = 1, widths = 27)
setColWidths(wb, "README", cols = 2, widths = 82)
setRowHeights(wb, "README", rows = 1, heights = 34)
setRowHeights(
  wb, "README", rows = 4:(nrow(readme) + 3), heights = 34
)
freezePane(wb, "README", firstActiveRow = 4)
pageSetup(
  wb, "README", orientation = "portrait",
  fitToWidth = 1, fitToHeight = 1
)

format_data_sheet <- function(sheet, data) {
  writeData(wb, sheet, data, keepNA = FALSE)
  row_count <- nrow(data)
  col_count <- ncol(data)
  headers <- names(data)

  addStyle(
    wb, sheet, header_style, rows = 1, cols = 1:col_count,
    gridExpand = TRUE
  )
  setRowHeights(wb, sheet, rows = 1, heights = 38)
  freezePane(
    wb, sheet, firstRow = TRUE,
    firstCol = col_count > 12
  )
  if (row_count > 0) {
    addFilter(wb, sheet, rows = 1, cols = 1:col_count)
  }
  pageSetup(
    wb, sheet, orientation = "landscape",
    fitToWidth = 1, fitToHeight = 0
  )

  widths <- vapply(seq_along(headers), function(index) {
    values <- c(headers[[index]], as.character(data[[index]]))
    values <- values[!is.na(values)]
    if (length(values) == 0) {
      return(10)
    }
    min(30, max(10, min(60, max(nchar(values), na.rm = TRUE) + 2)))
  }, numeric(1))
  setColWidths(wb, sheet, cols = 1:col_count, widths = widths)

  narrative_pattern <- paste(
    c(
      "definition", "description", "notes", "limitation", "assumption",
      "details", "check", "coverage", "source_file", "file", "path",
      "population_allocation_method", "target_definition"
    ),
    collapse = "|"
  )
  narrative_cols <- which(grepl(
    narrative_pattern, headers, ignore.case = TRUE
  ))
  if (length(narrative_cols) > 0 && row_count > 0) {
    setColWidths(wb, sheet, cols = narrative_cols, widths = 42)
    addStyle(
      wb, sheet, wrap_style, rows = 2:(row_count + 1),
      cols = narrative_cols, gridExpand = TRUE, stack = TRUE
    )
  }

  if (row_count > 0) {
    data_rows <- 2:(row_count + 1)
    numeric_cols <- which(vapply(data, is.numeric, logical(1)))
    year_cols <- which(grepl("(^year$|_year$|time_index$)", headers))
    currency_cols <- which(grepl(
      "usd|income|price|value_authorized|minimum_wage|gdp",
      headers,
      ignore.case = TRUE
    ))
    decimal_cols <- which(grepl(
      "rate|pct|share|per_10|per_100|per_1000|ratio|index|density|distance",
      headers,
      ignore.case = TRUE
    ))
    integer_cols <- setdiff(
      numeric_cols,
      union(year_cols, union(currency_cols, decimal_cols))
    )
    if (length(integer_cols) > 0) {
      addStyle(
        wb, sheet, integer_style, rows = data_rows,
        cols = integer_cols, gridExpand = TRUE, stack = TRUE
      )
    }
    if (length(decimal_cols) > 0) {
      addStyle(
        wb, sheet, decimal_style, rows = data_rows,
        cols = decimal_cols, gridExpand = TRUE, stack = TRUE
      )
    }
    if (length(currency_cols) > 0) {
      addStyle(
        wb, sheet, currency_style, rows = data_rows,
        cols = currency_cols, gridExpand = TRUE, stack = TRUE
      )
    }
    if (length(year_cols) > 0) {
      addStyle(
        wb, sheet, year_style, rows = data_rows,
        cols = year_cols, gridExpand = TRUE, stack = TRUE
      )
    }
  }

  id_widths <- c(
    state = 12, state_abbr = 11, year = 10, predictor_year = 14,
    target_year = 12, coc_number = 13, county_fips = 13,
    coc_name = 34, county_name = 30, variable = 36, pass = 10
  )
  for (column_name in intersect(names(id_widths), headers)) {
    setColWidths(
      wb, sheet, cols = match(column_name, headers),
      widths = unname(id_widths[[column_name]])
    )
  }

  if (row_count <= 250 && length(narrative_cols) > 0) {
    setRowHeights(wb, sheet, rows = 2:(row_count + 1), heights = 30)
  }
}

for (sheet in names(all_sheet_data)) {
  format_data_sheet(sheet, all_sheet_data[[sheet]])
}

validation_pass_col <- match("pass", names(master_validation))
validation_rows <- 2:(nrow(master_validation) + 1)
addStyle(
  wb, "Master Validation", pass_style,
  rows = validation_rows[master_validation$pass],
  cols = validation_pass_col, gridExpand = TRUE, stack = TRUE
)
if (any(!master_validation$pass)) {
  addStyle(
    wb, "Master Validation", fail_style,
    rows = validation_rows[!master_validation$pass],
    cols = validation_pass_col, gridExpand = TRUE, stack = TRUE
  )
}

saveWorkbook(wb, output_file, overwrite = TRUE)

if (!all(master_validation$pass)) {
  stop(
    "Master workbook validation failed:\n",
    paste(master_validation$check[!master_validation$pass], collapse = "\n")
  )
}

message(
  "Built ", basename(output_file), " with ", length(getSheetNames(output_file)),
  " sheets; Model Data has ", nrow(model_data), " rows and ",
  ncol(model_data), " columns; all ", nrow(master_validation),
  " master checks passed."
)
