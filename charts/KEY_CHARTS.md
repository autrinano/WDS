# Goal of the study and key EDA charts

## Study goal

The goal is to explain why homelessness rates diverged between California and Florida from 2010 through 2025 by examining the full system of candidate factors. Those factors span housing affordability, rental-market tightness, housing stock and new supply, economic conditions, policy and benefits, homelessness services, demographics, health, education, and climate.

This is preliminary exploratory data analysis (EDA). The charts show distributions, trends, missingness, and associations. They do **not** estimate the causal impact or independent contribution of a variable. That requires a later multivariable, time-aware analysis that accounts for state differences, common time trends, lags, collinearity, and the small sample.

## Core study-wide chart sequence

### 1. Establish the outcome that the study must explain

[Homelessness rate over time](01_outcomes/homelessness_rate_over_time.png)

California and Florida begin with much closer homelessness rates and then follow different trajectories. The remaining charts examine the broader set of candidate explanations. The disrupted 2021 PIT count is marked and is not treated as an ordinary annual observation.

### 2. Screen every eligible factor

[All-factor association screen](07_goal_eda/all_factor_association_screen.png)

This is the main relationship overview. It displays all 51 eligible numeric factors using two exploratory summaries: within-state correlations and correlations between annual changes. It prevents the project narrative from being built around one convenient variable. Point size shows the number of usable state-years, so sparse factors are visibly less certain.

Read this chart as a screening tool, not a ranking of causal impacts. The two panels ask different questions, variables overlap conceptually, correlations are not adjusted for the other factors, and shared trends can remain.

### 3. Compare whole categories of explanations

[Category association summary](07_goal_eda/category_association_summary.png)

This summarizes the median absolute association across every eligible variable in each category. It reveals whether the preliminary signal is concentrated in housing, economic, policy, service, demographic, health, education, climate, or other groups rather than treating any single column as the complete explanation. Absolute correlations show strength but not direction.

Category results must be interpreted with the number and quality of variables in each group. They are descriptive summaries, not category-level causal effects.

### 4. Examine relationships among selected concepts

[Selected within-state correlation heatmap](04_relationships/selected_within_state_correlation_heatmap.png)

The heatmap shows how representative outcome, housing, economic, and service measures move together after removing each state's mean and excluding 2021. Its purpose is to identify clusters, redundancy, and possible multicollinearity before modeling. It complements the all-factor screen; it does not replace it.

### 5. Make missing evidence visible

[Missing-data heatmap](05_data_quality/missing_data_heatmap.png)

This shows exactly which state-years are unavailable. It is essential to the study because an apparent weak relationship may reflect short coverage rather than weak importance, and different models may otherwise use different subsets of years.

### 6. Compare evidence coverage across categories

[Category completeness](05_data_quality/category_completeness.png)

This summarizes coverage by factor category. Categories with limited historical coverage should receive less interpretive weight and may require separate analysis panels or sensitivity checks.

### 7. Compare state distributions across representative mechanisms

[Key factor state boxplots](07_goal_eda/key_factor_state_boxplots.png)

The boxplots provide a compact California–Florida comparison for the outcome and representative housing and service measures. They show persistent differences and overlap, but they discard time order. Use them only alongside the time-series and study-wide association charts.

## Mechanism follow-ups

The following charts add substantive context after the full factor set has been shown. They are examples of mechanisms to investigate, not the study's entire explanation.

### 8. Housing affordability

[Home-price-to-income ratio](02_housing/home_price_to_income_ratio.png)

This compares median sale price with median household income. It is more interpretable than a raw price comparison but does not isolate housing cost from income, migration, supply, or policy.

### 9. Rental-market tightness

[Rental vacancy rate](02_housing/rental_vacancy_rate.png)

This shows whether households faced different levels of rental-market slack in the two states. Vacancy is one part of the broader housing system, not a standalone causal conclusion.

### 10. New housing supply

[Permits per 1,000 housing units](02_housing/permits_per_1000_housing_units.png)

Permits are normalized to the existing housing stock. They indicate authorized future supply, not starts or completed homes, and their relationship with homelessness may be lagged.

### 11. Homelessness-service capacity

[Homelessness and bed capacity](03_economy_and_services/homelessness_and_bed_capacity.png)

This places homelessness and recorded shelter-plus-PSH capacity on a common population denominator. Capacity may respond to homelessness as well as affect it, so the relationship may be simultaneous.

## Individual-variable appendix

The `06_scatterplots/` folder contains 51 state-faceted scatterplots—one for every eligible numeric factor. These plots are valuable for checking nonlinearity, outliers, state-specific patterns, time ordering, and limited coverage. They should be treated as an appendix to the study-wide screens, not as 51 separate claims of impact.

When presenting results, use **associated with**, **moves with**, or **candidate explanation**. Reserve **impact**, **effect**, and **independent contribution** for a later design that supports those claims. The next analytical step should compare a state-and-time baseline with a small, theory-guided multivariable model using time-based validation and lagged sensitivity checks.
