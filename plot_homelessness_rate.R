library(ggplot2)

data_path <- "DSA Group 10 - Sheet1.csv"
output_path <- "homelessness_rate_CA_FL_over_time.png"

homelessness <- read.csv(data_path, check.names = FALSE)
names(homelessness)[1] <- "state_year"

plot_data <- transform(
  homelessness,
  state = sub(" [0-9]{4}$", "", state_year),
  year = as.integer(sub("^.* ([0-9]{4})$", "\\1", state_year))
)[, c("state", "year", "homeless_rate_per_10k")]

stopifnot(
  nrow(plot_data) == 32,
  !anyDuplicated(plot_data[c("state", "year")]),
  all(sort(unique(plot_data$state)) == c("California", "Florida")),
  all(range(plot_data$year) == c(2010, 2025)),
  !anyNA(plot_data)
)

rate_plot <- ggplot(
  plot_data,
  aes(x = year, y = homeless_rate_per_10k, color = state, group = state)
) +
  geom_line(linewidth = 1.1) +
  geom_point(size = 2.3) +
  scale_color_manual(
    values = c("California" = "#D55E00", "Florida" = "#0072B2")
  ) +
  scale_x_continuous(breaks = 2010:2025) +
  labs(
    title = "Homelessness Rate Over Time: California vs. Florida",
    subtitle = "Recorded rate per 10,000 residents, 2010-2025",
    x = "Year",
    y = "Homelessness rate per 10,000 residents",
    color = "State",
    caption = "Source: DSA Group 10 - Sheet1.csv"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "top",
    panel.grid.minor = element_blank(),
    axis.text.x = element_text(angle = 45, hjust = 1),
    plot.title.position = "plot"
  )

ggsave(
  output_path,
  plot = rate_plot,
  width = 9,
  height = 5.4,
  units = "in",
  dpi = 300,
  bg = "white"
)

print(rate_plot)
