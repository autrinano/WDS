# Goal of the study and six key charts

## Study goal

The goal is to explain why homelessness rates diverged between California and Florida from 2010 through 2025. The project examines housing affordability, rental-market tightness, housing stock and new supply, economic conditions, policy, and homelessness-service capacity as candidate explanations for the different state trajectories.

This is preliminary exploratory data analysis. The broad directional trends are expected to remain similar as data sources are refined, but exact values, sample sizes, and relationships may change. These charts identify patterns to investigate; they do not establish causal effects.

## Recommended chart sequence

### 1. Establish the divergence

[Homelessness rate over time](01_outcomes/homelessness_rate_over_time.png)

This is the outcome chart. It shows the paths that the remaining charts are intended to help explain: California's rate rises after the middle of the period while Florida's rate declines and remains substantially lower. The disrupted 2021 PIT count is marked and should not be interpreted as an ordinary annual observation.

### 2. Housing affordability

[Home-price-to-income ratio](02_housing/home_price_to_income_ratio.png)

This compares the number of years of median household income represented by the median sale price. California has a consistently higher price-to-income ratio, making affordability a plausible contributor to the divergence. The chart is descriptive and does not isolate housing cost from income, migration, or policy.

### 3. Rental-market tightness

[Rental vacancy rate](02_housing/rental_vacancy_rate.png)

Florida has consistently more rental vacancy than California. A tighter rental market can reduce the margin for households facing income or housing shocks, making vacancy a central candidate mechanism.

### 4. Existing housing stock

[Housing units per 1,000 residents](02_housing/housing_units_per_1000_residents.png)

This normalizes the housing stock for population, avoiding a misleading comparison of raw state totals. It provides the stock-side context for interpreting price, vacancy, and homelessness differences.

### 5. New housing supply

[Permits per 1,000 housing units](02_housing/permits_per_1000_housing_units.png)

This compares newly authorized units relative to each state's existing housing stock. Permits are a forward-looking supply indicator, but they are not construction starts or completed homes and may affect homelessness only with a lag.

### 6. Homelessness-system capacity

[Homelessness and bed capacity](03_economy_and_services/homelessness_and_bed_capacity.png)

This places the homelessness rate and recorded shelter-plus-PSH bed capacity on the same population denominator. It broadens the explanation beyond housing markets and shows that the two states also have different service-capacity trajectories. Bed capacity may respond to homelessness as well as affect outcomes, so the relationship is potentially simultaneous.

## Presentation guidance

Present the charts in the order above. State the outcome divergence first, then organize the possible explanations into affordability, market tightness, existing stock, new supply, and service capacity. Avoid saying that any one chart proves a cause. Later modeling should use state and time terms, lagged predictors where appropriate, and time-based validation.
