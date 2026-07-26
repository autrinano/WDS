# FINAL LASSO analysis — required statements (CA/FL homelessness, v2)

- Definitive input: outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx (MD5 5d3fd16b32c687e5207ea59c902e7bef; matches expected: TRUE).
- The v2 modeling dataset contains 887 rows and 70 CoCs.
- FL-518 is excluded because the FHFA House Price Index (HPI) predictor is unavailable for it.
- The 2021 PIT outcome is excluded (COVID-disrupted enumeration is not comparable across years).
- FY2024 CoC boundaries are applied retrospectively; historical CoC mergers/splits remain a measurement-error source.
- All coefficients and selection results are PREDICTIVE ASSOCIATIONS, not causal effects.
- Validation is out-of-time only: expanding-window rolling origin over target years
  2017, 2018, 2019, 2020, 2022, 2023, 2024, 2025; lambda is tuned by nested forward-chaining within each training window;
  scaling and Duan smearing are fit on training rows only; no random row splits and no in-sample metrics.
