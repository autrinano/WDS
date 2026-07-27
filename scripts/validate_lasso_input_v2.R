#!/usr/bin/env Rscript
# =============================================================================
# validate_lasso_input_v2.R
#
# Independent data-quality reviewer for the California-Florida homelessness
# LASSO model input. This script READS ONLY. It never modifies the workbook,
# its construction script, or any central project documentation. All output is
# written to outputs/qa_v2/.
#
# It targets:  outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT_v2.xlsx
# and compares against the v1 baseline:
#              outputs/lasso_model/CA_FL_LASSO_MODEL_INPUT.xlsx
#
# If v2 is not yet available, the validator runs against v1 so the checks are
# exercised and tested, but it withholds any final v2 verdict.
#
# Every check reports PASS, WARNING, or FAIL with supporting evidence.
# Outputs:
#   outputs/qa_v2/validation_results.csv   (machine-readable table)
#   outputs/qa_v2/QA_AUDIT_v2.md           (short human-readable audit)
# =============================================================================

options(stringsAsFactors = FALSE)

project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) {
  .libPaths(c(local_r_lib, .libPaths()))
}

if (!requireNamespace("openxlsx", quietly = TRUE)) {
  stop("The 'openxlsx' package is required to read the workbook.")
}
suppressMessages(library(openxlsx))

# -----------------------------------------------------------------------------
# Paths and configuration
# -----------------------------------------------------------------------------
lasso_dir  <- file.path(project_root, "outputs", "lasso_model")
v2_file    <- file.path(lasso_dir, "CA_FL_LASSO_MODEL_INPUT_v2.xlsx")
v1_file    <- file.path(lasso_dir, "CA_FL_LASSO_MODEL_INPUT.xlsx")

output_dir <- file.path(project_root, "outputs", "qa_v2")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
results_csv <- file.path(output_dir, "validation_results.csv")
audit_md    <- file.path(output_dir, "QA_AUDIT_v2.md")

SHEET_NAME <- "LASSO Model Data"

# Known role structure (as documented in AGENTS.md and build_expanded_lasso_input.R)
ID_COLUMNS <- c(
  "state", "state_abbr", "coc_number", "coc_name",
  "predictor_year", "target_year"
)
TARGET_COLUMN   <- "target_homeless_rate_per_10k"
CONTROL_COLUMNS <- c("control_state_florida", "control_time_index")

# Minimum usable-observation requirement from the review brief.
MIN_USABLE_OBS <- 850L

# Plausible bounds for next-year PIT homelessness per 10,000 residents.
# 0 is implausible (every CoC has some homelessness); an upper bound of ~1000
# per 10k = 10% of the population, which no U.S. CoC approaches.
TARGET_LOWER_PLAUSIBLE <- 0
TARGET_UPPER_PLAUSIBLE <- 1000

# Leakage / prohibited-field patterns (mirrors the build script and adds a few).
PROHIBITED_PATTERNS <- c(
  "^target_total", "^target_estimated", "pit_count_caution",
  "target_definition", "^total_homeless$", "^sheltered_homeless$",
  "^unsheltered_homeless$", "funding_per_homeless",
  "beds_per_100_homeless", "next_year", "_t_plus", "future_"
)

# Identifier-like patterns that must NOT appear among penalized predictors.
IDENTIFIER_LIKE_PATTERNS <- c(
  "fips", "geoid", "_id$", "^id$", "zip", "zcta", "\\blat\\b",
  "\\blon\\b", "latitude", "longitude", "coc_number", "coc_name",
  "state_abbr", "tract", "geometry"
)

# -----------------------------------------------------------------------------
# Result accumulator
# -----------------------------------------------------------------------------
.results <- list()
add_result <- function(check_id, category, status, evidence) {
  status <- match.arg(status, c("PASS", "WARNING", "FAIL", "INFO"))
  .results[[length(.results) + 1]] <<- data.frame(
    check_id = check_id,
    category = category,
    status   = status,
    evidence = gsub("\\s+", " ", trimws(evidence))
  )
  invisible(NULL)
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
is_bad_numeric <- function(x) {
  # TRUE for values that are unusable in a numeric model: NA, NaN, +/-Inf.
  is.na(x) | is.nan(x) | is.infinite(x)
}

read_header_comments <- function(xlsx_path) {
  # Returns a character vector of comment text found anywhere in the workbook,
  # or character(0) if none. Parses xl/comments*.xml directly so we do not
  # depend on an openxlsx comment-reader API.
  tmp <- tempfile("xlsxcmt")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  ok <- tryCatch({
    utils::unzip(xlsx_path, exdir = tmp)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) return(character(0))
  comment_files <- list.files(
    file.path(tmp, "xl"), pattern = "^comments.*\\.xml$", full.names = TRUE
  )
  if (length(comment_files) == 0) return(character(0))
  texts <- unlist(lapply(comment_files, function(f) {
    xml <- paste(readLines(f, warn = FALSE), collapse = "\n")
    # Extract text between <t ...>...</t> tags.
    m <- regmatches(xml, gregexpr("<t[^>]*>.*?</t>", xml, perl = TRUE))[[1]]
    m <- gsub("<[^>]+>", "", m)
    m <- gsub("&amp;", "&", m); m <- gsub("&lt;", "<", m)
    m <- gsub("&gt;", ">", m);  m <- gsub("&quot;", "\"", m)
    m
  }))
  texts[nzchar(trimws(texts))]
}

nzv_flags <- function(x) {
  # Caret-style near-zero-variance heuristic on a numeric vector.
  x <- x[!is_bad_numeric(x)]
  if (length(x) == 0) return(list(constant = TRUE, nzv = TRUE, freq_ratio = Inf,
                                   unique_pct = 0))
  tab <- sort(table(x), decreasing = TRUE)
  n_unique <- length(tab)
  constant <- n_unique <= 1
  unique_pct <- 100 * n_unique / length(x)
  freq_ratio <- if (n_unique >= 2) as.numeric(tab[1] / tab[2]) else Inf
  nzv <- constant || (freq_ratio > 19 && unique_pct < 10)
  list(constant = constant, nzv = nzv, freq_ratio = freq_ratio,
       unique_pct = unique_pct)
}

# -----------------------------------------------------------------------------
# Resolve which file to validate
# -----------------------------------------------------------------------------
if (file.exists(v2_file)) {
  target_file <- v2_file
  validating_v2 <- TRUE
} else if (file.exists(v1_file)) {
  target_file <- v1_file
  validating_v2 <- FALSE
} else {
  stop(
    "Neither v2 nor v1 LASSO model input was found under ",
    lasso_dir, ". Nothing to validate."
  )
}

message("Validating: ", target_file)
message("v2 available: ", validating_v2)

# -----------------------------------------------------------------------------
# CHECK: exactly one worksheet named "LASSO Model Data"
# -----------------------------------------------------------------------------
sheet_names <- getSheetNames(target_file)
if (length(sheet_names) == 1 && sheet_names[1] == SHEET_NAME) {
  add_result("worksheet_single_named", "structure", "PASS",
             sprintf("Exactly one sheet named '%s'.", SHEET_NAME))
} else if (SHEET_NAME %in% sheet_names) {
  add_result("worksheet_single_named", "structure", "WARNING",
             sprintf("Sheet '%s' present but workbook has %d sheets: %s.",
                     SHEET_NAME, length(sheet_names),
                     paste(sheet_names, collapse = ", ")))
} else {
  add_result("worksheet_single_named", "structure", "FAIL",
             sprintf("No sheet named '%s'. Found: %s.",
                     SHEET_NAME, paste(sheet_names, collapse = ", ")))
}

# Read the model data (prefer the required sheet if present).
read_sheet <- if (SHEET_NAME %in% sheet_names) SHEET_NAME else 1
dat <- read.xlsx(target_file, sheet = read_sheet, detectDates = FALSE)
n_row <- nrow(dat)
n_col <- ncol(dat)
cols  <- names(dat)

# Derive role sets against the actual columns present.
id_present      <- intersect(ID_COLUMNS, cols)
control_present <- intersect(CONTROL_COLUMNS, cols)
has_target      <- TARGET_COLUMN %in% cols
predictor_cols  <- setdiff(cols, c(ID_COLUMNS, TARGET_COLUMN, CONTROL_COLUMNS))
model_cols      <- c(if (has_target) TARGET_COLUMN, control_present, predictor_cols)

# -----------------------------------------------------------------------------
# CHECK: unique CoC-year observations
# -----------------------------------------------------------------------------
if (all(c("coc_number", "predictor_year") %in% cols)) {
  key <- paste(dat$coc_number, dat$predictor_year, sep = "|")
  n_dup <- sum(duplicated(key))
  if (n_dup == 0) {
    add_result("unique_coc_year", "identity", "PASS",
               sprintf("All %d coc_number x predictor_year keys unique.", n_row))
  } else {
    dup_keys <- unique(key[duplicated(key)])
    add_result("unique_coc_year", "identity", "FAIL",
               sprintf("%d duplicated CoC-year rows. Example keys: %s.",
                       n_dup, paste(head(dup_keys, 5), collapse = ", ")))
  }
} else {
  add_result("unique_coc_year", "identity", "FAIL",
             "coc_number and/or predictor_year columns missing.")
}

# -----------------------------------------------------------------------------
# CHECK: California and Florida only
# -----------------------------------------------------------------------------
if ("state" %in% cols) {
  states <- sort(unique(dat$state))
  extra  <- setdiff(states, c("California", "Florida"))
  both   <- all(c("California", "Florida") %in% states)
  if (length(extra) == 0 && both) {
    add_result("states_ca_fl_only", "geography", "PASS",
               "Only California and Florida present, both represented.")
  } else if (length(extra) == 0 && !both) {
    add_result("states_ca_fl_only", "geography", "WARNING",
               sprintf("No out-of-scope states, but not both present: %s.",
                       paste(states, collapse = ", ")))
  } else {
    add_result("states_ca_fl_only", "geography", "FAIL",
               sprintf("Out-of-scope states present: %s.",
                       paste(extra, collapse = ", ")))
  }
} else {
  add_result("states_ca_fl_only", "geography", "FAIL", "state column missing.")
}

# -----------------------------------------------------------------------------
# CHECK: expected year coverage and documented 2021 treatment
# -----------------------------------------------------------------------------
if (all(c("predictor_year", "target_year") %in% cols)) {
  py <- suppressWarnings(as.integer(dat$predictor_year))
  ty <- suppressWarnings(as.integer(dat$target_year))
  offset_ok <- all(ty == py + 1L, na.rm = TRUE)
  target_2021 <- sum(ty == 2021, na.rm = TRUE)
  py_2021 <- sum(py == 2021, na.rm = TRUE)
  py_2020 <- sum(py == 2020, na.rm = TRUE)
  ty_span <- range(ty, na.rm = TRUE)
  evidence <- sprintf(
    "predictor_year %d-%d; target_year %d-%d; 2021-as-target rows=%d; 2021-as-predictor rows=%d; 2020-as-predictor rows=%d; offset(t+1) holds=%s.",
    min(py, na.rm = TRUE), max(py, na.rm = TRUE),
    ty_span[1], ty_span[2], target_2021, py_2021, py_2020, offset_ok)
  if (offset_ok && target_2021 == 0) {
    # Documented treatment: 2021 excluded as a target; 2020 predictor thus drops.
    if (py_2020 == 0 && py_2021 > 0) {
      add_result("year_coverage_2021", "coverage", "PASS",
                 paste("Coverage consistent; disrupted 2021 excluded as target",
                       "while retained as a predictor year.", evidence))
    } else {
      add_result("year_coverage_2021", "coverage", "WARNING",
                 paste("2021 not a target and offset holds, but 2020/2021",
                       "predictor pattern differs from v1 documentation.",
                       evidence))
    }
  } else if (!offset_ok) {
    add_result("year_coverage_2021", "coverage", "FAIL",
               paste("target_year is not always predictor_year + 1.", evidence))
  } else {
    add_result("year_coverage_2021", "coverage", "FAIL",
               paste("Disrupted 2021 PIT appears as a modeling target.",
                     evidence))
  }
} else {
  add_result("year_coverage_2021", "coverage", "FAIL",
             "predictor_year and/or target_year columns missing.")
}

# -----------------------------------------------------------------------------
# CHECK: numeric target, controls, and predictors
# -----------------------------------------------------------------------------
non_numeric <- model_cols[!vapply(dat[model_cols], is.numeric, logical(1))]
if (length(non_numeric) == 0) {
  add_result("modeling_numeric", "types", "PASS",
             sprintf("All %d modeling columns (target/controls/predictors) numeric.",
                     length(model_cols)))
} else {
  add_result("modeling_numeric", "types", "FAIL",
             sprintf("Non-numeric modeling columns: %s.",
                     paste(non_numeric, collapse = ", ")))
}

# -----------------------------------------------------------------------------
# CHECK: no missing, infinite, or NaN modeling values
# -----------------------------------------------------------------------------
numeric_model_cols <- model_cols[vapply(dat[model_cols], is.numeric, logical(1))]
bad_counts <- vapply(dat[numeric_model_cols],
                     function(x) sum(is_bad_numeric(x)), integer(1))
total_bad <- sum(bad_counts)
if (total_bad == 0) {
  add_result("no_missing_inf_nan", "completeness", "PASS",
             sprintf("No NA/NaN/Inf across %d numeric modeling columns x %d rows.",
                     length(numeric_model_cols), n_row))
} else {
  offenders <- bad_counts[bad_counts > 0]
  add_result("no_missing_inf_nan", "completeness", "FAIL",
             sprintf("%d unusable values. Columns: %s.", total_bad,
                     paste(sprintf("%s=%d", names(offenders), offenders),
                           collapse = ", ")))
}

# -----------------------------------------------------------------------------
# CHECK: no duplicated columns or duplicated predictors
# -----------------------------------------------------------------------------
dup_names <- unique(cols[duplicated(cols)])
# Duplicate CONTENT among numeric columns (identical value vectors).
num_cols <- cols[vapply(dat, is.numeric, logical(1))]
dup_content_pairs <- character(0)
if (length(num_cols) >= 2) {
  for (i in seq_len(length(num_cols) - 1)) {
    for (j in (i + 1):length(num_cols)) {
      a <- dat[[num_cols[i]]]; b <- dat[[num_cols[j]]]
      if (identical(a, b) || isTRUE(all.equal(a, b,
              tolerance = 1e-12, check.attributes = FALSE))) {
        dup_content_pairs <- c(dup_content_pairs,
                               paste(num_cols[i], "==", num_cols[j]))
      }
    }
  }
}
if (length(dup_names) == 0 && length(dup_content_pairs) == 0) {
  add_result("no_duplicate_columns", "structure", "PASS",
             "No duplicated column names and no columns with identical content.")
} else {
  msg <- c()
  if (length(dup_names) > 0)
    msg <- c(msg, sprintf("duplicate names: %s", paste(dup_names, collapse = ", ")))
  if (length(dup_content_pairs) > 0)
    msg <- c(msg, sprintf("identical-content pairs: %s",
                          paste(dup_content_pairs, collapse = "; ")))
  add_result("no_duplicate_columns", "structure", "FAIL",
             paste(msg, collapse = " | "))
}

# -----------------------------------------------------------------------------
# CHECK: no constant or near-zero-variance predictors
# -----------------------------------------------------------------------------
numeric_predictors <- predictor_cols[vapply(dat[predictor_cols], is.numeric,
                                            logical(1))]
constants <- character(0); nzvs <- character(0)
for (p in numeric_predictors) {
  f <- nzv_flags(dat[[p]])
  if (f$constant) constants <- c(constants, p)
  else if (f$nzv)  nzvs <- c(nzvs, sprintf("%s(fr=%.1f,uq=%.1f%%)",
                                           p, f$freq_ratio, f$unique_pct))
}
if (length(constants) > 0) {
  add_result("no_constant_nzv_predictors", "variance", "FAIL",
             sprintf("Constant predictors (no variation): %s.%s",
                     paste(constants, collapse = ", "),
                     if (length(nzvs) > 0)
                       sprintf(" Also near-zero-variance: %s.",
                               paste(nzvs, collapse = ", ")) else ""))
} else if (length(nzvs) > 0) {
  add_result("no_constant_nzv_predictors", "variance", "WARNING",
             sprintf("Near-zero-variance predictors (review before penalizing): %s.",
                     paste(nzvs, collapse = ", ")))
} else {
  add_result("no_constant_nzv_predictors", "variance", "PASS",
             sprintf("All %d numeric predictors have adequate variation.",
                     length(numeric_predictors)))
}

# -----------------------------------------------------------------------------
# CHECK: target values are plausible
# -----------------------------------------------------------------------------
if (has_target && is.numeric(dat[[TARGET_COLUMN]])) {
  tv <- dat[[TARGET_COLUMN]]
  rng <- range(tv, na.rm = TRUE)
  n_bad <- sum(is_bad_numeric(tv))
  out_of_range <- sum(tv <= TARGET_LOWER_PLAUSIBLE | tv > TARGET_UPPER_PLAUSIBLE,
                      na.rm = TRUE)
  ev <- sprintf("range [%.2f, %.2f] per 10k; median %.2f; n_bad=%d; out-of-range=%d.",
                rng[1], rng[2], median(tv, na.rm = TRUE), n_bad, out_of_range)
  if (n_bad == 0 && out_of_range == 0 && rng[1] > TARGET_LOWER_PLAUSIBLE) {
    add_result("target_plausible", "target", "PASS", ev)
  } else if (out_of_range == 0 && n_bad == 0) {
    add_result("target_plausible", "target", "WARNING",
               paste("Target within bounds but touches a boundary.", ev))
  } else {
    add_result("target_plausible", "target", "FAIL",
               paste("Implausible or unusable target values.", ev))
  }
} else {
  add_result("target_plausible", "target", "FAIL",
             "Target column missing or non-numeric.")
}

# -----------------------------------------------------------------------------
# CHECK: column-role prefixes and header comments are present
# -----------------------------------------------------------------------------
non_id_cols <- setdiff(cols, ID_COLUMNS)
bad_prefix <- non_id_cols[!grepl("^(target_|control_|coc_|state_)", non_id_cols)]
if (length(bad_prefix) == 0) {
  add_result("role_prefixes", "documentation", "PASS",
             "Every non-identifier column carries a target_/control_/coc_/state_ role prefix.")
} else {
  add_result("role_prefixes", "documentation", "WARNING",
             sprintf("Columns without a recognized role prefix: %s.",
                     paste(bad_prefix, collapse = ", ")))
}

comments <- read_header_comments(target_file)
role_comments <- comments[grepl("ROLE:", comments)]
if (length(comments) == 0) {
  add_result("header_comments", "documentation", "FAIL",
             "No header cell comments found in the workbook.")
} else if (length(role_comments) >= n_col) {
  add_result("header_comments", "documentation", "PASS",
             sprintf("%d header comments found (>= %d columns); all carry a ROLE: tag.",
                     length(role_comments), n_col))
} else {
  add_result("header_comments", "documentation", "WARNING",
             sprintf("%d ROLE: comments for %d columns (%d total comments); some headers may lack role/source notes.",
                     length(role_comments), n_col, length(comments)))
}

# -----------------------------------------------------------------------------
# CHECK: target or future-information leakage is absent
# -----------------------------------------------------------------------------
leak_hits <- unique(unlist(lapply(PROHIBITED_PATTERNS, function(p)
  grep(p, cols, value = TRUE, ignore.case = TRUE))))
# Also flag any predictor that is (near) perfectly correlated with the target.
corr_leaks <- character(0)
if (has_target && is.numeric(dat[[TARGET_COLUMN]])) {
  tv <- dat[[TARGET_COLUMN]]
  for (p in numeric_predictors) {
    xv <- dat[[p]]
    ok <- !is_bad_numeric(tv) & !is_bad_numeric(xv)
    if (sum(ok) > 3 && sd(xv[ok]) > 0 && sd(tv[ok]) > 0) {
      r <- suppressWarnings(cor(tv[ok], xv[ok]))
      if (!is.na(r) && abs(r) >= 0.999)
        corr_leaks <- c(corr_leaks, sprintf("%s(r=%.4f)", p, r))
    }
  }
}
if (length(leak_hits) == 0 && length(corr_leaks) == 0) {
  add_result("no_leakage", "leakage", "PASS",
             "No prohibited target/future-information field names and no predictor near-perfectly correlated with the target.")
} else if (length(leak_hits) == 0 && length(corr_leaks) > 0) {
  add_result("no_leakage", "leakage", "WARNING",
             sprintf("Predictors near-perfectly correlated with target (verify not derived): %s.",
                     paste(corr_leaks, collapse = ", ")))
} else {
  add_result("no_leakage", "leakage", "FAIL",
             sprintf("Prohibited leakage-prone columns present: %s.%s",
                     paste(leak_hits, collapse = ", "),
                     if (length(corr_leaks) > 0)
                       sprintf(" Correlation leaks: %s.",
                               paste(corr_leaks, collapse = ", ")) else ""))
}

# -----------------------------------------------------------------------------
# CHECK: no accidental identifiers among penalized predictors
# -----------------------------------------------------------------------------
id_like <- unique(unlist(lapply(IDENTIFIER_LIKE_PATTERNS, function(p)
  grep(p, predictor_cols, value = TRUE, ignore.case = TRUE))))
if (length(id_like) == 0) {
  add_result("no_identifier_predictors", "leakage", "PASS",
             "No identifier-like fields (fips/geoid/id/lat/lon/name/tract) among predictors.")
} else {
  add_result("no_identifier_predictors", "leakage", "WARNING",
             sprintf("Identifier-like predictor names (confirm they are true measures, not keys): %s.",
                     paste(id_like, collapse = ", ")))
}

# -----------------------------------------------------------------------------
# CHECK: at least 850 usable observations
# -----------------------------------------------------------------------------
# "Usable" = complete across every numeric modeling column.
usable_mask <- rep(TRUE, n_row)
for (p in numeric_model_cols) usable_mask <- usable_mask & !is_bad_numeric(dat[[p]])
n_usable <- sum(usable_mask)
if (n_usable >= MIN_USABLE_OBS) {
  add_result("min_usable_obs", "sample", "PASS",
             sprintf("%d usable complete-case observations (>= %d required).",
                     n_usable, MIN_USABLE_OBS))
} else {
  add_result("min_usable_obs", "sample", "FAIL",
             sprintf("Only %d usable observations (< %d required).",
                     n_usable, MIN_USABLE_OBS))
}

# -----------------------------------------------------------------------------
# v1 baseline comparison (for improvement count and change description)
# -----------------------------------------------------------------------------
v1_available <- file.exists(v1_file) && (validating_v2 || !identical(target_file, v1_file))
v1_cols <- character(0); v1_nrow <- NA_integer_; v1_ncol <- NA_integer_
if (file.exists(v1_file)) {
  v1_dat <- tryCatch(read.xlsx(v1_file, sheet = SHEET_NAME), error = function(e) NULL)
  if (is.null(v1_dat))
    v1_dat <- tryCatch(read.xlsx(v1_file, sheet = 1), error = function(e) NULL)
  if (!is.null(v1_dat)) {
    v1_cols <- names(v1_dat); v1_nrow <- nrow(v1_dat); v1_ncol <- ncol(v1_dat)
  }
}

if (validating_v2 && length(v1_cols) > 0) {
  added   <- setdiff(cols, v1_cols)
  removed <- setdiff(v1_cols, cols)
  row_delta <- n_row - v1_nrow
  # Count "defensible improvements": each added predictor, each removed
  # problematic/leakage column, and a material change in usable rows.
  improvements <- length(added) + length(removed)
  if (abs(row_delta) >= 1) improvements <- improvements + 1L
  ev <- sprintf("vs v1: +%d columns (%s); -%d columns (%s); row delta %+d (v1=%d, v2=%d); estimated distinct improvements=%d.",
                length(added), paste(head(added, 8), collapse = ", "),
                length(removed), paste(head(removed, 8), collapse = ", "),
                row_delta, v1_nrow, n_row, improvements)
  if (improvements >= 5 && improvements <= 10) {
    add_result("improvements_over_v1", "versioning", "PASS", ev)
  } else if (improvements > 0) {
    add_result("improvements_over_v1", "versioning", "WARNING",
               paste("Improvement count outside the expected 5-10 band.", ev))
  } else {
    add_result("improvements_over_v1", "versioning", "WARNING",
               paste("No structural differences detected vs v1.", ev))
  }
} else {
  add_result("improvements_over_v1", "versioning", "WARNING",
             "v2 not available (or v1 baseline unreadable); improvement count over v1 cannot be assessed yet.")
}

# -----------------------------------------------------------------------------
# CHECK: v1-to-v2 changes are accurately described
# -----------------------------------------------------------------------------
# Look for a v2 change description in the usual documentation locations.
doc_candidates <- c(
  file.path(project_root, "DECISION_LOG.md"),
  file.path(project_root, "DATA_SOURCES_AND_ASSUMPTIONS.md"),
  file.path(project_root, "DATA_LOG.md"),
  file.path(project_root, "CHANGELOG_v1_to_v2.md"),
  file.path(lasso_dir, "CHANGELOG_v2.md"),
  file.path(lasso_dir, "README.md"),
  file.path(output_dir, "..", "lasso_model", "v2_changes.md")
)
changelog_hits <- doc_candidates[file.exists(doc_candidates) &
  vapply(doc_candidates, function(f) {
    if (!file.exists(f)) return(FALSE)
    txt <- tolower(paste(readLines(f, warn = FALSE), collapse = "\n"))
    grepl("v2", txt) && grepl("lasso", txt)
  }, logical(1))]
if (validating_v2) {
  if (length(changelog_hits) > 0) {
    # If v1 baseline is present, cross-check that documented added/removed
    # columns match the actual diff (best-effort textual presence check).
    added   <- setdiff(cols, v1_cols)
    removed <- setdiff(v1_cols, cols)
    txt_all <- tolower(paste(unlist(lapply(changelog_hits, function(f)
      paste(readLines(f, warn = FALSE), collapse = "\n"))), collapse = "\n"))
    undocumented <- c(added, removed)[!vapply(tolower(c(added, removed)),
                     function(v) grepl(v, txt_all, fixed = TRUE), logical(1))]
    if (length(undocumented) == 0) {
      add_result("v1_v2_changes_documented", "versioning", "PASS",
                 sprintf("Change docs found (%s) and every added/removed column is named there.",
                         paste(basename(changelog_hits), collapse = ", ")))
    } else {
      add_result("v1_v2_changes_documented", "versioning", "WARNING",
                 sprintf("Change docs found (%s) but these diffs are not described: %s.",
                         paste(basename(changelog_hits), collapse = ", "),
                         paste(undocumented, collapse = ", ")))
    }
  } else {
    add_result("v1_v2_changes_documented", "versioning", "FAIL",
               "No v2 change description found in DECISION_LOG.md, DATA_SOURCES_AND_ASSUMPTIONS.md, DATA_LOG.md, or a v2 changelog.")
  }
} else {
  add_result("v1_v2_changes_documented", "versioning", "WARNING",
             "v2 not available; v1-to-v2 change description cannot be verified yet.")
}

# -----------------------------------------------------------------------------
# CHECK: sources and definitions are documented
# -----------------------------------------------------------------------------
src_comments <- comments[grepl("SOURCE", comments, ignore.case = TRUE)]
has_dsa <- file.exists(file.path(project_root, "DATA_SOURCES_AND_ASSUMPTIONS.md"))
has_dict <- file.exists(file.path(project_root, "coc_analysis", "variable_dictionary.csv"))
if (length(src_comments) > 0 && has_dsa && has_dict) {
  add_result("sources_documented", "documentation", "PASS",
             sprintf("%d header comments carry SOURCE notes; DATA_SOURCES_AND_ASSUMPTIONS.md and variable_dictionary.csv present.",
                     length(src_comments)))
} else {
  missing <- c(
    if (length(src_comments) == 0) "no SOURCE header comments",
    if (!has_dsa) "DATA_SOURCES_AND_ASSUMPTIONS.md missing",
    if (!has_dict) "variable_dictionary.csv missing"
  )
  add_result("sources_documented", "documentation", "WARNING",
             sprintf("Partial source documentation: %s.",
                     paste(missing, collapse = "; ")))
}

# -----------------------------------------------------------------------------
# CHECK: geographic mismatches and excluded observations are reported
# -----------------------------------------------------------------------------
coverage_file <- file.path(project_root, "coc_analysis", "coverage_summary.csv")
crosswalk_file <- file.path(project_root, "coc_analysis",
                            "county_to_coc_population_crosswalk_FY2024.csv")
split_flag_col <- "coc_contains_split_county_flag"
n_split <- if (split_flag_col %in% cols)
  sum(suppressWarnings(as.numeric(dat[[split_flag_col]])) == 1, na.rm = TRUE) else NA
geo_docs_present <- file.exists(coverage_file) && file.exists(crosswalk_file)
if (geo_docs_present && !is.na(n_split)) {
  add_result("geo_mismatch_reported", "geography", "PASS",
             sprintf("Coverage + FY2024 crosswalk present; %d rows flagged as split-county (%s) so mismatches are traceable.",
                     n_split, split_flag_col))
} else if (geo_docs_present) {
  add_result("geo_mismatch_reported", "geography", "WARNING",
             "Coverage/crosswalk docs present but split-county flag not found in the workbook.")
} else {
  add_result("geo_mismatch_reported", "geography", "WARNING",
             "coverage_summary.csv and/or FY2024 crosswalk not found; excluded-observation reporting unverified.")
}

# =============================================================================
# Assemble results table
# =============================================================================
results <- do.call(rbind, .results)
row.names(results) <- NULL

# Add run metadata rows are avoided; metadata goes to the markdown header.
write.csv(results, results_csv, row.names = FALSE)

# Summary counts
n_pass <- sum(results$status == "PASS")
n_warn <- sum(results$status == "WARNING")
n_fail <- sum(results$status == "FAIL")

# Overall verdict
if (!validating_v2) {
  verdict <- "PRELIMINARY (v1 only) - no final v2 verdict issued"
} else if (n_fail > 0) {
  verdict <- "FAIL - v2 has blocking data-quality defects"
} else if (n_warn > 0) {
  verdict <- "PASS WITH WARNINGS - v2 usable; review flagged items"
} else {
  verdict <- "PASS - v2 meets all checked criteria"
}

# =============================================================================
# Markdown audit
# =============================================================================
status_badge <- function(s) switch(s, PASS = "PASS", WARNING = "WARN",
                                    FAIL = "FAIL", INFO = "INFO")
md <- c(
  "# LASSO Model Input v2 - Independent QA Audit",
  "",
  sprintf("- **Run date:** %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  sprintf("- **File validated:** `%s`", sub(project_root, ".", target_file, fixed = TRUE)),
  sprintf("- **v2 available:** %s", if (validating_v2) "yes" else
    "no (validator exercised against v1 baseline)"),
  sprintf("- **Rows x Columns:** %d x %d", n_row, n_col),
  sprintf("- **Usable complete-case rows:** %d", n_usable),
  sprintf("- **Result tally:** %d PASS / %d WARNING / %d FAIL", n_pass, n_warn, n_fail),
  sprintf("- **Overall verdict:** **%s**", verdict),
  "",
  "> This review is read-only. No dataset, build script, or central document was",
  "> modified. Problems are reported to the dataset owner for repair; the reviewer",
  "> does not fix the data.",
  ""
)
if (!validating_v2) {
  md <- c(md,
    "## Note on scope",
    "",
    "The target file `CA_FL_LASSO_MODEL_INPUT_v2.xlsx` was **not present** at run time.",
    "The validator ran against the v1 baseline to confirm the checks execute and to",
    "establish a reference. **No final v2 verdict is issued.** Re-run this script once",
    "v2 is built to obtain the binding assessment.",
    "")
}
md <- c(md,
  "## Check results",
  "",
  "| # | Check | Category | Status | Evidence |",
  "|---|-------|----------|--------|----------|")
for (i in seq_len(nrow(results))) {
  md <- c(md, sprintf("| %d | %s | %s | **%s** | %s |",
                      i, results$check_id[i], results$category[i],
                      status_badge(results$status[i]),
                      gsub("|", "\\|", results$evidence[i], fixed = TRUE)))
}
md <- c(md, "",
  "## How to reproduce",
  "",
  "```bash",
  "Rscript validate_lasso_input_v2.R",
  "```",
  "",
  "Outputs are written to `outputs/qa_v2/`:",
  "",
  "- `validation_results.csv` - machine-readable check table.",
  "- `QA_AUDIT_v2.md` - this audit.",
  "")

writeLines(md, audit_md)

# Console summary
message("")
message(sprintf("QA complete: %d PASS / %d WARNING / %d FAIL", n_pass, n_warn, n_fail))
message("Verdict: ", verdict)
message("Wrote: ", results_csv)
message("Wrote: ", audit_md)
