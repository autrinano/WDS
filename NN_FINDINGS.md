# Neural network benchmark — CA/FL CoC homelessness

_Produced by [`fit_neural_net.R`](fit_neural_net.R). Outputs in
[`outputs/neural_net/`](outputs/neural_net/). No earlier model was refit and
nothing outside that directory was written._

**Everything below is a predictive association in a two-state, strongly
time-ordered panel. Nothing here is a causal effect.**

## 1. What this is

A feed-forward neural network benchmark on the same v2 input, the same eight
rolling-origin validation years, and the same training-only preprocessing rules
as the completed LASSO stage — so the two model families are directly
comparable on identical rows.

The architecture and workflow follow the Module 7 lecture (Yelp case):
`keras_model_sequential()` → dense ReLU layers → `compile()` → fit → choose the
epoch count where validation loss bottoms out → refit → evaluate once. Four
things were changed because the project requires it:

| Lecture | Here | Why |
|---|---|---|
| Classification, softmax output, cross-entropy | Regression: 1 linear output unit, MSE loss, MAE metric | The target is a continuous rate |
| `sample(n, 10000)` — random split | Rolling origin on target years 2017–2020, 2022–2025 | Project rules forbid random row splits; this also makes the LASSO comparison valid |
| `validation_split = 0.15` (random) | Most recent training year held out | A random inner split would let future years tune the model |
| No scaling needed | X and y standardised on outer training rows only, refit per fold | Learned preprocessing must fit on training years only |

Five architectures were run, including two deliberate anchors: `no_hidden`
(zero hidden layers — ordinary least squares written as a network, the
lecture's "logistic regression as a 0-layer NN" idea) and `class_16_8` (the
lecture's Yelp architecture unchanged).

| Architecture | Parameters (40 inputs) |
|---|---:|
| `no_hidden` | 41 |
| `shallow_8_drop` | 337 |
| `class_16_8` / `class_16_8_drop` | 801 |
| `wide_32_16_drop` | 1,857 |

Because the panel is small (887 rows) and network training is stochastic, every
fold was fit under **five random seeds** and the reported prediction is the seed
ensemble mean. Per-seed results are retained in
`NN_seed_variability.csv` so the seed noise is visible rather than hidden.
Epoch counts were chosen per fold by early stopping (median 59, range 3–300).

## 2. Factor model — the network beats the LASSO

Identical 555 scored rows and identical folds:

| Model | RMSE | MAE | R² |
|---|---:|---:|---:|
| NN `wide_32_16_drop` | **12.639** | 8.429 | **0.731** |
| NN `class_16_8` (lecture) | 12.917 | 9.114 | 0.719 |
| NN `class_16_8_drop` | 13.208 | 9.188 | 0.706 |
| NN `shallow_8_drop` | 13.880 | 9.751 | 0.676 |
| LASSO + state interactions (`min`) | 14.692 | 10.141 | 0.636 |
| Pooled LASSO (`min`) | 15.297 | 10.158 | 0.606 |
| NN `no_hidden` (linear) | 16.063 | 11.459 | 0.565 |
| State + time baseline | 21.931 | 14.983 | 0.190 |

All four hidden-layer networks beat every LASSO specification — a 14% RMSE
reduction for the best.

**The zero-layer anchor identifies where the gain comes from.** `no_hidden` is
unregularised OLS on 40 correlated predictors and lands *worse* than the LASSO
(16.063 vs 14.692), which is expected: there the LASSO's penalty is doing real
work. The network's advantage therefore comes from **nonlinearity**, not from
anything incidental in the fitting setup.

Accuracy improves as the expanding window grows (2017 RMSE 13.78 → 2025 RMSE
8.11), and 2019 is the weakest year — the same pattern the LASSO showed.

By state, for `class_16_8`: California RMSE 14.12 / R² 0.659, Florida RMSE
10.61 / R² 0.349. As with the LASSO, raw RMSE is not comparable across states
because Florida's outcome distribution is much narrower.

## 3. The advantage is partly ensembling, and must be reported as such

| Architecture | Single-seed pooled RMSE (min–max) | 5-seed ensemble |
|---|---:|---:|
| `class_16_8` | 14.375 – 16.288 | **12.917** |
| `wide_32_16_drop` | 13.213 – 14.430 | **12.639** |
| `shallow_8_drop` | 14.416 – 18.408 | 13.880 |
| `class_16_8_drop` | 13.116 – 14.962 | 13.208 |
| `no_hidden` | 16.853 – 18.409 | 16.063 |

In three of five cases **the ensemble is better than the best individual seed**,
so a substantial part of the improvement is averaging five unstable networks
rather than any single network being better. A single `class_16_8` network
trained with an unlucky seed scores 16.288 — worse than the LASSO. The LASSO is
deterministic: same data, same answer, every time.

The correct statement is therefore: *an ensemble of five networks beats the
LASSO; a single network is better on average but unreliable.* Any report that
quotes 12.64 without this qualification overstates the result.

## 4. Persistence — the network loses, and the reason is informative

On the same 485 rows and 7 folds as the LASSO persistence benchmark (predictor
year 2021 is ineligible, so the 2022 fold drops out):

| Model | RMSE | R² |
|---|---:|---:|
| LASSO: state + time + prior rate | **8.887** | 0.866 |
| NN on prior rate alone | 8.929 | 0.865 |
| LASSO: prior rate only | 9.119 | 0.859 |
| NN: prior rate + 38 factors (best, `no_hidden`) | 10.049 | 0.829 |
| NN: prior rate + 38 factors (`class_16_8`) | 10.838 | 0.801 |

Given the prior year's rate alone, the network matches the LASSO almost exactly
(8.929 vs 8.887). **Adding the 38 factors makes the network worse** — 8.929 →
10.049 or beyond.

The LASSO met the same situation and shrank all 38 factors to exactly zero,
paying no penalty. A neural network has no equivalent mechanism: every input
stays wired into the first layer, so 38 uninformative predictors inject variance
it cannot discard.

The seed-stability figures confirm the mechanism directly. Mean prediction SD
across seeds for `class_16_8` is **8.39 on the 40 factors but 0.69 on prior rate
alone**. Given one dominant predictor the network is stable; given 40 weak,
correlated ones it thrashes.

## 5. What this adds to the project

1. **The network finds real nonlinear structure the LASSO misses.** On factors alone it is meaningfully more accurate, and the zero-layer anchor shows the gain is nonlinearity rather than setup.
2. **It does not overturn the central finding.** Next-year CoC homelessness is dominated by its own prior level. Adding the factor set improves nothing for the LASSO and actively hurts the network.
3. **Two very different model families reached the same conclusion from opposite directions** — the LASSO by discarding the factors, the network by being damaged by them. That is stronger evidence than either result alone.
4. **Model choice is a genuine trade-off here**, not a ranking. The network predicts better on factors; the LASSO is deterministic, interpretable, tells you which predictors matter, and degrades gracefully when predictors are useless.

## 6. Limitations

1. **Reported accuracy depends on the five-seed ensemble.** Single-network performance ranges over 1.2–4.0 RMSE depending on seed. Reproducing a single run will not reproduce the headline number.
2. **`wide_32_16_drop` carries 1,857 parameters against 332–817 training rows.** It won, but it is heavily over-parameterised and its margin over `class_16_8` (0.28 RMSE) is smaller than the seed spread of either. The two should be treated as tied.
3. **No coefficients, no selection, no p-values.** The network gives no interpretable per-predictor quantities. Everything the project says about *which* factors matter still comes from the LASSO.
4. **The panel is small.** 887 rows, 70 CoCs, 13 target years, two states. This is far outside the regime where neural networks are normally preferred, and the instability observed is what that looks like.
5. **Model families beyond LASSO and neural nets are not yet run.** Ridge, Elastic Net, Random Forest, and XGBoost remain outstanding, so the cross-model comparison is incomplete.

## 7. Files

`outputs/neural_net/` — `NN_metrics_overall.csv`, `NN_metrics_by_fold.csv`,
`NN_state_performance.csv`, `NN_seed_variability.csv`, `NN_epoch_selection.csv`,
`NN_predictions.csv`, `NN_comparison_with_lasso.csv`, `NN_architectures.csv`,
`NN_run_manifest.csv`, `session_info_neural_net.txt`, and four figures
(`NN_01`–`NN_04`).

### Reproduce

```bash
Rscript fit_neural_net.R
```

The script verifies the v2 workbook MD5 before doing anything, hard-fails on any
NA/NaN/Inf rather than imputing, and routes every write through a guard that
refuses paths outside `outputs/neural_net/`. Runtime is roughly 35 minutes for
445 fits.
