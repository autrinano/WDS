options(stringsAsFactors = FALSE)
project_root <- normalizePath(".", mustWork = TRUE)
local_r_lib <- file.path(project_root, "_r_libs")
if (dir.exists(local_r_lib)) .libPaths(c(local_r_lib, .libPaths()))
library(httr)
library(jsonlite)
library(dplyr)

out_file <- file.path(
  project_root, "raw_data",
  "usaspending_coc_program_awards_CA_FL_2010_2025.csv"
)

fetch_state_awards <- function(state) {
  all_rows <- list()
  page <- 1
  repeat {
    body <- list(
      filters = list(
        award_type_codes = list("02", "03", "04", "05"),
        program_numbers = list("14.267"),
        time_period = list(list(start_date = "2009-10-01", end_date = "2025-12-31")),
        recipient_locations = list(list(country = "USA", state = state))
      ),
      fields = list(
        "Award ID", "Recipient Name", "Award Amount", "Start Date",
        "Recipient Location"
      ),
      page = page,
      limit = 100,
      sort = "Award Amount",
      order = "desc"
    )
    resp <- POST(
      "https://api.usaspending.gov/api/v2/search/spending_by_award/",
      body = toJSON(body, auto_unbox = TRUE),
      content_type_json(),
      encode = "raw"
    )
    if (status_code(resp) != 200) {
      stop("USAspending request failed for ", state, " page ", page, ": ", status_code(resp))
    }
    parsed <- fromJSON(content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
    results <- parsed$results
    if (length(results) == 0) break
    rows <- lapply(results, function(r) {
      loc <- r[["Recipient Location"]]
      data.frame(
        award_id = r[["Award ID"]] %||% NA_character_,
        recipient_name = r[["Recipient Name"]] %||% NA_character_,
        award_amount = as.numeric(r[["Award Amount"]] %||% NA),
        start_date = r[["Start Date"]] %||% NA_character_,
        recipient_state = if (!is.null(loc)) (loc$state_code %||% NA_character_) else NA_character_,
        recipient_county_code = if (!is.null(loc)) (loc$county_code %||% NA_character_) else NA_character_,
        recipient_county_name = if (!is.null(loc)) (loc$county_name %||% NA_character_) else NA_character_,
        stringsAsFactors = FALSE
      )
    })
    all_rows[[length(all_rows) + 1]] <- bind_rows(rows)
    has_next <- isTRUE(parsed$page_metadata$hasNext)
    message(state, " page ", page, ": ", length(results), " results, hasNext=", has_next)
    if (!has_next) break
    page <- page + 1
    Sys.sleep(0.15)
  }
  bind_rows(all_rows)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

if (!file.exists(out_file)) {
  ca_awards <- fetch_state_awards("CA")
  fl_awards <- fetch_state_awards("FL")
  awards <- bind_rows(ca_awards, fl_awards)
  write.csv(awards, out_file, row.names = FALSE)
  message("Saved ", nrow(awards), " award rows to ", out_file)
} else {
  message("Cache already exists at ", out_file, "; delete it to refetch.")
}
