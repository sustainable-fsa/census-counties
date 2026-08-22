#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/census-counties · census-counties.R
##
## An archive of vintage-matched US Census county boundaries, in three forms:
##
##   data/parquet/YYYY-counties.parquet    raw TIGER/Line, as published
##   data/clipped/YYYY-counties.parquet    the same, cut at that vintage's
##                                         cb 500k waterline
##   census-counties.parquet               all vintages, one row per county per
##                                         geometry-era (from/to)
##
## WHY BOTH RAW AND CLIPPED. TIGER/Line (tl_) county boundaries are the legal
## ones, and they are what the USDM county determinations in
## sustainable-fsa/usdm-counties are computed against — so tl is the analytical
## truth and the archive must keep it unaltered. But tl does not stop at water:
## coastal counties and the Great Lakes states extend far offshore, which is
## correct as a boundary and useless as a picture. The clipped form is for
## display, and it is derived, never authoritative.
##
## THE CLIP MASK MATCHES THE VINTAGE. Cutting 2012 land with a 2024 coastline
## produces a boundary belonging to neither year. Census does not publish a cb
## county file for every vintage, so the four years that lack one fall back to
## the nearest, recorded per row in `mask_year` — the substitution is data, not
## an assumption a reader has to reconstruct.
##
##   cb availability, measured against www2.census.gov:
##     2010        gz_2010_us_050_00_500k.zip   (GENZ2010, gz_ naming)
##     2013        cb_2013_us_county_500k.zip   (GENZ2013, no shp/ subdir)
##     2014-2025   shp/cb_YYYY_us_county_500k.zip
##     2000, 2009, 2011, 2012 — no county cb release exists
##
## THIS REPO PUBLISHES NO TILES, and holds no projection. The web map renders a
## dummy-Albers space that exists only for MapLibre's benefit; that transform
## lives in exactly one place (sustainable-fsa/data-tiles, R/dummy-space.R)
## because two copies that drift misregister layers by up to 765 m with nothing
## on screen to show it. This archive stays in real coordinate systems.
##
## Moved here from usdm-counties, which was carrying ~1.23 GB of Census
## boundaries that are not its subject.
##
##   Rscript census-counties.R                    # everything
##   VINTAGES=2020,2021 PUBLISH=0 Rscript census-counties.R
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(arrow); library(dplyr); library(tigris); library(curl)
})
source("R/s3-archive.R")
sf::sf_use_s2(FALSE)
options(tigris_use_cache = TRUE)

## ── The vintages ─────────────────────────────────────────────────────────────
## 2000, 2009 and 2010 come from decennial-specific TIGER paths; 2011 onward
## follow one pattern. This list defines the archive.
TL_URL <- c(
  `2000` = "https://www2.census.gov/geo/tiger/TIGER2010/COUNTY/2000/tl_2010_us_county00.zip",
  `2009` = "https://www2.census.gov/geo/tiger/TIGER2009/tl_2009_us_county.zip",
  `2010` = "https://www2.census.gov/geo/tiger/TIGER2010/COUNTY/2010/tl_2010_us_county10.zip",
  vapply(2011:2025, function(y)
    sprintf("https://www2.census.gov/geo/tiger/TIGER%d/COUNTY/tl_%d_us_county.zip", y, y),
    character(1)) |> setNames(as.character(2011:2025))
)

## Nearest cb vintage for the years Census never published one.
MASK_FALLBACK <- c(`2000` = 2010L, `2009` = 2010L, `2011` = 2010L, `2012` = 2013L)

## Territories the FSA-facing products drop. Kept OUT of the filter here: this
## is an archive, and a consumer that wants CONUS can filter. Recorded so the
## difference from data-tiles is deliberate rather than forgotten.

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "census-counties")
publish   <- Sys.getenv("PUBLISH", unset = "1") == "1"
vintages  <- as.integer(strsplit(Sys.getenv("VINTAGES",
               paste(names(TL_URL), collapse = ",")), "[, ]+")[[1]])

for (d in c("data-raw", "data/parquet", "data/clipped"))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)

## ── 1. Raw TIGER/Line, one parquet per vintage ───────────────────────────────
raw_parquet <- function(y) {
  out <- file.path("data/parquet", sprintf("%d-counties.parquet", y))
  if (file.exists(out)) return(out)
  url <- TL_URL[[as.character(y)]]
  zip <- file.path("data-raw", basename(url))
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
  st <- pick("STATEFP", "STATEFP00", "STATEFP10")
  co <- pick("COUNTYFP", "COUNTYFP00", "COUNTYFP10")
  nmc <- pick("NAME", "NAME00", "NAME10")
  lsad <- pick("NAMELSAD", "NAMELSAD00", "NAMELSAD10")
  x |>
    dplyr::transmute(STATEFP = .data[[st]], COUNTYFP = .data[[co]],
                     County = .data[[nmc]], CountyLSAD = .data[[lsad]],
                     year = y) |>
    sf::st_make_valid() |>
    sf::write_sf(out, driver = "Parquet",
                 layer_options = c("COMPRESSION=ZSTD", "COMPRESSION_LEVEL=13"),
                 delete_dsn = TRUE)
  out
}

## ── 2. The waterline clip, per vintage ───────────────────────────────────────
mask_for <- function(y) {
  used <- if (as.character(y) %in% names(MASK_FALLBACK))
    MASK_FALLBACK[[as.character(y)]] else y
  if (used != y)
    message(sprintf("  no cb %d exists; clipping with cb %d", y, used))
  m <- tigris::counties(cb = TRUE, resolution = "500k", year = used,
                        progress_bar = FALSE) |>
    sf::st_transform(4269) |> sf::st_union() |> sf::st_make_valid()
  list(mask = m, mask_year = used)
}

clipped_parquet <- function(y) {
  out <- file.path("data/clipped", sprintf("%d-counties.parquet", y))
  if (file.exists(out)) return(out)
  mk <- mask_for(y)
  x <- sf::read_sf(raw_parquet(y))
  sf::st_crs(x) <- 4269                       # TIGER is NAD83
  x <- suppressWarnings(sf::st_intersection(x, mk$mask))
  ## st_intersection can return GEOMETRY: a polygon plus a stray boundary line
  ## where the mask grazes an edge. Keep the areal part only.
  x <- sf::st_collection_extract(x, "POLYGON", warn = FALSE) |>
    sf::st_make_valid() |>
    dplyr::group_by(STATEFP, COUNTYFP, County, CountyLSAD, year) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_cast("MULTIPOLYGON") |>
    dplyr::mutate(mask_year = mk$mask_year)
  sf::write_sf(x, out, driver = "Parquet",
               layer_options = c("COMPRESSION=ZSTD", "COMPRESSION_LEVEL=13"),
               delete_dsn = TRUE)
  out
}

## ── 3. The multi-vintage parquet ─────────────────────────────────────────────
## Every clipped vintage stacked into one file, one row per county per vintage,
## distinguished by `year`. A consumer selects a vintage with a single filter.
##
## Deliberately NOT deduplicated. An earlier version collapsed runs of
## byte-identical geometry into from/to eras, and it does not pay: measured over
## 2020 and 2021, 6,468 vintage-rows collapsed to 6,466 — two rows. Even though
## 99.18% of vertices are unchanged between adjacent vintages, the clip's mask
## moves each year and st_intersection/st_make_valid re-node and reorder rings
## even where the shape is untouched, so byte comparison finds almost nothing.
## Recovering it would mean either freezing one mask across all vintages or
## canonicalising coordinates before hashing — both trade fidelity or
## complexity for space this archive does not need to save.
multi_vintage <- function(years) {
  message("\nstacking ", length(years), " clipped vintages")
  all <- do.call(rbind, lapply(years, function(y) sf::read_sf(clipped_parquet(y))))
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

## ── Run ──────────────────────────────────────────────────────────────────────
for (y in vintages) {
  message("=== ", y, " ===")
  raw_parquet(y); clipped_parquet(y)
  message(sprintf("  raw %.0f MB   clipped %.0f MB",
    file.size(file.path("data/parquet", sprintf("%d-counties.parquet", y))) / 1048576,
    file.size(file.path("data/clipped", sprintf("%d-counties.parquet", y))) / 1048576))
}
mv <- if (length(vintages) > 1) multi_vintage(vintages) else NULL

if (publish) {
  s3_push(bucket = s3_bucket, prefix = paste0(s3_prefix, "/data"),
          local_dir = "data", delete = FALSE)
  if (!is.null(mv))
    s3_put(bucket = s3_bucket, key = paste0(s3_prefix, "/census-counties.parquet"),
           file = mv, content_type = "application/vnd.apache.parquet",
           cache_control = "max-age=3600")
  message("published to s3://", s3_bucket, "/", s3_prefix)
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
