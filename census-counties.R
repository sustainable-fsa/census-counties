#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/census-counties · census-counties.R
##
## A BagIt archive of vintage-matched US Census county boundaries, in three
## forms:
##
##   census-counties/data/parquet/YYYY-counties.parquet    raw TIGER/Line
##   census-counties/data/clipped/YYYY-counties.parquet    cut at that vintage's
##                                                         cb 500k waterline
##   census-counties.parquet                               every clipped vintage
##                                                         stacked, by year
##
## WHY BOTH RAW AND CLIPPED. TIGER/Line (tl_) county boundaries are the legal
## ones, and they are what the USDM county aggregations in
## sustainable-fsa/usdm-counties are computed against — so tl is the analytical
## truth and the archive keeps it unaltered. But tl does not stop at water:
## coastal counties and the Great Lakes states extend far offshore, which is
## correct as a boundary and misleading as a picture. The clipped form is for
## display, and is derived, never authoritative.
##
## THE CLIP MASK MATCHES THE VINTAGE. Cutting 2012 land with a 2024 coastline
## produces a boundary belonging to neither year. Census publishes no county cb
## file for 2000, 2009, 2011 or 2012, so those fall back to the nearest and the
## substitution is recorded per row in `mask_year` — data, not an assumption a
## reader has to reconstruct.
##
##   cb availability, measured against www2.census.gov:
##     2010        gz_2010_us_050_00_500k.zip   (GENZ2010, gz_ naming)
##     2013        cb_2013_us_county_500k.zip   (GENZ2013, no shp/ subdir)
##     2014-2025   shp/cb_YYYY_us_county_500k.zip
##
## NOTHING IS REPROCESSED UNLESS NECESSARY. Following the usdm archive:
## membership in the S3 LISTING — not a local file, and not a 1.8 GB download —
## decides whether a vintage already exists. A weekly run that finds nothing new
## costs one list call plus a HEAD per candidate, and publishes nothing. Only
## when Census posts a new TIGER vintage does the run pull the archive, build,
## restack and upload; that happens about once a year.
##
## THIS REPO PUBLISHES NO TILES and holds no projection. The web map renders a
## dummy-Albers space that exists only for MapLibre's benefit; that transform
## lives in exactly one place (sustainable-fsa/data-tiles, R/dummy-space.R)
## because two copies that drift misregister layers by up to 765 m with nothing
## on screen to show it. Tiles are built there, from this archive.
##
## Moved here from usdm-counties, which was carrying ~1.23 GB of Census
## boundaries that are not its subject.
##
##   Rscript census-counties.R                               # discover + update
##   VINTAGES=2020,2021 PUBLISH=0 Rscript census-counties.R  # two, local only
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(arrow); library(dplyr); library(tigris); library(curl)
  library(purrr); library(tibble); library(digest); library(jsonlite)
  library(stringr); library(magrittr)
})
source("R/s3-archive.R")
sf::sf_use_s2(FALSE)
options(tigris_use_cache = TRUE)

s3_bucket_name <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix      <- Sys.getenv("S3_PREFIX", unset = "census-counties")
publish        <- Sys.getenv("PUBLISH", unset = "1") == "1"

bag_dir <- "census-counties"
directories <- list(
  bag_dir     = bag_dir,
  raw_dir     = file.path(bag_dir, "data", "raw"),
  parquet_dir = file.path(bag_dir, "data", "parquet"),
  clipped_dir = file.path(bag_dir, "data", "clipped")
)
invisible(lapply(directories, dir.create, recursive = TRUE, showWarnings = FALSE))

## ── What is already archived ─────────────────────────────────────────────────
## Membership in the S3 listing replaces a local-file check, exactly as in the
## usdm archive: a CI runner starts empty, so asking S3 is the only way to learn
## what exists without downloading it.
archived_rel <- character(0)
if (publish) {
  archived_rel <- tryCatch(
    stringr::str_remove(s3_list_keys(s3_bucket_name, s3_prefix)$Key,
                        paste0("^", s3_prefix, "/")),
    error = function(e) character(0))
}

## Pull the existing manifest so its hashes can be merged rather than dropped.
manifest <- NULL
if ("manifest-sha256.txt" %in% archived_rel) {
  try({
    s3_pull(s3_bucket_name, paste0(s3_prefix, "/manifest-sha256.txt"),
            file.path(bag_dir, "manifest-sha256.txt"))
    m <- stringr::str_split_fixed(readLines(file.path(bag_dir, "manifest-sha256.txt")), "  ", 2)
    manifest <- tibble::tibble(hash = m[, 1], file = m[, 2])
  }, silent = TRUE)
}

## ── Candidate vintages, discovered rather than hardcoded ─────────────────────
## Census posts a new TIGER vintage each autumn. Generating candidates out to
## next calendar year and HEAD-checking each picks a new vintage up the week it
## appears, with no edit to this file.
tl_url_for <- function(y) {
  switch(as.character(y),
    "2000" = "https://www2.census.gov/geo/tiger/TIGER2010/COUNTY/2000/tl_2010_us_county00.zip",
    "2009" = "https://www2.census.gov/geo/tiger/TIGER2009/tl_2009_us_county.zip",
    "2010" = "https://www2.census.gov/geo/tiger/TIGER2010/COUNTY/2010/tl_2010_us_county10.zip",
    sprintf("https://www2.census.gov/geo/tiger/TIGER%d/COUNTY/tl_%d_us_county.zip", y, y))
}
CANDIDATES    <- c(2000, 2009, 2010, 2011:(as.integer(format(Sys.Date(), "%Y")) + 1L))
MASK_FALLBACK <- c(`2000` = 2010L, `2009` = 2010L, `2011` = 2010L, `2012` = 2013L)

vintages <- if (nzchar(Sys.getenv("VINTAGES"))) {
  as.integer(strsplit(Sys.getenv("VINTAGES"), "[, ]+")[[1]])
} else {
  ok <- vapply(CANDIDATES, \(y) url_exists(tl_url_for(y)), logical(1))
  if (any(!ok))
    message("not published by Census yet: ", paste(CANDIDATES[!ok], collapse = ", "))
  CANDIDATES[ok]
}

## A vintage is done when its CLIPPED parquet is archived; the raw form is an
## intermediate on the way there.
needs <- vintages[!vapply(vintages, \(y)
  sprintf("data/clipped/%d-counties.parquet", y) %in% archived_rel, logical(1))]

message("vintages available: ", length(vintages), "   needing work: ",
        if (length(needs)) paste(needs, collapse = ", ") else "none")

if (publish && !length(needs) &&
    "census-counties.parquet" %in% archived_rel) {
  gate_skip("every available vintage is already archived; nothing to do.")
}

## Restacking needs every clipped vintage on disk, so pull the archive — but
## only now that there is work to justify it. This is the expensive step and it
## runs about once a year.
if (publish && length(needs) && length(needs) < length(vintages)) {
  message("pulling the archived vintages needed for the restack")
  try(s3_pull(s3_bucket_name, paste0(s3_prefix, "/data"),
              file.path(bag_dir, "data")), silent = TRUE)
}

## ── 1. Raw TIGER/Line, one parquet per vintage ───────────────────────────────
raw_parquet <- function(y) {
  out <- file.path(directories$parquet_dir, sprintf("%d-counties.parquet", y))
  if (file.exists(out)) return(out)
  url <- tl_url_for(y)
  zip <- file.path(directories$raw_dir, basename(url))
  if (!file.exists(zip)) {
    message("  downloading ", basename(url))
    curl::multi_download(url, destfiles = zip, resume = TRUE)
  }
  ## Column names differ by vintage: 2000 uses COUNTYFP00, 2010 COUNTYFP10.
  x <- sf::read_sf(file.path("/vsizip", zip))
  nm <- names(x)
  pick <- function(...) {
    for (cand in c(...)) if (cand %in% nm) return(cand)
    stop("no column among ", paste(c(...), collapse = "/"), " in tl ", y, call. = FALSE)
  }
  x |>
    dplyr::transmute(
      STATEFP    = .data[[pick("STATEFP", "STATEFP00", "STATEFP10")]],
      COUNTYFP   = .data[[pick("COUNTYFP", "COUNTYFP00", "COUNTYFP10")]],
      County     = .data[[pick("NAME", "NAME00", "NAME10")]],
      CountyLSAD = .data[[pick("NAMELSAD", "NAMELSAD00", "NAMELSAD10")]],
      year       = y
    ) |>
    sf::st_make_valid() |>
    sf::write_sf(out, driver = "Parquet",
                 layer_options = c("COMPRESSION=ZSTD", "COMPRESSION_LEVEL=13"),
                 delete_dsn = TRUE)
  out
}

## ── 2. The waterline clip, per vintage ───────────────────────────────────────
clipped_parquet <- function(y) {
  out <- file.path(directories$clipped_dir, sprintf("%d-counties.parquet", y))
  if (file.exists(out)) return(out)
  mask_yr <- if (as.character(y) %in% names(MASK_FALLBACK))
    MASK_FALLBACK[[as.character(y)]] else y
  if (mask_yr != y)
    message(sprintf("  no cb %d exists; clipping with cb %d", y, mask_yr))
  mask <- tigris::counties(cb = TRUE, resolution = "500k", year = mask_yr,
                           progress_bar = FALSE) |>
    sf::st_transform(4269) |> sf::st_union() |> sf::st_make_valid()

  x <- sf::read_sf(raw_parquet(y))
  sf::st_crs(x) <- 4269                       # TIGER is NAD83
  x <- suppressWarnings(sf::st_intersection(x, mask))
  ## st_intersection can return GEOMETRY: a polygon plus a stray boundary line
  ## where the mask grazes an edge. Keep the areal part only.
  sf::st_collection_extract(x, "POLYGON", warn = FALSE) |>
    sf::st_make_valid() |>
    dplyr::group_by(STATEFP, COUNTYFP, County, CountyLSAD, year) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_cast("MULTIPOLYGON") |>
    dplyr::mutate(mask_year = mask_yr) |>
    sf::write_sf(out, driver = "Parquet",
                 layer_options = c("COMPRESSION=ZSTD", "COMPRESSION_LEVEL=13"),
                 delete_dsn = TRUE)
  out
}

## ── 3. The stacked parquet ───────────────────────────────────────────────────
## Every clipped vintage in one file, one row per county per vintage,
## distinguished by `year`.
##
## Deliberately NOT deduplicated. Collapsing runs of byte-identical geometry
## into from/to eras was tried and does not pay: over 2020 and 2021 it reduced
## 6,468 rows to 6,466 — two rows. Even though 99.18% of vertices are unchanged
## between adjacent vintages, the clip mask moves each year and
## st_intersection/st_make_valid re-node and reorder rings even where the shape
## is untouched, so byte comparison finds almost nothing. Recovering it would
## mean freezing one mask across all vintages or canonicalising coordinates
## before hashing — both trade fidelity or complexity for space not worth saving.
stack_vintages <- function(years) {
  message("\nstacking ", length(years), " clipped vintages")
  all <- do.call(rbind, lapply(years, function(y)
    sf::read_sf(file.path(directories$clipped_dir, sprintf("%d-counties.parquet", y)))))
  all$fips <- paste0(all$STATEFP, all$COUNTYFP)
  all <- all |> dplyr::relocate(fips) |> dplyr::arrange(year, fips)
  out <- "census-counties.parquet"
  sf::write_sf(all, out, driver = "Parquet",
               layer_options = c("COMPRESSION=ZSTD", "COMPRESSION_LEVEL=13"),
               delete_dsn = TRUE)
  message(sprintf("  %s rows, %s counties x %d vintages, %.0f MB",
                  format(nrow(all), big.mark = ","),
                  format(dplyr::n_distinct(all$fips), big.mark = ","),
                  length(years), file.size(out) / 1048576))
  out
}

## ── Build ────────────────────────────────────────────────────────────────────
for (y in needs) {
  message("=== ", y, " ===")
  raw_parquet(y)
  clipped_parquet(y)
  message(sprintf("  raw %.0f MB   clipped %.0f MB",
    file.size(file.path(directories$parquet_dir, sprintf("%d-counties.parquet", y))) / 1048576,
    file.size(file.path(directories$clipped_dir, sprintf("%d-counties.parquet", y))) / 1048576))
}

## The stacked file is a concatenation, so it is stale only if a vintage was
## added. Rebuilding an unchanged multi-hundred-MB file weekly would be waste.
stacked <- if (length(needs) || !file.exists("census-counties.parquet"))
  stack_vintages(vintages) else NULL

## ── BagIt tags ───────────────────────────────────────────────────────────────
writeLines(c(
  "BagIt-Version: 0.97",
  "Tag-File-Character-Encoding: UTF-8"
), file.path(bag_dir, "bagit.txt"))

writeLines(c(
  paste("Bag-Software-Agent:", "R Census Counties Archive BagIt Pipeline"),
  paste("Bagging-Date:", Sys.Date()),
  "Contact-Name: R. Kyle Bocinsky",
  "Contact-Email: kyle.bocinsky@umontana.edu",
  "Source-Organization: Montana Climate Office, University of Montana",
  "External-Description: Vintage-matched GeoParquet archive of US Census county boundaries, raw and clipped to each vintage's cartographic waterline"
), file.path(bag_dir, "bag-info.txt"))

## ── manifest-sha256.txt, merged rather than rewritten ────────────────────────
## On a fresh runner the local bag holds only this run's new files, so merge
## their hashes into the pulled manifest instead of dropping everything else.
new_files  <- list.files(file.path(bag_dir, "data"), recursive = TRUE, full.names = TRUE)
new_hashes <- tibble::tibble(
  file = gsub(paste0(bag_dir, "/"), "", new_files),
  hash = purrr::map_chr(new_files, digest::digest, algo = "sha256", file = TRUE)
)
manifest_updated <-
  {if (!is.null(manifest)) dplyr::anti_join(manifest, new_hashes, by = "file")
   else tibble::tibble(hash = character(0), file = character(0))} |>
  dplyr::bind_rows(new_hashes) |>
  dplyr::arrange(file)
writeLines(paste0(manifest_updated$hash, "  ", manifest_updated$file),
           file.path(bag_dir, "manifest-sha256.txt"))

## ── Publish (append-only: never --delete) ────────────────────────────────────
if (!publish) {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
} else {
  s3_push(s3_bucket_name, s3_prefix, bag_dir, delete = FALSE)
  s3_verify(s3_bucket_name, s3_prefix, bag_dir,
            allow_extra = character(0), expect_exact = FALSE)
  if (!is.null(stacked))
    s3_put(s3_bucket_name, paste0(s3_prefix, "/census-counties.parquet"),
           stacked, content_type = "application/vnd.apache.parquet",
           cache_control = "max-age=3600")

  ## Flat index regenerated from the authoritative S3 listing.
  generate_tree_flat <- function(output_file = "census-counties-manifest.json") {
    hashes <- magrittr::set_names(as.list(manifest_updated$hash), manifest_updated$file)
    entries <- s3_list_keys(s3_bucket_name, s3_prefix) |>
      dplyr::mutate(path = stringr::str_remove(Key, paste0("^", s3_prefix, "/"))) |>
      dplyr::filter(!startsWith(path, "_")) |>
      dplyr::arrange(path) |>
      purrr::pmap(\(Key, Size, path) {
        entry <- list(path = path, size = Size)
        if (!is.null(hashes[[path]])) entry$hash <- hashes[[path]]
        entry
      })
    jsonlite::write_json(entries, output_file, pretty = TRUE, auto_unbox = TRUE)
    message("✅ Wrote ", length(entries), " entries to ", output_file)
  }
  generate_tree_flat()
  s3_put(s3_bucket_name, paste0(s3_prefix, "/census-counties-manifest.json"),
         "census-counties-manifest.json",
         content_type = "application/json", cache_control = "max-age=3600")
  s3_write_manifest(s3_bucket_name, s3_prefix)

  ## Only the mutated paths, per the archive convention.
  cf_invalidate(c(paste0("/", s3_prefix, "/census-counties.parquet"),
                  paste0("/", s3_prefix, "/census-counties-manifest.json"),
                  paste0("/", s3_prefix, "/_manifest.txt")))
  cf_wait_manifest(
    paste0(Sys.getenv("CLOUDFRONT_BASE", "https://data.sustainable-fsa.com"),
           "/", s3_prefix, "/census-counties-manifest.json"),
    "census-counties-manifest.json")
}

if (requireNamespace("rmarkdown", quietly = TRUE) && file.exists("README.Rmd"))
  rmarkdown::render("README.Rmd", quiet = TRUE)
