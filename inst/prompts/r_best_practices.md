# R Best Practices: Statistical Analysis Protocol

Follow these rules for all R-based statistical work. They enforce transparent,
reproducible, theory-driven analysis.

---

## 1. General Definitions & Setup

- **DV**: Dependent variable.
- **Stochasticity**: Set seed for anything stochastic (CV folds, bootstraps,
  Bayesian sampling where relevant).
- **Outliers**: Never delete outliers silently. Flag influential points
  (Cook's D / leverage / DFBetas or Bayesian influence checks), report
  sensitivity analyses.

## 2. Coding Standards

- **Section Headers**: DO NOT display sections using `cat` or `print`. Put them
  behind hashtags (e.g., `# Visualization Section`, `# Printing results`).
- **Rationale**: Explain your rationale at each step above each code chunk you
  execute to allow for a transparent audit of your thought process.
- **Displaying Results**: If you want to show results, call the objects directly
  with a hashtag comment above to explain what it is.
- **Visualizations**: Avoid cluttered direct labels unless necessary; prefer
  uncertainty (CI/error bars) over value labels.
- **Dynamic Values (CRITICAL)**: When using R tools, NEVER hard code any results
  such as mean values, significant values, sample sizes, etc. All values should
  be dynamically pulled from the objects.

## 3. Data Integrity & Assumptions

- **The "No Assumptions" Rule**: No assumptions. Never "assume." If you think
  you need to assume something about data structure or data, write R code to
  check it. If you are assuming, we have failed.

## 4. Workflow: Exploratory Data Analysis (EDA)

- **Exhaustive Exploration**: EDA should be exhaustive — plot the DV, IVs, and
  their relationships. There is never too much EDA. The data should be maximally
  investigated to explore all the nooks and crannies.
- **Missing Data**: Check for missing data during EDA. If missingness is
  significant (>5%), prioritize multiple imputation (e.g., `mice` package) or
  full-information maximum likelihood (FIML) over listwise deletion, unless
  instructed otherwise.
- **Object Verification**: When making any transformed objects (new columns,
  updated values, etc.), print the newly made object to confirm columns, values,
  and rows are as expected.
  - If not all columns are printed, use `print(df, width = Inf)` to see all
    column values.
  - If the dataset is too large, use `glimpse()` or `str()` to verify structure,
    and `head()`/`tail()` to verify values.
  - **Context**: Always make sure you have all the context you need from object
    print outs, especially if columns contain information that changes downstream
    tasks (such as hidden columns with p-values, effect sizes, etc.).

## 5. Workflow: Model Building

- **Theory-Driven**: Models should ALWAYS be fit incrementally in a
  theory-driven way. Start simple (one or two predictors), then add more as
  assumptions are met.
- **Pre-Model Steps**:
  - After deciding the model formation, plot the DV one more time.
  - Ensure categorical variables are converted to factors and the reference
    level is set intentionally (theory-driven) before modeling.
  - Use the EDA plot to check for outliers and bounds, not strictly for
    normality.
- **Family Selection**: Choose the family based on the nature of the DV:
  - Count data → Poisson / Negative Binomial
  - Binary outcome → Binomial
  - Continuous and bounded → Beta
  - **Ambiguity**: If multiple families could fit (e.g., Poisson vs NegBin),
    justify with dispersion checks / posterior predictive checks / residual
    simulation.
- **Collinearity**: Check for multicollinearity using VIF (Variance Inflation
  Factor). If VIF > 5 (or 10), address it.

## 6. Workflow: Diagnostics & Validation

- **The "Before Summary" Rule**: Once the model is fit but BEFORE looking at
  `summary()`, check assumptions with at least 3 methods (residuals, QQ plot,
  etc.). The specific checks vary by model family/distribution. Only if they
  pass should you look at summary output.
- **Assumption Handling**: If minor violations exist, note them and discuss
  limitations or switch to robust standard errors / bootstrapping. If major
  violations exist, revise the model family/link.
- **Post-Hoc Analysis**: If summary output is significant, create effects
  plots with the `effects` and/or `emmeans` package, if applicable. Do this
  for all models.
- **Predictive Validation**: ANY predictive model MUST have validation checked
  (cross-fold validation, Precision, Recall, F1, AUC, etc.).

## 7. Workflow: Model Criteria & Comparisons

Always check model criteria:
- Use LR tests for nested frequentist models.
- Use AIC/BIC for comparable likelihood-based models (same response, same data,
  same likelihood assumptions).
- **Bayesian**: Add LOO/WAIC + Bayes factors (where appropriate) + prior
  sensitivity.

## 8. Output & Reporting

- **File Management**: Save models as `.rds` files so they load faster on
  subsequent runs.
- **Tables**: Include `kable` tables with all results and comparisons across
  models. Use the `broom` package (`tidy()`/`glance()`) to extract model
  results into data frames before passing to `kable`.
- **Metrics**:
  - Always report effect sizes + uncertainty (CI/CrI), not just p-values.
  - Include model formula, family/link, N used, and model comparison table.
- **Multiple Comparisons**: For any time there are multiple tests, apply an
  appropriate correction (e.g., FDR for exploratory, Holm for strict control).

## 9. Bayesian Specifics

- Use the same workflow as above.
- **Assumption Checks**: Plot priors, posterior predictive checks, fit
  diagnostics, posterior probabilities, ROPEs or Bayes Factors for weak,
  medium, and strong priors, and model comparisons.
