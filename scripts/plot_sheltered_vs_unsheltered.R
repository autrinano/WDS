library(ggplot2)

data_path <- "DSA Group 10 - Sheet1.csv"
output_path <- "sheltered_vs_unsheltered_CA_FL.png"

homelessness <- read.csv(data_path, check.names = FALSE)
names(homelessness)[1] <- "state_year"

wide_data <- transform(
  homelessness,
  state = sub(" [0-9]{4}$", "", state_year),
  year = as.integer(sub("^.* ([0-9]{4})$", "\\1", state_year))
)

plot_data <- rbind(
  data.frame(
    state = wide_data$state,
    year = wide_data$year,
    housing_status = "Sheltered",
    people = wide_data$sheltered_homeless
  ),
  data.frame(
    state = wide_data$state,
    year = wide_data$year,
    housing_status = "Unsheltered",
    people = wide_data$unsheltered_homeless
  )
)

plot_data$housing_status <- factor(
  plot_data$housing_status,
  levels = c("Sheltered", "Unsheltered")
)

stopifnot(
  nrow(plot_data) == 64,
  !anyNA(plot_data),
  !anyDuplicated(plot_data[c("state", "year", "housing_status")]),
  all(wide_data$total_homeless ==
        wide_data$sheltered_homeless + wide_data$unsheltered_homeless)
)

comparison_plot <- ggplot(
  plot_data,
  aes(x = year, y = people, color = housing_status, group = housing_status)
) +
  geom_blank(
    data = data.frame(
      state = c("California", "Florida"),
      year = 2010,
      people = 0
    ),
    aes(x = year, y = people),
    inherit.aes = FALSE
  ) +
  geom_line(linewidth = 1.05) +
  geom_point(size = 2.2) +
  facet_wrap(~state, ncol = 1, scales = "free_y") +
  scale_color_manual(
    values = c("Sheltered" = "#0072B2", "Unsheltered" = "#D55E00")
  ) +
  scale_x_continuous(breaks = 2010:2025) +
  scale_y_continuous(
    labels = function(x) format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
  ) +
  labs(
    title = "Sheltered vs. Unsheltered Homelessness",
    subtitle = "California and Florida, 2010-2025",
    x = "Year",
    y = "Number of people",
    color = "Homelessness type",
    caption = paste0(
      "Source: DSA Group 10 - Sheet1.csv. ",
      "Panels use different y-axis ranges and both begin at zero.\n",
      "California's 2021 values are shown as recorded."
    )
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "top",
    panel.grid.minor = element_blank(),
    axis.text.x = element_text(angle = 45, hjust = 1),
    strip.text = element_text(face = "bold", size = 12),
    plot.title.position = "plot"
  )

ggsave(
  output_path,
  plot = comparison_plot,
  width = 9,
  height = 8,
  units = "in",
  dpi = 300,
  bg = "white"
)

print(comparison_plot)
