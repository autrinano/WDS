## ---------------------------------------------------------------------------
## build_2021_descriptive_series.R
##
## Builds a SEPARATE descriptive dataset of CoC homelessness rates that
## INCLUDES 2021, purely so the 2021 dip can be plotted.
##
## ===========================================================================
##  THIS OUTPUT IS FOR PLOTTING ONLY. IT MUST NEVER BE MERGED INTO
##  CA_FL_LASSO_MODEL_INPUT_v2.xlsx OR USED AS A MODELING TARGET.
## ===========================================================================
##
## 2021 is excluded from every model in this project because COVID disrupted the
## Point-in-Time count. This script does not overturn that decision -- it makes
## the disruption visible, and carries the evidence for it in the data.
##
## The key column is `count_type`. HUD requires an unsheltered count only in odd
## years; in 2021 it waived that requirement, so most CoCs counted sheltered
## people only. Comparing the two adjacent odd years:
##
##     2019:  0 of 71 CoCs were sheltered-only
##     2021: 47 of 71 CoCs were sheltered-only  (66%)
##
## So the 2021 "drop" is very largely a change in WHAT WAS COUNTED, not a
## change in how many people were homeless. Any plot of this series must say so.
##
## Writes only to outputs/descriptive_2021/.
## ---------------------------------------------------------------------------

.libPaths(c(file.path(getwd(), "_r_libs"), .libPaths()))
suppressMessages({
  library(dplyr)
  library(ggplot2)
})

IN  <- "coc_analysis/coc_year_homelessness_outcomes_CA_FL_2010_2025.csv"
OUT <- "outputs/descriptive_2021"

dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

write_owned <- function(x, path) {
  norm <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  root <- normalizePath(OUT,           winslash = "/", mustWork = TRUE)
  if (!startsWith(norm, root)) stop("Refusing to write outside ", OUT)
  utils::write.csv(x, path, row.names = FALSE)
  invisible(path)
}

## ---------------------------------------------------------------------------
## 1. Load the official CoC outcomes, keeping 2021
## ---------------------------------------------------------------------------

raw <- read.csv(IN, stringsAsFactors = FALSE)

coc_rates <- raw %>%
  filter(!is.na(homeless_rate_per_10k_estimated)) %>%
  transmute(
    state, state_abbr, coc_number, coc_name, year,
    homeless_rate_per_10k = homeless_rate_per_10k_estimated,
    total_homeless, sheltered_homeless, unsheltered_homeless,
    estimated_population = estimated_coc_population,
    count_type,
    # the single most important column for interpreting this series
    sheltered_only_count = grepl("Sheltered-Only", count_type, fixed = TRUE),
    pit_count_caution_flag,
    # spell out why a row should be treated with care
    interpretation_note = ifelse(
      year == 2021,
      "2021: COVID-disrupted PIT. HUD waived the unsheltered-count requirement. NOT comparable to other years.",
      ifelse(grepl("Sheltered-Only", count_type, fixed = TRUE),
             "Sheltered-only count: unsheltered people were not enumerated this year.",
             "Full sheltered + unsheltered enumeration."))
  ) %>%
  arrange(state, coc_number, year)

write_owned(coc_rates, file.path(OUT, "coc_homeless_rate_by_year_INCLUDING_2021.csv"))

## ---------------------------------------------------------------------------
## 2. State-year averages -- the series you actually plot
##
## Unweighted mean across CoCs, matching how the project's other trend plots
## are built. A small rural CoC counts the same as a large metro one.
## ---------------------------------------------------------------------------

state_year <- coc_rates %>%
  group_by(state, year) %>%
  summarise(
    n_cocs             = n(),
    mean_rate_per_10k  = mean(homeless_rate_per_10k),
    median_rate_per_10k = median(homeless_rate_per_10k),
    n_sheltered_only   = sum(sheltered_only_count),
    pct_sheltered_only = 100 * mean(sheltered_only_count),
    .groups = "drop"
  ) %>%
  mutate(comparable_to_neighbours = year != 2021)

write_owned(state_year, file.path(OUT, "state_mean_rate_by_year_INCLUDING_2021.csv"))

## ---------------------------------------------------------------------------
## 3. How big is the dip, and how much of it is the count change?
## ---------------------------------------------------------------------------

context <- coc_rates %>%
  filter(year %in% c(2019, 2020, 2021, 2022)) %>%
  group_by(state, year) %>%
  summarise(mean_rate = mean(homeless_rate_per_10k),
            pct_sheltered_only = 100 * mean(sheltered_only_count),
            .groups = "drop")

write_owned(context, file.path(OUT, "dip_context_2019_2022.csv"))

## Compare the two adjacent ODD years. Both should have been full counts.
odd_compare <- coc_rates %>%
  filter(year %in% c(2019, 2021)) %>%
  group_by(year) %>%
  summarise(n_cocs = n(),
            n_sheltered_only = sum(sheltered_only_count),
            pct_sheltered_only = 100 * mean(sheltered_only_count),
            mean_rate = mean(homeless_rate_per_10k),
            .groups = "drop")

write_owned(odd_compare, file.path(OUT, "odd_year_comparison_2019_vs_2021.csv"))

## Within the CoCs that DID run a full count in 2021, was there still a dip?
## This is the closest thing to an apples-to-apples check.
full_2021 <- coc_rates$coc_number[coc_rates$year == 2021 & !coc_rates$sheltered_only_count]

like_for_like <- coc_rates %>%
  filter(coc_number %in% full_2021, year %in% 2019:2022, !sheltered_only_count) %>%
  group_by(year) %>%
  summarise(n_cocs = n(), mean_rate = mean(homeless_rate_per_10k), .groups = "drop")

write_owned(like_for_like, file.path(OUT, "like_for_like_full_count_cocs.csv"))

## ---------------------------------------------------------------------------
## 4. The plot
## ---------------------------------------------------------------------------

p <- ggplot(state_year, aes(x = year, y = mean_rate_per_10k, colour = state)) +
  annotate("rect", xmin = 2020.5, xmax = 2021.5, ymin = -Inf, ymax = Inf,
           fill = "grey70", alpha = 0.25) +
  annotate("text", x = 2021, y = max(state_year$mean_rate_per_10k) * 1.13,
           label = "2021\nCOVID-disrupted count", size = 2.9, colour = "grey25",
           lineheight = 0.95) +
  expand_limits(y = max(state_year$mean_rate_per_10k) * 1.20) +
  geom_line(linewidth = 0.9) +
  geom_point(aes(shape = comparable_to_neighbours), size = 2.2) +
  scale_shape_manual(values = c(`TRUE` = 19, `FALSE` = 1), guide = "none") +
  scale_colour_manual(values = c(California = "#1b7f8c", Florida = "#b3771f")) +
  scale_x_continuous(breaks = seq(2010, 2025, 2)) +
  labs(
    title = "Average CoC homelessness rate, California vs Florida",
    subtitle = "Unweighted mean across CoCs. Among the 24 CoCs that ran a full count in both 2019 and 2021,\nthe rate was unchanged (21.0 vs 21.1) - the dip is a counting artifact, not a real decline.",
    x = NULL, y = "Homeless rate per 10,000 residents", colour = NULL,
    caption = "Hollow point = 2021, not comparable with neighbouring years. Source: HUD PIT counts."
  ) +
  theme_bw(base_size = 11) +
  theme(legend.position = "bottom",
        plot.subtitle = element_text(size = 8.5, colour = "grey30"),
        plot.caption  = element_text(size = 7.5, colour = "grey45", hjust = 0))

ggsave(file.path(OUT, "FIG_homeless_rate_with_2021_dip.png"), p,
       width = 8, height = 4.6, dpi = 150)

## Second panel: the dip next to the measurement change that produced it.
p2 <- ggplot(state_year, aes(x = year, y = pct_sheltered_only, fill = state)) +
  geom_col(position = "dodge") +
  scale_fill_manual(values = c(California = "#1b7f8c", Florida = "#b3771f")) +
  scale_x_continuous(breaks = seq(2010, 2025, 2)) +
  labs(title = "Share of CoCs that counted sheltered people only",
       subtitle = "HUD requires an unsheltered count in odd years. In 2021 it waived that requirement.",
       x = NULL, y = "% of CoCs, sheltered-only", fill = NULL) +
  theme_bw(base_size = 11) +
  theme(legend.position = "bottom",
        plot.subtitle = element_text(size = 8.5, colour = "grey30"))

ggsave(file.path(OUT, "FIG_sheltered_only_share_by_year.png"), p2,
       width = 8, height = 4, dpi = 150)

## ---------------------------------------------------------------------------
## 5. Console summary
## ---------------------------------------------------------------------------

cat("\n=== Rows written ===\n")
cat("CoC-year rows (all years, incl. 2021):", nrow(coc_rates), "\n")
cat("2021 rows:", sum(coc_rates$year == 2021), "CoCs\n")

cat("\n=== The dip ===\n")
print(as.data.frame(context), row.names = FALSE)

cat("\n=== Two adjacent odd years, both of which should have been full counts ===\n")
print(as.data.frame(odd_compare), row.names = FALSE)

cat("\n=== CoCs that ran a FULL count in 2021: was there still a dip? ===\n")
print(as.data.frame(like_for_like), row.names = FALSE)

cat("\nOutputs in", OUT, "\n")
cat("REMINDER: descriptive only. Do not use 2021 as a modeling target.\n")
