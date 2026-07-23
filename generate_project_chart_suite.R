#!/usr/bin/env Rscript

# Curated chart suite for the California–Florida homelessness project.
# The suite emphasizes time, normalized denominators, within-state variation,
# data coverage, and the 2021 PIT-count disruption.

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(readr)
})

data_path <- "DSA Group 10 - Sheet1.csv"
output_root <- "charts"
local_lib <- "_r_libs"
.libPaths(c(local_lib, .libPaths()))

chart_dirs <- file.path(
  output_root,
  c(
    "01_outcomes",
    "02_housing",
    "03_economy_and_services",
    "04_relationships",
    "05_data_quality",
    "06_scatterplots"
  )
)
invisible(lapply(chart_dirs, dir.create, recursive = TRUE, showWarnings = FALSE))

data <- read_csv(data_path, show_col_types = FALSE) |>
  arrange(state, year) |>
  mutate(
    homeless_rate_for_plot = if_else(
      year == 2021L, NA_real_, homeless_rate_per_10k
    )
  )

stopifnot(
  nrow(data) == 32,
  !anyDuplicated(data[c("state", "year")]),
  all(range(data$year) == c(2010, 2025)),
  sum(is.na(data$housing_units_per_capita)) == 0
)

state_colors <- c("California" = "#C44E52", "Florida" = "#2A6FBB")
component_colors <- c("Sheltered" = "#4C78A8", "Unsheltered" = "#E45756")
series_colors <- c(
  "Homelessness rate" = "#7A5195",
  "Total beds" = "#2A9D8F",
  "Real personal income" = "#2A9D8F",
  "Real home price" = "#E76F51"
)

base_theme <- theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    legend.position = "top",
    plot.title.position = "plot",
    plot.title = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(color = "grey30"),
    plot.caption = element_text(color = "grey35", hjust = 0),
    strip.text = element_text(face = "bold"),
    axis.title = element_text(face = "bold")
  )

year_scale <- scale_x_continuous(
  breaks = c(2010, 2013, 2016, 2019, 2022, 2025),
  minor_breaks = NULL
)

shade_2021 <- annotate(
  "rect",
  xmin = 2020.5, xmax = 2021.5,
  ymin = -Inf, ymax = Inf,
  fill = "grey55", alpha = 0.12
)

save_chart <- function(plot, relative_path, width = 9, height = 5.8) {
  output_path <- file.path(output_root, relative_path)
  ggsave(
    output_path,
    plot = plot,
    width = width,
    height = height,
    units = "in",
    dpi = 300,
    bg = "white"
  )
  output_path
}

manifest <- tibble(
  category = character(),
  title = character(),
  variables = character(),
  path = character(),
  design_reason = character()
)

record_chart <- function(category, title, variables, path, design_reason) {
  manifest <<- bind_rows(
    manifest,
    tibble(
      category = category,
      title = title,
      variables = variables,
      path = path,
      design_reason = design_reason
    )
  )
}

source_caption <- paste0(
  "Source: updated DSA Group 10 panel. ",
  "Gray band marks the COVID-disrupted 2021 PIT count."
)

# ---------------------------------------------------------------------------
# 01. Homelessness outcomes
# ---------------------------------------------------------------------------

homeless_rate_plot <- ggplot(
  data,
  aes(year, homeless_rate_for_plot, color = state)
) +
  shade_2021 +
  geom_line(linewidth = 1.2, na.rm = TRUE) +
  geom_point(size = 2.5, na.rm = TRUE) +
  geom_point(
    data = filter(data, year == 2021),
    aes(year, homeless_rate_per_10k),
    shape = 4, size = 3.5, stroke = 1.2,
    color = "grey35", inherit.aes = FALSE
  ) +
  scale_color_manual(values = state_colors) +
  year_scale +
  labs(
    title = "Homelessness rates diverged after the early 2010s",
    subtitle = "Annual PIT rate per 10,000 residents; 2021 is not directly comparable",
    x = NULL,
    y = "People per 10,000 residents",
    color = NULL,
    caption = source_caption
  ) +
  base_theme

path <- save_chart(
  homeless_rate_plot,
  "01_outcomes/homelessness_rate_over_time.png"
)
record_chart(
  "Outcomes",
  "Homelessness rate over time",
  "homeless_rate_per_10k",
  path,
  "Preserves time ordering and explicitly flags the 2021 measurement disruption."
)
unsheltered_share_plot <- ggplot(
  data,
  aes(year, unsheltered_share_pct, color = state)
) +
  shade_2021 +
  geom_hline(yintercept = 50, color = "grey65", linetype = "dashed") +
  geom_line(linewidth = 1.2, na.rm = TRUE) +
  geom_point(size = 2.5, na.rm = TRUE) +
  scale_color_manual(values = state_colors) +
  scale_y_continuous(labels = scales::label_percent(scale = 1)) +
  year_scale +
  labs(
    title = "The unsheltered share is persistently higher in California",
    subtitle = "Unsheltered people as a percentage of the recorded PIT total",
    x = NULL,
    y = "Unsheltered share",
    color = NULL,
    caption = source_caption
  ) +
  base_theme

path <- save_chart(
  unsheltered_share_plot,
  "01_outcomes/unsheltered_share_over_time.png"
)
record_chart(
  "Outcomes",
  "Unsheltered share over time",
  "unsheltered_share_pct",
  path,
  "Uses a comparable percentage instead of state totals with very different population sizes."
)

composition <- data |>
  filter(year != 2021) |>
  select(state, year, sheltered_homeless, unsheltered_homeless) |>
  pivot_longer(
    c(sheltered_homeless, unsheltered_homeless),
    names_to = "housing_status",
    values_to = "people"
  ) |>
  mutate(
    housing_status = recode(
      housing_status,
      sheltered_homeless = "Sheltered",
      unsheltered_homeless = "Unsheltered"
    )
  )

composition_plot <- ggplot(
  composition,
  aes(factor(year), people, fill = housing_status)
) +
  geom_col(position = "fill", width = 0.82) +
  facet_wrap(~state, ncol = 1) +
  scale_fill_manual(values = component_colors) +
  scale_y_continuous(labels = scales::label_percent()) +
  scale_x_discrete(breaks = as.character(c(2010, 2013, 2016, 2019, 2022, 2025))) +
  labs(
    title = "Composition of recorded homelessness",
    subtitle = "Each bar sums to 100%; use caution for the COVID-disrupted 2021 count",
    x = NULL,
    y = "Share of PIT total",
    fill = NULL,
    caption = "Source: updated DSA Group 10 panel."
  ) +
  base_theme

path <- save_chart(
  composition_plot,
  "01_outcomes/homelessness_composition.png",
  height = 7.2
)
record_chart(
  "Outcomes",
  "Homelessness composition",
  "sheltered_homeless; unsheltered_homeless",
  path,
  "A 100% composition chart avoids misleading comparisons of raw state totals."
)
# ---------------------------------------------------------------------------
# 02. Housing cost, affordability, and supply
# ---------------------------------------------------------------------------

plot_time_series <- function(
    variable, title, subtitle, y_label, relative_path,
    formatter = scales::label_number(), show_2021 = FALSE) {
  plot <- ggplot(data, aes(year, .data[[variable]], color = state))
  if (show_2021) plot <- plot + shade_2021
  plot <- plot +
    geom_line(linewidth = 1.2, na.rm = TRUE) +
    geom_point(size = 2.4, na.rm = TRUE) +
    scale_color_manual(values = state_colors) +
    scale_y_continuous(labels = formatter) +
    year_scale +
    labs(
      title = title,
      subtitle = subtitle,
      x = NULL, y = y_label, color = NULL,
      caption = paste0(
        "Source: updated DSA Group 10 panel. ",
        "Lines break where observations are unavailable."
      )
    ) +
    base_theme
  save_chart(plot, relative_path)
  plot
}

real_rent_plot <- plot_time_series(
  "real_median_rent_2025_usd",
  "Inflation-adjusted rent rose sharply in recent years",
  "Median gross rent in constant 2025 dollars",
  "Monthly rent (2025 dollars)",
  "02_housing/real_median_rent_over_time.png",
  scales::label_dollar(accuracy = 1)
)
record_chart(
  "Housing",
  "Real median rent",
  "real_median_rent_2025_usd",
  "charts/02_housing/real_median_rent_over_time.png",
  "Uses constant dollars so the trend is not merely general inflation."
)

real_price_plot <- plot_time_series(
  "real_median_home_price_2025_usd",
  "Real home prices increased much faster in California",
  "Annual median sale price in constant 2025 dollars",
  "Median sale price (2025 dollars)",
  "02_housing/real_median_home_price_over_time.png",
  scales::label_dollar(scale = 0.001, suffix = "K", accuracy = 1)
)
record_chart(
  "Housing",
  "Real median home price",
  "real_median_home_price_2025_usd",
  "charts/02_housing/real_median_home_price_over_time.png",
  "Uses a consistent sale-price series and adjusts for inflation."
)

price_income_plot <- plot_time_series(
  "home_price_to_income_ratio",
  "Home prices require more years of median household income",
  "Median state sale price divided by median household income",
  "Price-to-income ratio",
  "02_housing/home_price_to_income_ratio.png",
  scales::label_number(accuracy = 0.1)
)
record_chart(
  "Housing",
  "Home price-to-income ratio",
  "home_price_to_income_ratio",
  "charts/02_housing/home_price_to_income_ratio.png",
  "Combines price and income into an interpretable affordability measure."
)

vacancy_plot <- plot_time_series(
  "rental_vacancy_rate",
  "Florida has consistently had more rental vacancy",
  "Annual rental vacancy rate",
  "Rental vacancy rate",
  "02_housing/rental_vacancy_rate.png",
  scales::label_percent(scale = 1, accuracy = 0.1)
)
record_chart(
  "Housing",
  "Rental vacancy rate",
  "rental_vacancy_rate",
  "charts/02_housing/rental_vacancy_rate.png",
  "Direct time comparison of a central housing-market tightness measure."
)

housing_units_plot <- ggplot(
  data,
  aes(year, 1000 * housing_units_per_capita, color = state)
) +
  geom_line(linewidth = 1.2) +
  geom_point(size = 2.4) +
  scale_color_manual(values = state_colors) +
  year_scale +
  labs(
    title = "Florida has more housing units per resident",
    subtitle = "Estimated total housing units per 1,000 residents",
    x = NULL,
    y = "Housing units per 1,000 residents",
    color = NULL,
    caption = paste0(
      "Source: U.S. Census Population Estimates. ",
      "The series crosses a documented vintage boundary after 2019."
    )
  ) +
  base_theme

path <- save_chart(
  housing_units_plot,
  "02_housing/housing_units_per_1000_residents.png"
)
record_chart(
  "Housing",
  "Housing units per 1,000 residents",
  "housing_units_per_capita",
  path,
  "Rescales the complete per-capita series to an intuitive denominator."
)

permit_plot <- plot_time_series(
  "permits_per_1000_housing_units",
  "Permitting intensity shifted after the housing crash",
  "Authorized units per 1,000 existing housing units",
  "Permits per 1,000 housing units",
  "02_housing/permits_per_1000_housing_units.png",
  scales::label_number(accuracy = 0.1)
)
record_chart(
  "Housing",
  "Permits per 1,000 housing units",
  "permits_per_1000_housing_units",
  "charts/02_housing/permits_per_1000_housing_units.png",
  "Normalizes permits for the very different size of the two housing stocks."
)

supply_growth_plot <- plot_time_series(
  "housing_supply_growth_rate",
  "Florida's housing stock has generally grown faster",
  "Within-vintage year-over-year change; 2020 is intentionally blank",
  "Housing-stock growth",
  "02_housing/housing_supply_growth_rate.png",
  scales::label_percent(scale = 1, accuracy = 0.1)
)
record_chart(
  "Housing",
  "Housing supply growth",
  "housing_supply_growth_rate",
  "charts/02_housing/housing_supply_growth_rate.png",
  "Shows the expanded historical series without bridging the Census vintage boundary."
)

# ---------------------------------------------------------------------------
# 03. Economy and service capacity
# ---------------------------------------------------------------------------

capacity <- data |>
  select(state, year, homeless_rate_for_plot, total_beds_per_10k) |>
  pivot_longer(
    c(homeless_rate_for_plot, total_beds_per_10k),
    names_to = "series",
    values_to = "rate"
  ) |>
  mutate(
    series = recode(
      series,
      homeless_rate_for_plot = "Homelessness rate",
      total_beds_per_10k = "Total beds"
    )
  )

capacity_plot <- ggplot(
  capacity,
  aes(year, rate, color = series)
) +
  shade_2021 +
  geom_line(linewidth = 1.15, na.rm = TRUE) +
  geom_point(size = 2.2, na.rm = TRUE) +
  facet_wrap(~state, ncol = 1, scales = "free_y") +
  scale_color_manual(values = series_colors) +
  year_scale +
  labs(
    title = "Recorded homelessness and bed capacity",
    subtitle = "Both series are expressed per 10,000 residents",
    x = NULL,
    y = "Rate per 10,000 residents",
    color = NULL,
    caption = source_caption
  ) +
  base_theme

path <- save_chart(
  capacity_plot,
  "03_economy_and_services/homelessness_and_bed_capacity.png",
  height = 7.2
)
record_chart(
  "Economy and services",
  "Homelessness and bed capacity",
  "homeless_rate_per_10k; total_beds_per_10k",
  path,
  "Uses a common population denominator and separates states into readable panels."
)

funding_plot <- plot_time_series(
  "funding_per_homeless_person",
  "Recorded state funding is highly episodic",
  "State homelessness funding divided by the PIT count",
  "Nominal dollars per person counted",
  "03_economy_and_services/funding_per_homeless_person.png",
  scales::label_dollar(accuracy = 1),
  show_2021 = TRUE
)
record_chart(
  "Economy and services",
  "Funding per person counted",
  "funding_per_homeless_person",
  "charts/03_economy_and_services/funding_per_homeless_person.png",
  "Normalizes funding while warning that the 2021 denominator is disrupted."
)

indexed <- data |>
  select(
    state, year,
    real_personal_income_per_capita_2025_usd,
    real_median_home_price_2025_usd
  ) |>
  pivot_longer(
    -c(state, year),
    names_to = "series",
    values_to = "value"
  ) |>
  group_by(state, series) |>
  mutate(index_2010 = 100 * value / value[year == 2010]) |>
  ungroup() |>
  mutate(
    series = recode(
      series,
      real_personal_income_per_capita_2025_usd = "Real personal income",
      real_median_home_price_2025_usd = "Real home price"
    )
  )

indexed_plot <- ggplot(
  indexed,
  aes(year, index_2010, color = series)
) +
  geom_hline(yintercept = 100, linetype = "dashed", color = "grey60") +
  geom_line(linewidth = 1.15) +
  geom_point(size = 2.1) +
  facet_wrap(~state, ncol = 1) +
  scale_color_manual(values = series_colors) +
  year_scale +
  labs(
    title = "Real home prices outpaced personal income",
    subtitle = "Each series is indexed to 100 in 2010",
    x = NULL,
    y = "Index (2010 = 100)",
    color = NULL,
    caption = "Source: updated DSA Group 10 panel; CPI-U via U.S. BLS/FRED."
  ) +
  base_theme

path <- save_chart(
  indexed_plot,
  "03_economy_and_services/real_income_vs_home_price_index.png",
  height = 7.2
)
record_chart(
  "Economy and services",
  "Real income versus home-price index",
  "real_personal_income_per_capita_2025_usd; real_median_home_price_2025_usd",
  path,
  "Indexing compares growth rates without a misleading dual axis."
)

# ---------------------------------------------------------------------------
# 04. Relationships designed to reduce state/time confounding
# ---------------------------------------------------------------------------

within_state <- data |>
  filter(pit_count_caution_flag == 0) |>
  group_by(state) |>
  mutate(
    vacancy_deviation =
      rental_vacancy_rate - mean(rental_vacancy_rate, na.rm = TRUE),
    homelessness_deviation =
      homeless_rate_per_10k - mean(homeless_rate_per_10k, na.rm = TRUE)
  ) |>
  ungroup()

within_vacancy_plot <- ggplot(
  within_state,
  aes(vacancy_deviation, homelessness_deviation, color = year, shape = state)
) +
  geom_hline(yintercept = 0, color = "grey70") +
  geom_vline(xintercept = 0, color = "grey70") +
  geom_smooth(
    data = within_state,
    aes(
      x = vacancy_deviation,
      y = homelessness_deviation,
      group = 1
    ),
    method = "lm", se = TRUE,
    color = "grey25", fill = "grey75",
    linewidth = 0.9,
    inherit.aes = FALSE
  ) +
  geom_point(size = 3) +
  scale_color_gradient(low = "#F2C14E", high = "#5B2C83") +
  labs(
    title = "Within-state vacancy deviations and homelessness",
    subtitle = "State means are removed; 2021 is excluded",
    x = "Rental vacancy rate: deviation from state mean",
    y = "Homelessness rate: deviation from state mean",
    color = "Year",
    shape = NULL,
    caption = paste0(
      "Exploratory association only. Removing state means reduces, but does not ",
      "eliminate, time trends or confounding."
    )
  ) +
  base_theme

path <- save_chart(
  within_vacancy_plot,
  "04_relationships/within_state_vacancy_vs_homelessness.png"
)
record_chart(
  "Relationships",
  "Within-state vacancy and homelessness",
  "rental_vacancy_rate; homeless_rate_per_10k",
  path,
  "Avoids treating the static California–Florida difference as the relationship."
)

lagged_permits <- data |>
  group_by(state) |>
  mutate(
    prior_year_permits_per_1000 =
      lag(permits_per_1000_housing_units)
  ) |>
  ungroup() |>
  filter(
    pit_count_caution_flag == 0,
    !is.na(prior_year_permits_per_1000),
    !is.na(homeless_rate_change_per_10k)
  )

lagged_permits_plot <- ggplot(
  lagged_permits,
  aes(
    prior_year_permits_per_1000,
    homeless_rate_change_per_10k,
    color = state
  )
) +
  geom_hline(yintercept = 0, color = "grey65", linetype = "dashed") +
  geom_point(size = 3, alpha = 0.85) +
  geom_text(
    aes(label = year),
    size = 3, vjust = -0.8,
    check_overlap = TRUE, show.legend = FALSE
  ) +
  scale_color_manual(values = state_colors) +
  labs(
    title = "Prior-year permitting versus change in homelessness",
    subtitle = "Lagging the predictor clarifies timing; changes involving 2021 are excluded",
    x = "Prior-year permits per 1,000 housing units",
    y = "Annual change in homelessness rate",
    color = NULL,
    caption = "Exploratory association; no causal claim is implied."
  ) +
  base_theme

path <- save_chart(
  lagged_permits_plot,
  "04_relationships/lagged_permits_vs_homelessness_change.png"
)
record_chart(
  "Relationships",
  "Lagged permits and homelessness change",
  "lag(permits_per_1000_housing_units); homeless_rate_change_per_10k",
  path,
  "Uses temporal ordering and a change outcome instead of a raw cross-state trend."
)

price_change <- data |>
  filter(
    pit_count_caution_flag == 0,
    !is.na(real_home_price_growth_pct),
    !is.na(homeless_rate_change_per_10k)
  )

price_change_plot <- ggplot(
  price_change,
  aes(real_home_price_growth_pct, homeless_rate_change_per_10k, color = state)
) +
  geom_hline(yintercept = 0, color = "grey65") +
  geom_vline(xintercept = 0, color = "grey65") +
  geom_point(size = 3, alpha = 0.85) +
  geom_text(
    aes(label = year),
    size = 3, vjust = -0.8,
    check_overlap = TRUE, show.legend = FALSE
  ) +
  scale_color_manual(values = state_colors) +
  scale_x_continuous(labels = scales::label_percent(scale = 1, accuracy = 1)) +
  labs(
    title = "Annual real home-price growth and homelessness change",
    subtitle = "First differences reduce long-run trend confounding; changes involving 2021 are excluded",
    x = "Real home-price growth",
    y = "Change in homelessness rate per 10,000",
    color = NULL,
    caption = "Exploratory association; annual changes remain noisy with only two states."
  ) +
  base_theme

path <- save_chart(
  price_change_plot,
  "04_relationships/home_price_growth_vs_homelessness_change.png"
)
record_chart(
  "Relationships",
  "Home-price growth and homelessness change",
  "real_home_price_growth_pct; homeless_rate_change_per_10k",
  path,
  "Compares within-state annual changes rather than raw levels."
)

# Selected within-state correlation matrix.
correlation_variables <- c(
  "homeless_rate_per_10k",
  "unsheltered_share_pct",
  "rental_vacancy_rate",
  "housing_units_per_capita",
  "permits_per_1000_housing_units",
  "home_price_to_income_ratio",
  "unemployment_rate",
  "poverty_rate",
  "total_beds_per_10k",
  "funding_per_homeless_person"
)

correlation_labels <- c(
  homeless_rate_per_10k = "Homeless rate",
  unsheltered_share_pct = "Unsheltered share",
  rental_vacancy_rate = "Rental vacancy",
  housing_units_per_capita = "Housing per capita",
  permits_per_1000_housing_units = "Permit intensity",
  home_price_to_income_ratio = "Price / income",
  unemployment_rate = "Unemployment",
  poverty_rate = "Poverty",
  total_beds_per_10k = "Total beds",
  funding_per_homeless_person = "Funding / homeless person"
)

correlation_data <- data |>
  filter(pit_count_caution_flag == 0) |>
  select(state, all_of(correlation_variables)) |>
  group_by(state) |>
  mutate(across(all_of(correlation_variables), ~.x - mean(.x, na.rm = TRUE))) |>
  ungroup() |>
  select(all_of(correlation_variables))

correlation_matrix <- suppressWarnings(
  cor(correlation_data, use = "pairwise.complete.obs")
)
pairwise_n <- outer(
  correlation_variables,
  correlation_variables,
  Vectorize(function(x, y) {
    sum(complete.cases(correlation_data[c(x, y)]))
  })
)
dimnames(pairwise_n) <- list(correlation_variables, correlation_variables)

write.csv(
  correlation_matrix,
  file.path(output_root, "04_relationships", "selected_within_state_correlations.csv")
)
write.csv(
  pairwise_n,
  file.path(output_root, "04_relationships", "selected_pairwise_sample_sizes.csv")
)

correlation_long <- as.data.frame(as.table(correlation_matrix))
names(correlation_long) <- c("variable_x", "variable_y", "correlation")
correlation_long <- correlation_long |>
  mutate(
    label_x = unname(correlation_labels[as.character(variable_x)]),
    label_y = unname(correlation_labels[as.character(variable_y)]),
    label_x = factor(label_x, levels = unname(correlation_labels)),
    label_y = factor(label_y, levels = rev(unname(correlation_labels)))
  )

correlation_plot <- ggplot(
  correlation_long,
  aes(label_x, label_y, fill = correlation)
) +
  geom_tile(color = "white", linewidth = 0.5) +
  geom_text(
    aes(label = ifelse(is.na(correlation), "", sprintf("%.2f", correlation))),
    size = 3
  ) +
  scale_fill_gradient2(
    low = "#2A6FBB", mid = "white", high = "#C44E52",
    midpoint = 0, limits = c(-1, 1), na.value = "grey80"
  ) +
  coord_fixed() +
  labs(
    title = "Selected within-state correlations",
    subtitle = "State means removed; 2021 excluded; pairwise-complete observations",
    x = NULL, y = NULL, fill = "Correlation",
    caption = paste0(
      "Exploratory only. Correlation does not establish causation, and ",
      "pairwise sample sizes vary."
    )
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid = element_blank(),
    axis.text.x = element_text(angle = 45, hjust = 1),
    plot.title = element_text(face = "bold", size = 15),
    plot.title.position = "plot"
  )

path <- save_chart(
  correlation_plot,
  "04_relationships/selected_within_state_correlation_heatmap.png",
  width = 10,
  height = 8.5
)
record_chart(
  "Relationships",
  "Selected within-state correlation heatmap",
  paste(correlation_variables, collapse = "; "),
  path,
  "Replaces the unreadable 43-variable raw correlation matrix with a focused, de-meaned matrix."
)

# ---------------------------------------------------------------------------
# 05. Data quality and completeness
# ---------------------------------------------------------------------------

dictionary_file <- "DSA_Group_10_updated.xlsx"
if (file.exists(dictionary_file) && requireNamespace("openxlsx", quietly = TRUE)) {
  dictionary <- openxlsx::read.xlsx(dictionary_file, sheet = "Variable Dictionary")
} else {
  dictionary <- tibble(
    variable = names(data),
    category = "Unknown",
    definition = tools::toTitleCase(gsub("_", " ", names(data))),
    source_status = "Unknown",
    available_rows = vapply(data, function(x) sum(!is.na(x)), integer(1)),
    total_rows = nrow(data),
    missing_rows = vapply(data, function(x) sum(is.na(x)), integer(1))
  )
}

variables_with_missing <- dictionary |>
  filter(missing_rows > 0, !variable %in% c("state_year", "state", "year")) |>
  arrange(category, desc(missing_rows)) |>
  pull(variable)

coverage_long <- data |>
  select(state, year, all_of(variables_with_missing)) |>
  pivot_longer(
    -c(state, year),
    names_to = "variable",
    values_to = "value"
  ) |>
  mutate(
    status = if_else(is.na(value), "Missing", "Available"),
    variable = factor(variable, levels = rev(variables_with_missing))
  )

coverage_plot <- ggplot(
  coverage_long,
  aes(year, variable, fill = status)
) +
  geom_tile(color = "white", linewidth = 0.35) +
  facet_wrap(~state, ncol = 1) +
  scale_fill_manual(values = c("Available" = "#4C956C", "Missing" = "#F2C14E")) +
  scale_x_continuous(breaks = c(2010, 2013, 2016, 2019, 2022, 2025)) +
  labs(
    title = "Remaining missing-data pattern",
    subtitle = "Only variables with at least one missing state-year are shown",
    x = NULL,
    y = NULL,
    fill = NULL,
    caption = "Blank values were preserved; no statistical imputation was used."
  ) +
  theme_minimal(base_size = 10) +
  theme(
    panel.grid = element_blank(),
    strip.text = element_text(face = "bold"),
    plot.title = element_text(face = "bold", size = 15),
    plot.title.position = "plot",
    legend.position = "top"
  )

path <- save_chart(
  coverage_plot,
  "05_data_quality/missing_data_heatmap.png",
  width = 10,
  height = 9
)
record_chart(
  "Data quality",
  "Missing-data heatmap",
  paste(variables_with_missing, collapse = "; "),
  path,
  "Makes gaps explicit instead of hiding them in regressions or broken lines."
)

category_completeness <- dictionary |>
  filter(!category %in% c("Identifier", "Data quality")) |>
  group_by(category) |>
  summarise(
    variables = n(),
    possible_cells = sum(total_rows),
    available_cells = sum(available_rows),
    completeness_pct = 100 * available_cells / possible_cells,
    .groups = "drop"
  ) |>
  arrange(completeness_pct)

category_plot <- ggplot(
  category_completeness,
  aes(completeness_pct, reorder(category, completeness_pct))
) +
  geom_col(fill = "#4C78A8", width = 0.7) +
  geom_text(
    aes(label = sprintf("%.0f%%", completeness_pct)),
    hjust = -0.15, size = 3.8
  ) +
  scale_x_continuous(
    limits = c(0, 105),
    breaks = seq(0, 100, 20),
    labels = scales::label_percent(scale = 1)
  ) +
  labs(
    title = "Data completeness by variable category",
    subtitle = "Available state-year cells divided by possible cells",
    x = "Completeness",
    y = NULL,
    caption = "Source: updated workbook Variable Dictionary."
  ) +
  base_theme +
  theme(legend.position = "none")

path <- save_chart(
  category_plot,
  "05_data_quality/category_completeness.png",
  width = 9,
  height = 6.5
)
record_chart(
  "Data quality",
  "Category completeness",
  "all categorized variables",
  path,
  "Summarizes where additional sourcing work would have the greatest value."
)

# ---------------------------------------------------------------------------
# 06. Factor-by-factor scatterplots against homelessness rate
# ---------------------------------------------------------------------------

# Exclude identifiers, the target, alternate outcomes, target components, and
# ratios that mechanically contain the target in their denominator.
scatterplot_exclusions <- tibble(
  variable = c(
    "year",
    "homeless_rate_per_10k",
    "homeless_rate_for_plot",
    "total_homeless",
    "sheltered_homeless",
    "unsheltered_homeless",
    "homeless_rate_change_per_10k",
    "pit_count_caution_flag",
    "beds_per_100_homeless",
    "funding_per_homeless_person",
    "foreclosure_rate"
  ),
  reason = c(
    "Time is already shown directly in the time-series charts.",
    "This is the scatterplot outcome.",
    "Temporary plotting copy of the outcome, not a dataset variable.",
    "Raw total is mechanically and population-related to the rate outcome.",
    "Component of the total homelessness count.",
    "Component of the total homelessness count.",
    "Alternate homelessness outcome derived from the target.",
    "Data-quality flag rather than a substantive factor.",
    "Contains homelessness rate in its denominator.",
    "Contains total homelessness in its denominator.",
    "All 32 values are missing."
  )
)

numeric_variables <- names(data)[vapply(data, is.numeric, logical(1))]
scatter_variables <- setdiff(
  numeric_variables,
  scatterplot_exclusions$variable
)
scatter_variables <- scatter_variables[vapply(
  scatter_variables,
  function(variable) {
    plot_data <- data |>
      filter(
        year != 2021L,
        !is.na(homeless_rate_per_10k),
        !is.na(.data[[variable]])
      )
    nrow(plot_data) >= 4 && n_distinct(plot_data[[variable]]) >= 2
  },
  logical(1)
)]

scatterplot_inventory <- tibble(variable = scatter_variables) |>
  left_join(
    dictionary |>
      select(any_of(c("variable", "category", "definition", "source_status"))),
    by = "variable"
  ) |>
  mutate(
    available_non2021_rows = vapply(
      variable,
      function(v) {
        sum(
          data$year != 2021L &
            !is.na(data$homeless_rate_per_10k) &
            !is.na(data[[v]])
        )
      },
      integer(1)
    )
  )

for (variable in scatter_variables) {
  plot_data <- data |>
    filter(
      year != 2021L,
      !is.na(homeless_rate_per_10k),
      !is.na(.data[[variable]])
    )

  dictionary_row <- dictionary |>
    filter(.data$variable == .env$variable) |>
    slice(1)
  variable_label <- if (
    nrow(dictionary_row) == 1 &&
      "definition" %in% names(dictionary_row) &&
      !is.na(dictionary_row$definition[1])
  ) {
    dictionary_row$definition[1]
  } else {
    tools::toTitleCase(gsub("_", " ", variable))
  }
  source_status <- if (
    nrow(dictionary_row) == 1 &&
      "source_status" %in% names(dictionary_row) &&
      !is.na(dictionary_row$source_status[1])
  ) {
    dictionary_row$source_status[1]
  } else {
    "Unknown"
  }

  scatter_plot <- ggplot(
    plot_data,
    aes(
      x = .data[[variable]],
      y = homeless_rate_per_10k,
      color = year
    )
  ) +
    geom_point(size = 2.8, alpha = 0.85) +
    facet_wrap(~state, scales = "free_x") +
    scale_color_viridis_c(
      option = "C",
      end = 0.9,
      breaks = c(2010, 2015, 2020, 2025)
    ) +
    scale_y_continuous(labels = scales::label_number(accuracy = 0.1)) +
    labs(
      title = paste(
        tools::toTitleCase(gsub("_", " ", variable)),
        "and homelessness rate"
      ),
      subtitle = paste0(
        "Descriptive state-year scatterplot; ",
        nrow(plot_data),
        " observations; 2021 PIT count excluded"
      ),
      x = variable_label,
      y = "People experiencing homelessness per 10,000 residents",
      color = "Year",
      caption = paste0(
        "No fitted line is shown because state and time trends can confound ",
        "the relationship. Source status: ",
        source_status,
        "."
      )
    ) +
    base_theme +
    theme(
      plot.caption = element_text(size = 8.5),
      legend.position = "top"
    )

  if (n_distinct(plot_data[[variable]]) <= 6) {
    scatter_plot <- scatter_plot +
      scale_x_continuous(breaks = sort(unique(plot_data[[variable]])))
  }

  relative_path <- file.path(
    "06_scatterplots",
    paste0(variable, "_vs_homeless_rate.png")
  )
  path <- save_chart(
    scatter_plot,
    relative_path,
    width = 9,
    height = 5.8
  )
  record_chart(
    "Scatterplots",
    paste(
      tools::toTitleCase(gsub("_", " ", variable)),
      "versus homelessness rate"
    ),
    paste(variable, "homeless_rate_per_10k", sep = "; "),
    path,
    paste0(
      "State-faceted descriptive scatterplot with year encoded by color; ",
      "2021 excluded and no fitted trend line."
    )
  )
}

write_csv(
  scatterplot_inventory,
  file.path(output_root, "scatterplot_inventory.csv")
)
write_csv(
  scatterplot_exclusions,
  file.path(output_root, "scatterplot_exclusions.csv")
)

key_chart_paths <- c(
  "charts/01_outcomes/homelessness_rate_over_time.png",
  "charts/02_housing/home_price_to_income_ratio.png",
  "charts/02_housing/rental_vacancy_rate.png",
  "charts/02_housing/housing_units_per_1000_residents.png",
  "charts/02_housing/permits_per_1000_housing_units.png",
  "charts/03_economy_and_services/homelessness_and_bed_capacity.png"
)
key_chart_manifest <- manifest |>
  filter(path %in% key_chart_paths) |>
  mutate(display_order = match(path, key_chart_paths)) |>
  arrange(display_order) |>
  select(display_order, everything())
stopifnot(nrow(key_chart_manifest) == 6)
write_csv(
  key_chart_manifest,
  file.path(output_root, "key_chart_manifest.csv")
)

write_csv(manifest, file.path(output_root, "chart_manifest.csv"))

cat(
  "Created", nrow(manifest), "charts, including",
  length(scatter_variables), "factor scatterplots, in",
  normalizePath(output_root), "\n"
)
