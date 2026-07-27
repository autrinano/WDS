#!/usr/bin/env Rscript

# Reproducible cell-level sanity audit for DSA_Group_10_updated.xlsx.
# The script preserves the source workbook and writes an annotated copy.

.libPaths(c(file.path("Final Project", "_r_libs"), .libPaths()))
suppressPackageStartupMessages({
  library(openxlsx)
  library(readxl)
  library(zip)
})

input_path <- file.path("Final Project", "DSA_Group_10_updated.xlsx")
csv_path <- file.path("Final Project", "DSA Group 10 - Sheet1.csv")
housing_path <- file.path("Final Project", "housing_metrics_CA_FL_2010_2025.csv")
output_path <- file.path(
  "Final Project",
  "DSA_Group_10_updated_sanity_checked.xlsx"
)

stopifnot(file.exists(input_path), file.exists(csv_path), file.exists(housing_path))

data <- as.data.frame(readxl::read_excel(input_path, sheet = "Data"))
dictionary <- as.data.frame(
  readxl::read_excel(input_path, sheet = "Variable Dictionary")
)
missingness <- as.data.frame(
  readxl::read_excel(input_path, sheet = "Missingness")
)
csv_data <- read.csv(csv_path, check.names = FALSE, na.strings = c("", "NA"))
housing <- read.csv(housing_path, check.names = FALSE, na.strings = c("", "NA"))

headers <- names(data)
header_col <- setNames(seq_along(headers), headers)

near <- function(actual, expected, tol = 1e-7) {
  both_na <- is.na(actual) & is.na(expected)
  both_num <- !is.na(actual) & !is.na(expected)
  both_na | (both_num & abs(actual - expected) <= tol * pmax(1, abs(expected)))
}

same_vector <- function(a, b) {
  if (is.numeric(a) && is.numeric(b)) {
    identical(is.na(a), is.na(b)) && all(near(a, b))
  } else {
    identical(as.character(a), as.character(b))
  }
}

# Structural and provenance checks.
structural <- data.frame(
  check = character(),
  result = character(),
  details = character(),
  stringsAsFactors = FALSE
)

add_structural <- function(check, passed, details) {
  structural <<- rbind(
    structural,
    data.frame(
      check = check,
      result = if (passed) "PASS" else "FAIL",
      details = details,
      stringsAsFactors = FALSE
    )
  )
}

add_structural(
  "Workbook dimensions",
  nrow(data) == 32 && ncol(data) == 63,
  sprintf("%d rows x %d variables", nrow(data), ncol(data))
)
add_structural(
  "Unique state-year key",
  !anyDuplicated(data$state_year) &&
    !anyDuplicated(paste(data$state, data$year)),
  "One row per state-year"
)
add_structural(
  "Expected state/year coverage",
  identical(sort(unique(data$state)), c("California", "Florida")) &&
    all(vapply(
      split(data$year, data$state),
      function(x) identical(sort(x), 2010:2025),
      logical(1)
    )),
  "California and Florida, 2010-2025"
)
add_structural(
  "Workbook Data equals machine-readable team CSV",
  identical(names(data), names(csv_data)) &&
    all(vapply(headers, function(v) same_vector(data[[v]], csv_data[[v]]), logical(1))),
  "All 2,016 data values and missing-value positions match"
)

housing_fields <- setdiff(
  intersect(names(data), names(housing)),
  c("state", "year", "state_year")
)
housing_join <- merge(
  data[c("state", "year", housing_fields)],
  housing[c("state", "year", housing_fields)],
  by = c("state", "year"),
  suffixes = c(".workbook", ".source"),
  sort = FALSE
)
housing_match <- all(vapply(housing_fields, function(v) {
  same_vector(
    housing_join[[paste0(v, ".workbook")]],
    housing_join[[paste0(v, ".source")]]
  )
}, logical(1)))
add_structural(
  "Documented housing fields equal processed housing source panel",
  housing_match,
  sprintf("%d housing variables checked", length(housing_fields))
)

dict_counts_match <- all(vapply(seq_len(nrow(dictionary)), function(i) {
  v <- dictionary$variable[i]
  sum(!is.na(data[[v]])) == dictionary$available_rows[i] &&
    sum(is.na(data[[v]])) == dictionary$missing_rows[i] &&
    nrow(data) == dictionary$total_rows[i]
}, logical(1)))
add_structural(
  "Variable Dictionary availability counts",
  dict_counts_match,
  "Available/missing/total counts agree with Data"
)

missing_counts_match <- all(vapply(seq_len(nrow(missingness)), function(i) {
  v <- missingness$variable[i]
  sum(!is.na(data[[v]])) == missingness$available_rows[i] &&
    sum(is.na(data[[v]])) == missingness$missing_rows[i] &&
    nrow(data) == missingness$total_rows[i]
}, logical(1)))
add_structural(
  "Missingness sheet counts",
  missing_counts_match,
  "Every variable agrees with Data"
)

# Collect formula/domain problems separately so they can be marked red.
formula_issues <- data.frame(
  row_index = integer(),
  variable = character(),
  message = character(),
  stringsAsFactors = FALSE
)

add_formula_issue <- function(rows, variable, message) {
  if (!length(rows)) return(invisible(NULL))
  formula_issues <<- rbind(
    formula_issues,
    data.frame(
      row_index = rows,
      variable = variable,
      message = message,
      stringsAsFactors = FALSE
    )
  )
}

check_formula <- function(variable, expected, label, tol = 1e-7) {
  bad <- which(!near(data[[variable]], expected, tol = tol))
  add_formula_issue(bad, variable, paste("Formula mismatch:", label))
  !length(bad)
}

formula_results <- c(
  total_homeless =
    check_formula(
      "total_homeless",
      data$sheltered_homeless + data$unsheltered_homeless,
      "sheltered_homeless + unsheltered_homeless"
    ),
  homeless_rate_per_10k =
    check_formula(
      "homeless_rate_per_10k",
      round(10000 * data$total_homeless / data$state_population, 2),
      "round(10,000 * total_homeless / state_population, 2)",
      tol = 1e-6
    ),
  funding_per_capita =
    check_formula(
      "state_homeless_funding_per_capita",
      round(1e6 * data$state_homeless_funding_musd / data$state_population, 2),
      "round(1e6 * funding_musd / population, 2)",
      tol = 1e-6
    ),
  population_density =
    check_formula(
      "population_density",
      data$state_population /
        ifelse(data$state == "California", 155858.33, 53652.17),
      "state_population / documented state land area"
    ),
  population_growth =
    {
      expected <- rep(NA_real_, nrow(data))
      for (idx in split(seq_len(nrow(data)), data$state)) {
        expected[idx] <- c(
          NA_real_,
          100 * (data$state_population[idx[-1]] /
            data$state_population[idx[-length(idx)]] - 1)
        )
      }
      check_formula(
        "population_growth_rate_pct",
        expected,
        "within-state year-over-year population growth"
      )
    },
  unsheltered_share =
    check_formula(
      "unsheltered_share_pct",
      ifelse(
        data$year == 2021,
        NA_real_,
        100 * data$unsheltered_homeless / data$total_homeless
      ),
      "100 * unsheltered_homeless / total_homeless; 2021 suppressed"
    ),
  homeless_rate_change =
    {
      expected <- rep(NA_real_, nrow(data))
      for (idx in split(seq_len(nrow(data)), data$state)) {
        expected[idx] <- c(NA_real_, diff(data$homeless_rate_per_10k[idx]))
      }
      expected[data$year %in% c(2021, 2022)] <- NA_real_
      check_formula(
        "homeless_rate_change_per_10k",
        expected,
        "within-state rate change; 2021-2022 suppressed"
      )
    },
  pit_flag =
    check_formula(
      "pit_count_caution_flag",
      as.integer(data$year == 2021),
      "1 only in 2021"
    ),
  total_beds =
    check_formula(
      "total_beds_per_10k",
      data$shelter_beds_per_10k + data$psh_beds_per_10k,
      "shelter_beds_per_10k + psh_beds_per_10k"
    ),
  beds_per_homeless =
    check_formula(
      "beds_per_100_homeless",
      ifelse(
        data$year == 2021,
        NA_real_,
        100 * data$total_beds_per_10k / data$homeless_rate_per_10k
      ),
      "100 * total_beds_per_10k / homeless_rate_per_10k; 2021 suppressed"
    ),
  funding_per_homeless =
    check_formula(
      "funding_per_homeless_person",
      ifelse(
        data$year == 2021,
        NA_real_,
        1e6 * data$state_homeless_funding_musd / data$total_homeless
      ),
      "1e6 * funding_musd / total_homeless; 2021 suppressed"
    ),
  estimated_housing_units =
    check_formula(
      "estimated_housing_units",
      data$housing_units_per_capita * data$state_population,
      "housing_units_per_capita * state_population"
    ),
  permits_rate =
    check_formula(
      "permits_per_1000_housing_units",
      1000 * data$new_housing_permits / data$estimated_housing_units,
      "1,000 * permits / estimated_housing_units"
    ),
  price_income =
    check_formula(
      "home_price_to_income_ratio",
      data$median_home_price / data$median_household_income,
      "median_home_price / median_household_income"
    )
)

cpi_2025 <- unique(data$cpi_u[data$year == 2025])
stopifnot(length(cpi_2025) == 1)
formula_results <- c(
  formula_results,
  real_rent = check_formula(
    "real_median_rent_2025_usd",
    data$median_rent * cpi_2025 / data$cpi_u,
    "median_rent * CPI_2025 / CPI_year"
  ),
  real_home_price = check_formula(
    "real_median_home_price_2025_usd",
    data$median_home_price * cpi_2025 / data$cpi_u,
    "median_home_price * CPI_2025 / CPI_year"
  ),
  real_personal_income = check_formula(
    "real_personal_income_per_capita_2025_usd",
    data$personal_income_per_capita * cpi_2025 / data$cpi_u,
    "personal_income_per_capita * CPI_2025 / CPI_year"
  ),
  real_household_income = check_formula(
    "real_median_household_income_2025_usd",
    data$median_household_income * cpi_2025 / data$cpi_u,
    "median_household_income * CPI_2025 / CPI_year"
  ),
  real_minimum_wage = check_formula(
    "real_minimum_wage_2025_usd",
    data$minimum_wage * cpi_2025 / data$cpi_u,
    "minimum_wage * CPI_2025 / CPI_year"
  ),
  real_home_price_growth =
    {
      expected <- rep(NA_real_, nrow(data))
      for (idx in split(seq_len(nrow(data)), data$state)) {
        expected[idx] <- c(
          NA_real_,
          100 * (data$real_median_home_price_2025_usd[idx[-1]] /
            data$real_median_home_price_2025_usd[idx[-length(idx)]] - 1)
        )
      }
      check_formula(
        "real_home_price_growth_pct",
        expected,
        "year-over-year growth in real median home price"
      )
    }
)
add_structural(
  "Documented identities and derived formulas",
  all(formula_results),
  sprintf("%d formula families checked; %d mismatched cells", length(formula_results), nrow(formula_issues))
)

# Domain checks.
nonnegative_exceptions <- c(
  "population_growth_rate_pct",
  "homeless_rate_change_per_10k",
  "real_home_price_growth_pct"
)
numeric_vars <- headers[vapply(data, is.numeric, logical(1))]
nonnegative_vars <- setdiff(numeric_vars, c("year", nonnegative_exceptions))
bad_negative <- unlist(lapply(nonnegative_vars, function(v) {
  idx <- which(!is.na(data[[v]]) & data[[v]] < 0)
  if (length(idx)) {
    add_formula_issue(idx, v, "Domain error: value should be nonnegative")
    paste(v, idx, sep = ":")
  } else character()
}))

percent_vars <- c(
  "poverty_rate", "labor_force_participation", "unemployment_rate",
  "substance_use_disorder_rate", "serious_mental_illness_rate",
  "uninsured_rate", "high_school_graduation_rate", "pct_age_18_24",
  "pct_age_65plus", "rent_as_pct_income", "rent_burden_share",
  "rental_vacancy_rate", "homeownership_rate", "unsheltered_share_pct"
)
bad_percent <- unlist(lapply(percent_vars, function(v) {
  idx <- which(!is.na(data[[v]]) & (data[[v]] < 0 | data[[v]] > 100))
  if (length(idx)) {
    add_formula_issue(idx, v, "Domain error: percentage should be between 0 and 100")
    paste(v, idx, sep = ":")
  } else character()
}))

binary_vars <- c("medicaid_expansion", "pit_count_caution_flag")
bad_binary <- unlist(lapply(binary_vars, function(v) {
  idx <- which(!is.na(data[[v]]) & !(data[[v]] %in% c(0, 1)))
  if (length(idx)) {
    add_formula_issue(idx, v, "Domain error: flag should be 0 or 1")
    paste(v, idx, sep = ":")
  } else character()
}))
bad_ordinal <- which(
  !is.na(data$anticamping_strictness) &
    !(data$anticamping_strictness %in% 0:3)
)
if (length(bad_ordinal)) {
  add_formula_issue(
    bad_ordinal,
    "anticamping_strictness",
    "Domain error: expected documented ordinal level 0-3"
  )
}
add_structural(
  "Numeric domain checks",
  !length(bad_negative) && !length(bad_percent) &&
    !length(bad_binary) && !length(bad_ordinal),
  "Nonnegative, percentage, binary, and ordinal ranges checked"
)

# Flag registry. One cell can have several reasons; styles use highest severity.
flags <- data.frame(
  row_index = integer(),
  excel_row = integer(),
  variable = character(),
  cell = character(),
  state = character(),
  year = integer(),
  previous_value = character(),
  current_value = character(),
  abs_change = character(),
  pct_change = character(),
  severity = character(),
  classification = character(),
  reason = character(),
  provenance = character(),
  stringsAsFactors = FALSE
)

fmt <- function(x) {
  if (length(x) == 0 || is.na(x)) return("")
  if (is.numeric(x)) return(format(signif(x, 8), trim = TRUE, scientific = FALSE))
  as.character(x)
}

add_flag <- function(
    i,
    variable,
    severity,
    classification,
    reason,
    previous = NA,
    current = data[[variable]][i],
    abs_change = NA,
    pct_change = NA) {
  provenance <- dictionary$source_status[match(variable, dictionary$variable)]
  flags <<- rbind(
    flags,
    data.frame(
      row_index = i,
      excel_row = i + 1L,
      variable = variable,
      cell = paste0(int2col(header_col[[variable]]), i + 1L),
      state = data$state[i],
      year = data$year[i],
      previous_value = fmt(previous),
      current_value = fmt(current),
      abs_change = fmt(abs_change),
      pct_change = if (is.na(pct_change)) "" else sprintf("%.1f%%", 100 * pct_change),
      severity = severity,
      classification = classification,
      reason = reason,
      provenance = provenance,
      stringsAsFactors = FALSE
    )
  )
}

jump_rule <- function(variable, rule, reason) {
  for (idx in split(seq_len(nrow(data)), data$state)) {
    z <- data[[variable]][idx]
    for (j in 2:length(idx)) {
      i <- idx[j]
      previous <- z[j - 1]
      current <- z[j]
      if (is.na(previous) || is.na(current)) next
      delta <- current - previous
      rel <- if (previous == 0) Inf else abs(delta / previous)
      if (!rule(previous, current, delta, rel, i)) next

      known_pit <- variable %in% c(
        "total_homeless", "sheltered_homeless",
        "unsheltered_homeless", "homeless_rate_per_10k"
      ) && data$year[i] %in% c(2021, 2022)
      if (known_pit) {
        add_flag(
          i, variable, "KNOWN CAUTION", "Known 2021 PIT disruption",
          paste(
            "Large change involves the COVID-disrupted 2021 PIT count;",
            "do not treat it as an ordinary year-over-year movement."
          ),
          previous, current, delta, rel
        )
      } else {
        add_flag(
          i, variable, "REVIEW", "Large year-over-year change",
          reason, previous, current, delta, rel
        )
      }
    }
  }
}

rel_at_least <- function(cutoff, min_abs = 0) {
  force(cutoff); force(min_abs)
  function(previous, current, delta, rel, i) {
    rel >= cutoff && abs(delta) >= min_abs
  }
}
abs_at_least <- function(cutoff) {
  force(cutoff)
  function(previous, current, delta, rel, i) abs(delta) >= cutoff
}
any_change <- function(previous, current, delta, rel, i) delta != 0

# Source and outcome variables.
jump_rule("total_homeless", rel_at_least(0.20, 5000), "Count changed by at least 20%; verify the PIT source/method.")
jump_rule("sheltered_homeless", rel_at_least(0.20, 3000), "Count changed by at least 20%; verify the PIT source/method.")
jump_rule("unsheltered_homeless", rel_at_least(0.20, 3000), "Count changed by at least 20%; verify the PIT source/method.")
jump_rule("homeless_rate_per_10k", abs_at_least(3), "Rate moved by at least 3 people per 10,000.")
jump_rule("shelter_beds_per_10k", abs_at_least(2), "Bed rate moved by at least 2 per 10,000.")
jump_rule("psh_beds_per_10k", abs_at_least(2), "PSH bed rate moved by at least 2 per 10,000.")
jump_rule("state_homeless_funding_musd", rel_at_least(0.45, 10), "Funding changed by at least 45% and $10 million; accounting scope/source is undocumented.")
jump_rule("state_homeless_funding_per_capita", rel_at_least(0.45, 0.25), "Derived from the large movement in recorded funding.")
jump_rule("anticamping_strictness", any_change, "Ordinal policy code changed; verify the coding rule and effective date.")
jump_rule("medicaid_expansion", any_change, "Policy flag changed; verify the effective year.")
jump_rule("tanf_max_benefit_3person", rel_at_least(0.15, 25), "Benefit changed by at least 15%; verify nominal-dollar source.")
jump_rule("ssi_state_supplement", rel_at_least(0.15, 10), "Supplement changed by at least 15%; verify nominal-dollar source.")
jump_rule("minimum_wage", rel_at_least(0.15, 0.5), "Minimum wage changed by at least 15%; verify effective-date convention.")
jump_rule("personal_income_per_capita", rel_at_least(0.10, 2000), "Nominal income changed by at least 10%; pandemic/inflation may be relevant.")
jump_rule("median_household_income", rel_at_least(0.10, 2000), "Nominal income changed by at least 10%; verify annual source.")
jump_rule("poverty_rate", abs_at_least(1.5), "Poverty rate moved by at least 1.5 percentage points.")
jump_rule("labor_force_participation", abs_at_least(1.5), "Participation moved by at least 1.5 percentage points.")
jump_rule("unemployment_rate", abs_at_least(2), "Unemployment moved by at least 2 percentage points; 2020 pandemic shock is plausible.")
jump_rule("uninsured_rate", abs_at_least(3), "Uninsured rate moved by at least 3 percentage points.")
jump_rule("high_school_graduation_rate", abs_at_least(5), "Graduation rate moved by at least 5 percentage points.")
jump_rule("population_growth_rate_pct", abs_at_least(1), "Annual growth rate changed by at least 1 percentage point.")
jump_rule("avg_temp_f", abs_at_least(2), "Annual average temperature changed by at least 2 F.")
jump_rule("precip_in", rel_at_least(0.35, 5), "Annual precipitation changed by at least 35% and 5 inches; climate variability is plausible.")
jump_rule("cooling_degree_days", rel_at_least(0.25, 200), "Cooling degree days changed by at least 25% and 200.")

# Documented housing and macro series.
jump_rule("median_rent", rel_at_least(0.10, 100), "Rent changed by at least 10%; value matches the processed housing panel.")
jump_rule("median_home_price", rel_at_least(0.15, 20000), "Home price changed by at least 15%; value matches the processed Zillow-based panel.")
jump_rule("rental_vacancy_rate", abs_at_least(2), "Vacancy rate moved by at least 2 percentage points; value matches the processed housing panel.")
jump_rule("homeownership_rate", abs_at_least(2), "Homeownership moved by at least 2 percentage points; value matches the processed housing panel.")
jump_rule("new_housing_permits", rel_at_least(0.25, 10000), "Permits changed by at least 25%; value matches the processed FRED/Census-based panel.")
jump_rule("housing_supply_growth_rate", abs_at_least(0.5), "Housing-stock growth moved by at least 0.5 percentage points; check Census-vintage context.")
jump_rule("cpi_u", rel_at_least(0.05, 5), "Annual CPI-U rose by at least 5%; value matches the local CPI source series.")

# Derived measures: mark large movements so users can trace their source.
jump_rule("unsheltered_share_pct", abs_at_least(5), "Composition changed by at least 5 percentage points.")
for (i in which(!is.na(data$homeless_rate_change_per_10k) &
                abs(data$homeless_rate_change_per_10k) >= 3)) {
  add_flag(
    i, "homeless_rate_change_per_10k", "REVIEW",
    "Large year-over-year change",
    "Derived homelessness-rate movement is at least 3 per 10,000.",
    current = data$homeless_rate_change_per_10k[i],
    abs_change = data$homeless_rate_change_per_10k[i]
  )
}
jump_rule("total_beds_per_10k", abs_at_least(2), "Derived total bed rate moved by at least 2 per 10,000.")
jump_rule("beds_per_100_homeless", abs_at_least(10), "Derived beds-per-homeless ratio moved by at least 10.")
jump_rule("funding_per_homeless_person", rel_at_least(0.50, 100), "Derived value inherits a large funding movement.")
jump_rule("permits_per_1000_housing_units", rel_at_least(0.25, 1), "Derived permit rate changed by at least 25%.")
jump_rule("home_price_to_income_ratio", rel_at_least(0.15, 0.5), "Derived affordability ratio changed by at least 15%.")
jump_rule("real_median_rent_2025_usd", rel_at_least(0.10, 100), "Inflation-adjusted rent changed by at least 10%.")
jump_rule("real_median_home_price_2025_usd", rel_at_least(0.15, 20000), "Inflation-adjusted home price changed by at least 15%.")
jump_rule("real_personal_income_per_capita_2025_usd", rel_at_least(0.10, 2000), "Inflation-adjusted personal income changed by at least 10%.")
jump_rule("real_median_household_income_2025_usd", rel_at_least(0.10, 2000), "Inflation-adjusted household income changed by at least 10%.")
jump_rule("real_minimum_wage_2025_usd", rel_at_least(0.10, 0.75), "Inflation-adjusted minimum wage changed by at least 10%.")
for (i in which(!is.na(data$real_home_price_growth_pct) &
                abs(data$real_home_price_growth_pct) >= 10)) {
  add_flag(
    i, "real_home_price_growth_pct", "REVIEW",
    "Large year-over-year change",
    "Absolute real home-price growth is at least 10%; derived value matches the documented formula.",
    current = data$real_home_price_growth_pct[i],
    abs_change = data$real_home_price_growth_pct[i]
  )
}

# Explicitly mark the known 2021 PIT cells even where a threshold did not fire.
pit_vars <- c(
  "total_homeless", "sheltered_homeless",
  "unsheltered_homeless", "homeless_rate_per_10k",
  "pit_count_caution_flag"
)
for (i in which(data$year == 2021)) {
  for (v in pit_vars) {
    if (!any(flags$row_index == i & flags$variable == v)) {
      add_flag(
        i, v, "KNOWN CAUTION", "Known 2021 PIT disruption",
        "COVID disrupted 2021 PIT enumeration; retain only with an explicit caution/exclusion."
      )
    }
  }
}

# Repeated benchmark and too-smooth patterns are audit cautions, not errors.
pattern_notes <- c(
  median_rent = paste(
    "Repeated 2011-2015 and 2016-2019 benchmark values are documented",
    "carry-forwards in the housing source; do not interpret as no market change."
  ),
  rent_burden_share = paste(
    "Repeated Eviction Lab benchmark values are documented carry-forwards;",
    "do not interpret as no market change."
  ),
  average_student_debt_per_borrower = paste(
    "Every state series rises by exactly $500 each year.",
    "This unusually mechanical pattern requires original-source verification."
  ),
  avg_in_state_tuition = paste(
    "Series follows near-mechanical annual increments.",
    "This unusually smooth pattern requires original-source verification."
  ),
  high_school_graduation_rate = paste(
    "Long nearly linear runs are unusually smooth;",
    "verify original annual source and measurement changes."
  ),
  substance_use_disorder_rate = paste(
    "Series changes almost entirely in 0.1-point steps;",
    "verify whether values were interpolated or constructed."
  ),
  serious_mental_illness_rate = paste(
    "Only six unique values across 32 rows;",
    "verify whether values were carried or rounded."
  ),
  state_homeless_funding_musd = paste(
    "California has four leading zeros and later very large budget swings.",
    "Confirm zeros are true measured zeros, not unavailable values."
  )
)

# Mark repeated documented benchmark cells.
for (v in c("median_rent", "rent_burden_share")) {
  for (idx in split(seq_len(nrow(data)), data$state)) {
    z <- data[[v]][idx]
    runs <- rle(z)
    ends <- cumsum(runs$lengths)
    starts <- ends - runs$lengths + 1
    for (k in seq_along(runs$lengths)) {
      if (is.na(runs$values[k]) || runs$lengths[k] < 3) next
      for (j in starts[k]:ends[k]) {
        i <- idx[j]
        add_flag(
          i, v, "PATTERN", "Documented repeated benchmark",
          pattern_notes[[v]], current = data[[v]][i]
        )
      }
    }
  }
}

# Promote all formula/domain issues to red flags.
if (nrow(formula_issues)) {
  for (k in seq_len(nrow(formula_issues))) {
    i <- formula_issues$row_index[k]
    v <- formula_issues$variable[k]
    add_flag(
      i, v, "ERROR", "Formula/domain failure",
      formula_issues$message[k], current = data[[v]][i]
    )
  }
}

# Remove exact duplicate flags caused by overlapping rules.
flags <- unique(flags)
severity_order <- c("ERROR" = 4, "REVIEW" = 3, "KNOWN CAUTION" = 2, "PATTERN" = 1)
flags <- flags[order(
  flags$state, flags$year,
  -unname(severity_order[flags$severity]),
  flags$variable
), ]
row.names(flags) <- NULL

# Variable-level audit (all 63 variables).
pattern_for <- function(v) {
  if (v %in% names(pattern_notes)) pattern_notes[[v]] else ""
}
formula_vars <- c(
  "total_homeless", "homeless_rate_per_10k",
  "state_homeless_funding_per_capita", "population_density",
  "population_growth_rate_pct", "unsheltered_share_pct",
  "homeless_rate_change_per_10k", "pit_count_caution_flag",
  "total_beds_per_10k", "beds_per_100_homeless",
  "funding_per_homeless_person", "estimated_housing_units",
  "permits_per_1000_housing_units", "home_price_to_income_ratio",
  "real_median_rent_2025_usd", "real_median_home_price_2025_usd",
  "real_personal_income_per_capita_2025_usd",
  "real_median_household_income_2025_usd",
  "real_minimum_wage_2025_usd", "real_home_price_growth_pct"
)
variable_audit <- data.frame(
  variable = dictionary$variable,
  category = dictionary$category,
  source_status = dictionary$source_status,
  data_type = vapply(dictionary$variable, function(v) class(data[[v]])[1], character(1)),
  available = vapply(dictionary$variable, function(v) sum(!is.na(data[[v]])), integer(1)),
  missing = vapply(dictionary$variable, function(v) sum(is.na(data[[v]])), integer(1)),
  unique_nonmissing = vapply(
    dictionary$variable,
    function(v) length(unique(data[[v]][!is.na(data[[v]])])),
    integer(1)
  ),
  minimum = vapply(dictionary$variable, function(v) {
    x <- data[[v]]
    if (!is.numeric(x) || all(is.na(x))) "" else fmt(min(x, na.rm = TRUE))
  }, character(1)),
  maximum = vapply(dictionary$variable, function(v) {
    x <- data[[v]]
    if (!is.numeric(x) || all(is.na(x))) "" else fmt(max(x, na.rm = TRUE))
  }, character(1)),
  formula_check = vapply(dictionary$variable, function(v) {
    if (!(v %in% formula_vars)) "N/A"
    else if (any(formula_issues$variable == v)) "FAIL"
    else "PASS"
  }, character(1)),
  flagged_cells = vapply(
    dictionary$variable,
    function(v) length(unique(flags$cell[flags$variable == v])),
    integer(1)
  ),
  audit_note = vapply(dictionary$variable, pattern_for, character(1)),
  stringsAsFactors = FALSE
)

# Write the annotated workbook. Work from a temporary copy because some
# spreadsheet libraries repair malformed relationships during load.
workbook_source <- tempfile("wds_workbook_source_", fileext = ".xlsx")
stopifnot(file.copy(input_path, workbook_source, overwrite = TRUE))
wb <- loadWorkbook(workbook_source)
if ("Sanity Check" %in% names(wb)) removeWorksheet(wb, "Sanity Check")
addWorksheet(wb, "Sanity Check", gridLines = FALSE)

title_style <- createStyle(
  fontSize = 16, textDecoration = "bold", fontColour = "#FFFFFF",
  fgFill = "#1F4E78", halign = "left", valign = "center"
)
section_style <- createStyle(
  fontSize = 12, textDecoration = "bold", fontColour = "#FFFFFF",
  fgFill = "#5B9BD5", halign = "left"
)
header_style <- createStyle(
  textDecoration = "bold", fontColour = "#FFFFFF", fgFill = "#4472C4",
  border = "Bottom", borderColour = "#203864", wrapText = TRUE,
  valign = "top"
)
pass_style <- createStyle(fontColour = "#006100", fgFill = "#C6EFCE")
fail_style <- createStyle(fontColour = "#9C0006", fgFill = "#FFC7CE")
review_style <- createStyle(fgFill = "#F4B183")
known_style <- createStyle(fgFill = "#BDD7EE")
pattern_style <- createStyle(fgFill = "#FFF2CC")
error_style <- createStyle(fgFill = "#F4CCCC", fontColour = "#9C0006")
source_needed_style <- createStyle(fgFill = "#E4DFEC")
wrap_top <- createStyle(wrapText = TRUE, valign = "top")

writeData(wb, "Sanity Check", "DSA Group 10 workbook sanity check", startRow = 1, startCol = 1)
mergeCells(wb, "Sanity Check", cols = 1:14, rows = 1)
addStyle(wb, "Sanity Check", title_style, rows = 1, cols = 1:14, gridExpand = TRUE)
setRowHeights(wb, "Sanity Check", rows = 1, heights = 26)

overview <- data.frame(
  item = c(
    "Workbook reviewed",
    "Scope",
    "Result",
    "Source limitation",
    "Interpretation"
  ),
  value = c(
    basename(input_path),
    "Every one of 63 variables; 2,016 data cells; identifiers, domains, missingness, formulas, provenance, and year-over-year movements",
    sprintf(
      "%d ERROR, %d REVIEW, %d KNOWN CAUTION, and %d PATTERN flag rows",
      sum(flags$severity == "ERROR"),
      sum(flags$severity == "REVIEW"),
      sum(flags$severity == "KNOWN CAUTION"),
      sum(flags$severity == "PATTERN")
    ),
    sprintf(
      "%d variables are marked 'source verification needed'; their values cannot be certified against an absent original source.",
      sum(dictionary$source_status == "source verification needed")
    ),
    "A flag means investigate or disclose; it does not mean delete, winsorize, or replace the value."
  ),
  stringsAsFactors = FALSE
)
writeData(wb, "Sanity Check", overview, startRow = 3, startCol = 1, headerStyle = header_style)
addStyle(wb, "Sanity Check", wrap_top, rows = 4:(3 + nrow(overview)), cols = 1:2, gridExpand = TRUE)

legend_row <- 10
writeData(wb, "Sanity Check", "Legend", startRow = legend_row, startCol = 1)
mergeCells(wb, "Sanity Check", cols = 1:14, rows = legend_row)
addStyle(wb, "Sanity Check", section_style, rows = legend_row, cols = 1:14, gridExpand = TRUE)
legend <- data.frame(
  color = c("Red", "Orange", "Blue", "Yellow", "Purple header"),
  meaning = c(
    "Formula/domain error (none found if count is zero)",
    "Large year-over-year change or high-priority value requiring source review",
    "Known 2021 PIT disruption or a change involving that count",
    "Repeated benchmark or suspiciously smooth/carry-forward pattern",
    "Variable is explicitly labeled source verification needed"
  ),
  stringsAsFactors = FALSE
)
writeData(wb, "Sanity Check", legend, startRow = legend_row + 1, startCol = 1, headerStyle = header_style)
for (j in seq_len(nrow(legend))) {
  style <- list(error_style, review_style, known_style, pattern_style, source_needed_style)[[j]]
  addStyle(wb, "Sanity Check", style, rows = legend_row + 1 + j, cols = 1)
}

structural_row <- legend_row + nrow(legend) + 3
writeData(wb, "Sanity Check", "Structural, source-panel, and formula checks", startRow = structural_row, startCol = 1)
mergeCells(wb, "Sanity Check", cols = 1:14, rows = structural_row)
addStyle(wb, "Sanity Check", section_style, rows = structural_row, cols = 1:14, gridExpand = TRUE)
writeData(wb, "Sanity Check", structural, startRow = structural_row + 1, startCol = 1, headerStyle = header_style)
for (j in seq_len(nrow(structural))) {
  addStyle(
    wb, "Sanity Check",
    if (structural$result[j] == "PASS") pass_style else fail_style,
    rows = structural_row + 1 + j, cols = 2
  )
}
addStyle(
  wb, "Sanity Check", wrap_top,
  rows = (structural_row + 2):(structural_row + 1 + nrow(structural)),
  cols = 1:3, gridExpand = TRUE
)

variable_row <- structural_row + nrow(structural) + 4
writeData(wb, "Sanity Check", "Variable-by-variable audit (all 63 variables)", startRow = variable_row, startCol = 1)
mergeCells(wb, "Sanity Check", cols = 1:14, rows = variable_row)
addStyle(wb, "Sanity Check", section_style, rows = variable_row, cols = 1:14, gridExpand = TRUE)
writeData(wb, "Sanity Check", variable_audit, startRow = variable_row + 1, startCol = 1, headerStyle = header_style)
addStyle(
  wb, "Sanity Check", wrap_top,
  rows = (variable_row + 2):(variable_row + 1 + nrow(variable_audit)),
  cols = 1:ncol(variable_audit), gridExpand = TRUE
)
for (j in which(variable_audit$source_status == "source verification needed")) {
  addStyle(
    wb, "Sanity Check", source_needed_style,
    rows = variable_row + 1 + j, cols = 3
  )
}
for (j in which(variable_audit$formula_check == "PASS")) {
  addStyle(wb, "Sanity Check", pass_style, rows = variable_row + 1 + j, cols = 10)
}
for (j in which(variable_audit$formula_check == "FAIL")) {
  addStyle(wb, "Sanity Check", fail_style, rows = variable_row + 1 + j, cols = 10)
}

flags_row <- variable_row + nrow(variable_audit) + 4
writeData(wb, "Sanity Check", "Flagged cells and investigated year-over-year movements", startRow = flags_row, startCol = 1)
mergeCells(wb, "Sanity Check", cols = 1:14, rows = flags_row)
addStyle(wb, "Sanity Check", section_style, rows = flags_row, cols = 1:14, gridExpand = TRUE)
writeData(wb, "Sanity Check", flags, startRow = flags_row + 1, startCol = 1, headerStyle = header_style)
addStyle(
  wb, "Sanity Check", wrap_top,
  rows = (flags_row + 2):(flags_row + 1 + nrow(flags)),
  cols = 1:ncol(flags), gridExpand = TRUE
)
for (j in seq_len(nrow(flags))) {
  style <- switch(
    flags$severity[j],
    ERROR = error_style,
    REVIEW = review_style,
    `KNOWN CAUTION` = known_style,
    PATTERN = pattern_style
  )
  addStyle(wb, "Sanity Check", style, rows = flags_row + 1 + j, cols = 11)
}

freezePane(wb, "Sanity Check", firstActiveRow = 2)
setColWidths(
  wb, "Sanity Check", cols = 1:ncol(flags),
  widths = c(12, 12, 18, 12, 14, 10, 16, 16, 14, 12, 16, 28, 60, 34)
)
setColWidths(wb, "Sanity Check", cols = 1, widths = 24)
setColWidths(wb, "Sanity Check", cols = 2, widths = 52)

# Purple headers identify variables with unresolved source provenance.
for (v in dictionary$variable[dictionary$source_status == "source verification needed"]) {
  addStyle(
    wb, "Data", source_needed_style,
    rows = 1, cols = header_col[[v]], stack = TRUE
  )
}

# Yellow headers and comments identify series-level pattern concerns.
for (v in names(pattern_notes)) {
  addStyle(
    wb, "Data", pattern_style,
    rows = 1, cols = header_col[[v]], stack = TRUE
  )
  writeComment(
    wb, "Data", col = header_col[[v]], row = 1,
    comment = createComment(
      comment = pattern_notes[[v]],
      author = "WDS sanity audit",
      visible = FALSE
    )
  )
}

# Apply the highest-severity style and combine all reasons into one comment per cell.
cell_groups <- split(seq_len(nrow(flags)), flags$cell)
for (cell in names(cell_groups)) {
  rows <- cell_groups[[cell]]
  best <- rows[which.max(unname(severity_order[flags$severity[rows]]))]
  style <- switch(
    flags$severity[best],
    ERROR = error_style,
    REVIEW = review_style,
    `KNOWN CAUTION` = known_style,
    PATTERN = pattern_style
  )
  addStyle(
    wb, "Data", style,
    rows = flags$excel_row[best],
    cols = header_col[[flags$variable[best]]],
    stack = TRUE
  )
  messages <- unique(paste0(
    flags$classification[rows], ": ", flags$reason[rows],
    ifelse(
      flags$previous_value[rows] == "",
      "",
      paste0(
        "\nPrevious=", flags$previous_value[rows],
        "; current=", flags$current_value[rows],
        "; change=", flags$abs_change[rows],
        ifelse(flags$pct_change[rows] == "", "", paste0(" (", flags$pct_change[rows], ")"))
      )
    ),
    "\nProvenance status: ", flags$provenance[rows]
  ))
  writeComment(
    wb, "Data",
    col = header_col[[flags$variable[best]]],
    row = flags$excel_row[best],
    comment = createComment(
      comment = paste(messages, collapse = "\n\n"),
      author = "WDS sanity audit",
      visible = FALSE
    )
  )
}

saveWorkbook(wb, output_path, overwrite = TRUE)
unlink(workbook_source)

# openxlsx writes legacy comment rich-text fonts with a <name> element.
# Normalize that element to the OOXML <rFont> form for broader reader support.
patch_dir <- tempfile("wds_xlsx_patch_")
dir.create(patch_dir)
utils::unzip(output_path, exdir = patch_dir)
comment_files <- list.files(
  file.path(patch_dir, "xl"),
  pattern = "^comments.*\\.xml$",
  recursive = TRUE,
  full.names = TRUE
)
for (comment_file in comment_files) {
  xml <- paste(readLines(comment_file, warn = FALSE), collapse = "\n")
  xml <- gsub("<name val=", "<rFont val=", xml, fixed = TRUE)
  xml <- gsub("</name>", "</rFont>", xml, fixed = TRUE)
  writeLines(xml, comment_file, useBytes = TRUE)
}
# The source workbook contains stale relationships to drawing files that do
# not exist. Remove those dangling links; retain sheet 1's real comment VML.
relationship_files <- list.files(
  file.path(patch_dir, "xl", "worksheets", "_rels"),
  pattern = "\\.rels$",
  full.names = TRUE
)
for (relationship_file in relationship_files) {
  xml <- paste(readLines(relationship_file, warn = FALSE), collapse = "\n")
  xml <- gsub(
    '<Relationship[^>]*Type="http://schemas\\.openxmlformats\\.org/officeDocument/2006/relationships/drawing"[^>]*/>',
    "",
    xml
  )
  if (basename(relationship_file) != "sheet1.xml.rels") {
    xml <- gsub(
      '<Relationship[^>]*Type="http://schemas\\.openxmlformats\\.org/officeDocument/2006/relationships/vmlDrawing"[^>]*/>',
      "",
      xml
    )
  }
  writeLines(xml, relationship_file, useBytes = TRUE)
}
patched_path <- tempfile("wds_sanity_checked_", fileext = ".xlsx")
zip::zip(
  zipfile = patched_path,
  files = list.files(
    patch_dir,
    recursive = TRUE,
    all.files = TRUE,
    no.. = TRUE
  ),
  root = patch_dir,
  mode = "mirror",
  include_directories = FALSE
)
stopifnot(file.copy(patched_path, output_path, overwrite = TRUE))
unlink(patch_dir, recursive = TRUE)
unlink(patched_path)

cat("Wrote:", output_path, "\n")
cat("Flags:", paste(names(table(flags$severity)), as.integer(table(flags$severity)), collapse = "; "), "\n")
cat("Formula/domain issue cells:", nrow(formula_issues), "\n")
cat("Variables requiring original-source verification:",
    sum(dictionary$source_status == "source verification needed"), "\n")
