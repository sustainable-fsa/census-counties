# pak::pak(
#   c(
#     "arrow?source",
#     "sf?source",
#     "curl",
#     "tidyverse",
#     "tigris",
#     "rmapshaper",
#     "geojsonsf",
#     "s2",
#     "digest"
#   )
# )
#
# rmapshaper's sys = TRUE path shells out to `mapshaper-xl`, so the mapshaper
# npm package has to be on PATH as well: npm install -g mapshaper

library(magrittr)
library(tidyverse)
library(sf)
library(arrow)
library(rmapshaper)
library(s2)

source("R/s3-archive.R")
s3_bucket_name <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix      <- Sys.getenv("S3_PREFIX", unset = "census-counties")
publish        <- Sys.getenv("PUBLISH", unset = "1") == "1"

## Credentials are only needed to publish, so a PUBLISH=0 build runs without
## them. Locally: aws sso login --profile mco
if (publish) s3_preflight()

sf::sf_use_s2(TRUE)

## Each vintage needs its own cb file, so a full build fetches 18 of them.
## Caching makes a rerun free; a CI runner starts empty and is unaffected.
options(tigris_use_cache = TRUE)

bag_dir <- "census-counties"

dir.create(
  file.path(bag_dir, "data", "raw"),
  recursive = TRUE,
  showWarnings = FALSE
)

dir.create(
  file.path(bag_dir, "data", "parquet"),
  recursive = TRUE,
  showWarnings = FALSE
)

dir.create(
  file.path(bag_dir, "data", "clipped"),
  recursive = TRUE,
  showWarnings = FALSE
)

dir.create(
  file.path(bag_dir, "data", "quality"),
  recursive = TRUE,
  showWarnings = FALSE
)

quality_file <-
  file.path(bag_dir, "data", "quality", "geometry_validation.csv")

## Membership in the S3 listing — not a local file, and not a full download —
## decides whether a vintage is already archived. A CI runner starts empty, so
## asking S3 is the only way to know what exists without pulling ~3 GB every
## week to discover that nothing changed.
archived <-
  if (publish) {
    tryCatch(
      s3_list_keys(s3_bucket_name, s3_prefix) %>%
        dplyr::pull(Key) %>%
        stringr::str_remove(paste0("^", s3_prefix, "/")),
      error = function(e) character(0)
    )
  } else {
    character(0)
  }

## s3_pull() is a sync, and sync treats its destination as a directory — so
## pulling one file with it creates a directory of that name and reads back
## nothing. The stateful files below are fetched with cp instead, which is what
## usdm does for its own quality log, for the same reason.
s3_get_file <-
  function(key, dest){
    s3_run(c("s3", "cp",
             paste0("s3://", s3_bucket_name, "/", key),
             dest),
           echo = FALSE)
  }

## The prior manifest, so its hashes survive a merge rather than being dropped.
manifest <-
  if ("manifest-sha256.txt" %in% archived) {
    try({
      s3_get_file(paste0(s3_prefix, "/manifest-sha256.txt"),
                  file.path(bag_dir, "manifest-sha256.txt"))

      file.path(bag_dir, "manifest-sha256.txt") %>%
        readr::read_fwf(readr::fwf_widths(c(64, NA), c("hash", "file")),
                        show_col_types = FALSE) %>%
        dplyr::mutate(file = stringr::str_trim(file))
    }, silent = TRUE)
  } else {
    NULL
  }

## The validity log is stateful the same way the manifest is: it accumulates
## across runs, so a run that builds one new vintage has to append to what is
## already archived rather than replace it.
if ("data/quality/geometry_validation.csv" %in% archived)
  try(s3_get_file(paste0(s3_prefix, "/data/quality/geometry_validation.csv"),
                  quality_file),
      silent = TRUE)

## Census posts a new TIGER vintage each autumn, so the vintages are discovered
## rather than hardcoded: generate candidates out to next calendar year, keep
## whichever URLs resolve. A new release is picked up the week it appears.
tl_urls <-
  c(
    `2000` =
      "https://www2.census.gov/geo/tiger/TIGER2010/COUNTY/2000/tl_2010_us_county00.zip",
    `2009` =
      "https://www2.census.gov/geo/tiger/TIGER2009/tl_2009_us_county.zip",
    `2010` =
      "https://www2.census.gov/geo/tiger/TIGER2010/COUNTY/2010/tl_2010_us_county10.zip",
    2011:(lubridate::year(lubridate::today()) + 1) %>%
      magrittr::set_names(., .) %>%
      purrr::map_chr(
        \(x){
          paste0(
            "https://www2.census.gov/geo/tiger/TIGER", x, "/COUNTY/tl_", x, "_us_county.zip"
          )
        }
      )
  ) %>%
  .[purrr::map_lgl(., url_exists)]

## VINTAGES=2000,2020 narrows a run to those vintages, which is the difference
## between iterating on one and rebuilding eighteen.
vintages <-
  Sys.getenv("VINTAGES", unset = "") %>%
  stringr::str_split_1(",") %>%
  stringr::str_trim() %>%
  purrr::discard(~ .x == "")

if (length(vintages)) {
  stopifnot(all(vintages %in% names(tl_urls)))
  tl_urls <- tl_urls[vintages]
  message("VINTAGES set: building ", paste(vintages, collapse = ", "))
}

## Nothing new to build means nothing to restack either, so stop before
## pulling 3 GB to rediscover it. Census posts a vintage once a year.
if (publish &&
    all(paste0("data/clipped/", names(tl_urls), "-counties.parquet") %in% archived)) {
  gate_skip(paste0("All ", length(tl_urls),
                   " vintages already archived; nothing to build."))
  quit(save = "no", status = 0)
}

## ---- Geometry accounting -------------------------------------------------
## Everything below parses with check = FALSE. sf routes through s2 with
## checking on, so on invalid geometry st_is_valid(), st_make_valid() and
## st_union() throw at the WKB gate instead of reporting or repairing.
s2_geog <-
  function(x){
    x %>%
      sf::st_geometry() %>%
      sf::st_as_binary() %>%
      s2::s2_geog_from_wkb(check = FALSE)
  }

s2_valid <-
  function(x){
    s2::s2_is_valid(s2_geog(x))
  }

s2_apply <-
  function(x, f){
    sf::st_geometry(x) <-
      x %>%
      s2_geog() %>%
      f() %>%
      s2::s2_as_binary() %>%
      structure(class = "WKB") %>%
      sf::st_as_sfc(crs = sf::st_crs(x))

    x
  }

## Dropping the CRS forces the planar answer: geometry with no CRS is not
## longlat, so sf hands it to GEOS. More reliable than sf_use_s2(FALSE), which
## does not hold inside a pipeline that also toggles it.
planar <-
  function(x){
    sf::st_set_crs(sf::st_geometry(x), NA)
  }

planar_area <-
  function(x){
    as.numeric(sf::st_area(planar(x)))
  }

## Every measurement one operation can be held to, in one pass. Both areas are
## kept: s2_area() is the meaningful number in m², and the planar one is what
## the repair guard compares, since on a self-crossing loop s2's own area is as
## suspect as the ring.
geom_stats <-
  function(x){
    g  <- s2_geog(x)
    v  <- s2::s2_is_valid_detail(g)
    pl <- planar(x)
    mp <- sf::st_cast(sf::st_geometry(x), "MULTIPOLYGON", warn = FALSE)

    tibble::tibble(
      s2_valid    = v$is_valid,
      s2_reason   = v$reason,
      geos_valid  = sf::st_is_valid(pl),
      geos_reason = dplyr::na_if(sf::st_is_valid(pl, reason = TRUE), "Valid Geometry"),
      area_m2     = s2::s2_area(g),
      planar_area = as.numeric(sf::st_area(pl)),
      n_vertices  = s2::s2_num_points(g),
      n_parts     = vapply(mp, length, integer(1)),
      n_rings     = vapply(mp, \(p) sum(lengths(p)), integer(1))
    )
  }

## ---- The validity log ----------------------------------------------------
## Per-county record of what enforcing validity changed, written to
## data/quality/geometry_validation.csv. Untouched features get no row.
##
## A row is emitted when the vertex, part or ring count changed, the area moved
## by more than 1 m², or the feature arrived or left invalid under either
## engine. The area threshold is not zero because a no-op reprojection still
## perturbs the last bits; an exact test would flag every county and say
## nothing. `keep` overrides the rule where it asks the wrong question — the
## clip is meant to change coastal counties, so a clip row means it broke one.
log_change <-
  function(before, after, fips, year, stage, method,
           mask_year = NA_integer_, keep = NULL){
    b <- geom_stats(before)
    a <- geom_stats(after)

    if (is.null(keep))
      keep <-
        b$n_vertices != a$n_vertices |
        b$n_parts    != a$n_parts |
        b$n_rings    != a$n_rings |
        abs(a$area_m2 - b$area_m2) > 1 |
        !b$s2_valid | !a$s2_valid | !b$geos_valid | !a$geos_valid

    tibble::tibble(
      year               = as.integer(year),
      fips               = fips,
      stage              = stage,
      method             = method,
      s2_valid_before    = b$s2_valid,
      s2_valid_after     = a$s2_valid,
      s2_reason_before   = b$s2_reason,
      s2_reason_after    = a$s2_reason,
      geos_valid_before  = b$geos_valid,
      geos_valid_after   = a$geos_valid,
      geos_reason_before = b$geos_reason,
      area_m2_before     = b$area_m2,
      area_m2_after      = a$area_m2,
      area_delta_m2      = a$area_m2 - b$area_m2,
      area_ratio         = a$planar_area / b$planar_area,
      n_vertices_before  = b$n_vertices,
      n_vertices_after   = a$n_vertices,
      n_parts_before     = b$n_parts,
      n_parts_after      = a$n_parts,
      n_rings_before     = b$n_rings,
      n_rings_after      = a$n_rings,
      mask_year          = as.integer(mask_year),
      build_date         = Sys.Date()
    )[keep, ]
  }

## Appended per vintage rather than accumulated to the end of the run, so a
## build that dies on vintage 14 still leaves the record of the thirteen it
## finished. Following usdm, which does the same with its own quality log.
quality_append <-
  function(rows){
    if (!nrow(rows)) return(invisible(rows))

    readr::write_excel_csv(rows,
                           quality_file,
                           append = file.exists(quality_file))

    invisible(rows)
  }

## ---- Repair --------------------------------------------------------------
## Three repairs, because they fail on different geometry. GEOS runs first: it
## is the only one that will touch a self-crossing ring at all. On clipped
## geometry st_make_valid() can return a GEOMETRYCOLLECTION — a polygon plus
## the stray line where the mask grazed an edge — so extract the areal part.
geos_repair <-
  function(x){
    g <-
      x %>%
      planar() %>%
      sf::st_make_valid() %>%
      sf::st_collection_extract("POLYGON", warn = FALSE) %>%
      sf::st_cast("MULTIPOLYGON", warn = FALSE)

    stopifnot(length(g) == nrow(x))

    sf::st_geometry(x) <- sf::st_set_crs(g, sf::st_crs(x))

    x
  }

## The rebuild snaps coordinates to a 1e-7 degree grid, about a centimetre.
## TIGER/Line carries six decimal places, so the grid is finer than the source
## and a real vertex cannot move; what it does resolve is duplicate vertices
## and edges that cross only as geodesics, which is most of the damage.
s2_rebuild_repair <-
  function(x){
    s2_apply(x, \(g) s2::s2_rebuild(g, s2::s2_options(snap = s2::s2_snap_precision(1e7))))
  }

## The union reaches rings the rebuild cannot, and is a trap taken alone: where
## a hole crosses its own shell the two cancel and the feature leaves as empty
## geometry. El Dorado, Shelby and the District of Columbia all vanished this
## way before the area guard below existed.
s2_union_repair <-
  function(x){
    s2_apply(x, s2::s2_union)
  }

## Valid features are returned untouched, byte for byte — not an optimisation:
## rebuilding good geometry would make the validity log meaningless, since
## every feature would report as changed.
##
## No repair is trusted on its word. st_make_valid() under s2 once returned
## Clark County WA with its winding inverted, a NEGATIVE area of 1.7e9 m² that
## every validity check calls fine and that deletes the county the moment
## anything unions it. So a candidate is accepted only if it is s2-valid AND
## holds the area it was handed; otherwise the feature keeps what it arrived
## with, as `kept_as_is`. The method comes back as an attribute so the caller
## can log it without breaking the pipe.
census_repair <-
  function(x, tolerance = 0.001){
    method <- rep("none", nrow(x))
    broken <- with(geom_stats(x), !s2_valid | !geos_valid)

    if (!any(broken)) {
      attr(x, "repair_method") <- method
      return(x)
    }

    damaged <- x[broken, ]
    before  <- planar_area(damaged)

    accept <-
      function(candidate){
        check <- geom_stats(candidate)

        check$s2_valid &
          check$planar_area > 0 &
          check$planar_area >= before * (1 - tolerance)
      }

    geos    <- geos_repair(damaged)
    rebuilt <- s2_rebuild_repair(geos)
    unioned <- s2_union_repair(geos)

    take_geos    <- accept(geos)
    take_rebuilt <- !take_geos & accept(rebuilt)
    take_unioned <- !take_geos & !take_rebuilt & accept(unioned)
    kept         <- !take_geos & !take_rebuilt & !take_unioned

    sf::st_geometry(damaged)[take_geos]    <- sf::st_geometry(geos)[take_geos]
    sf::st_geometry(damaged)[take_rebuilt] <- sf::st_geometry(rebuilt)[take_rebuilt]
    sf::st_geometry(damaged)[take_unioned] <- sf::st_geometry(unioned)[take_unioned]

    chose <- rep("kept_as_is", nrow(damaged))
    chose[take_geos]    <- "geos_make_valid"
    chose[take_rebuilt] <- "s2_rebuild"
    chose[take_unioned] <- "s2_union"

    if (any(kept))
      message("  no repair held for ", sum(kept),
              " feature(s); keeping the geometry they arrived with")

    sf::st_geometry(damaged) <-
      sf::st_cast(sf::st_geometry(damaged), "MULTIPOLYGON", warn = FALSE)

    sf::st_geometry(x)[broken] <- sf::st_geometry(damaged)
    method[broken] <- chose

    attr(x, "repair_method") <- method

    x
  }

repair_method <-
  function(x){
    method <- attr(x, "repair_method")

    if (is.null(method)) rep("none", nrow(x)) else method
  }

## ---- The clip mask -------------------------------------------------------
## An enclosed ring in a waterline is real water or an artifact, and at 500k
## none is real — every Great Lake drains through Canada. Dropping them is
## where the mask's validity comes from: on cb 2010 the union returns 520 parts
## carrying 5,036 rings and is s2-invalid ("Loop 4565: Edge 0 is degenerate"),
## and dropping the 4,516 interior rings leaves 520 and passes both engines, at
## 6.36 km² out of 9,339,011. Left in, each punches a pinhole through whichever
## county it lands on. The threshold is a guard, not a filter: a ring big
## enough to be real water is kept and announced.
fill_holes <-
  function(g, max_hole = 1e-4){
    parts <-
      g %>%
      sf::st_cast("MULTIPOLYGON", warn = FALSE) %>%
      purrr::map(\(mp) purrr::map(mp, identity)) %>%
      purrr::list_flatten()

    ring_area <-
      \(r) abs(as.numeric(sf::st_area(sf::st_polygon(list(r)))))

    filled <- 0L
    kept   <- 0L

    out <-
      parts %>%
      purrr::map(\(p){
        if (length(p) == 1L) return(p)

        big <- purrr::map_lgl(p[-1], \(r) ring_area(r) > max_hole)

        filled <<- filled + sum(!big)
        kept   <<- kept + sum(big)

        p[c(TRUE, big)]
      })

    message("  mask: filled ", filled, " interior ring(s) below the threshold",
            if (kept) paste0("; KEPT ", kept, " above it — check they are water") else "")

    sf::st_sfc(sf::st_multipolygon(out), crs = sf::st_crs(g))
  }

## Cutting 2012 land with a 2024 coastline yields a boundary belonging to
## neither year, so each vintage is clipped with its own cb. Census publishes
## one for 2010 (GENZ2010, gz_ naming), 2013 (no shp/ subdir) and 2014 onward;
## the four years without fall back to the nearest, recorded in `mask_year`.
mask_years <-
  c(`2000` = 2010L, `2009` = 2010L, `2011` = 2010L, `2012` = 2013L)

## Every cb 500k county vintage Census publishes. The mask_years table above
## picks which one a tl vintage is clipped with; this is the pool a gap in that
## choice is filled from, tried nearest-first. Candidates that do not resolve
## are skipped, so the list needs no maintenance as Census adds years.
cb_years <-
  c(2010L, 2013L, seq(2014L, lubridate::year(lubridate::today()) + 1L))

## tigris normalizes the 2010 gz_ schema, so STATEFP and COUNTYFP are present
## on every vintage even though the shapefile calls them STATE and COUNTY.
cb_counties <-
  function(year){
    tigris::counties(cb = TRUE,
                     resolution = "500k",
                     year = year,
                     progress_bar = FALSE) %>%
      dplyr::select(STATEFP, COUNTYFP) %>%
      sf::st_transform("EPSG:4269")
  }

## The mask is unioned in spherical geometry, NOT with ms_explode() +
## ms_dissolve(). Mapshaper snapped 2,588 points building the old one: cb 2010
## arrives with 3,221 features and zero s2-invalid, and came out s2-invalid in
## 2,430 disconnected pieces instead of ~520, with 1,935 degenerate holes.
## Clipping against that produced 123 invalid counties on the 2000 vintage,
## including landlocked ones the clip should never have touched.
##
## st_union() under s2 dissolves to 520 parts and matches the old mask's area
## to eight significant figures. It is not valid on its own — fill_holes()
## above is what makes it so.
census_waterline <-
  function(year, states){
    mask_year <-
      dplyr::coalesce(unname(mask_years[as.character(year)]), as.integer(year))

    if (mask_year != year)
      message("  no cb ", year, " exists; clipping with cb ", mask_year)

    cb <- dplyr::mutate(cb_counties(mask_year), cb_year = mask_year)

    ## A cb vintage need not cover every state its tl counterpart carries. cb
    ## 2010 is the only one with no American Samoa, Guam, Northern Marianas or
    ## US Virgin Islands — and tl 2009 and tl 2011 have all four and both fall
    ## back to it. Clipping those 13 counties against a mask that does not
    ## reach them deletes them outright, silently, because mapshaper's -clean
    ## drops null geometries by default. That is how this was found.
    ##
    ## So the states the chosen cb misses are supplied from the nearest cb
    ## vintage that has them, and the year used is recorded per county rather
    ## than per vintage. It is the same principle as mask_years, one level
    ## down: keep the nearest coastline wherever one exists, and make the
    ## substitution data rather than an assumption a reader has to reconstruct.
    missing <- setdiff(states, cb$STATEFP)

    for (candidate in cb_years[order(abs(cb_years - mask_year))]) {
      if (!length(missing)) break
      if (candidate == mask_year) next

      supplement <- try(cb_counties(candidate), silent = TRUE)

      if (inherits(supplement, "try-error")) next

      supplement <- dplyr::filter(supplement, STATEFP %in% missing)

      if (!nrow(supplement)) next

      message("  cb ", mask_year, " does not cover state(s) ",
              paste(sort(unique(supplement$STATEFP)), collapse = ", "),
              "; supplying them from cb ", candidate)

      cb      <- dplyr::bind_rows(cb, dplyr::mutate(supplement, cb_year = candidate))
      missing <- setdiff(missing, supplement$STATEFP)
    }

    if (length(missing))
      stop("no cb vintage covers state(s) ", paste(missing, collapse = ", "),
           " carried by tl ", year, call. = FALSE)

    repaired <- census_repair(cb)

    unioned <-
      repaired %>%
      sf::st_geometry() %>%
      sf::st_union()

    mask <- fill_holes(unioned)

    stopifnot(all(s2::s2_is_valid(s2::s2_geog_from_wkb(sf::st_as_binary(mask),
                                                       check = FALSE))))

    list(
      mask = sf::st_sf(geometry = mask),
      mask_year = mask_year,
      ## A composite mask has no single answer, so the answer is per state and
      ## the clipped form carries it per county.
      mask_year_by_state =
        cb %>%
        sf::st_drop_geometry() %>%
        dplyr::distinct(STATEFP, cb_year) %>%
        {magrittr::set_names(.$cb_year, .$STATEFP)},
      log =
        dplyr::bind_rows(
          ## Per cb county, where repairing one changed it — carrying the cb
          ## vintage that county actually came from, not the vintage's nominal
          ## mask year.
          log_change(
            before = cb,
            after = repaired,
            fips = paste0(cb$STATEFP, cb$COUNTYFP),
            year = year,
            stage = "mask_repair",
            method = repair_method(repaired),
            mask_year = cb$cb_year
          ),
          ## And one row for the mask itself, which is where the ring count
          ## and the area the hole-filling put back are recorded. Always
          ## written: a mask that changed nothing is worth saying out loud,
          ## because it is the input every clipped county depends on.
          log_change(
            before = sf::st_sf(geometry = unioned),
            after = sf::st_sf(geometry = mask),
            fips = "<mask>",
            year = year,
            stage = "mask_fill_holes",
            method = "fill_holes",
            mask_year = mask_year,
            keep = TRUE
          )
        )
    )
  }

## ---- The clip ------------------------------------------------------------
## One mapshaper process, one topology build. Mapshaper rebuilds arc topology
## every time it reads GeoJSON, so cleaning in a second invocation re-snaps
## what the first just fixed. Chained, on the 2000 vintage: 13 s2-invalid with
## no flags, 12 with remove-slivers, 0 with remove-slivers and -clean rewind.
## -clean rewind is the winding-order repair (as in fsa-counties-dd17/dd22).
##
## Done by hand because rmapshaper::ms_clip() silently drops remove_slivers on
## the sys = TRUE path and cannot chain -clean. GeoJSON via geojsonsf, not
## sf::write_sf(): GDAL's GeoJSON driver rewrites NAD83 to CRS84.
census_clip <-
  function(x, mask, mem = 16){
    target_file <- tempfile(fileext = ".geojson")
    mask_file   <- tempfile(fileext = ".geojson")

    on.exit(unlink(c(target_file, mask_file)), add = TRUE)

    writeLines(geojsonsf::sf_geojson(x), target_file)
    writeLines(geojsonsf::sf_geojson(sf::st_sf(geometry = sf::st_geometry(mask))),
               mask_file)

    out <-
      rmapshaper::apply_mapshaper_commands(
        target_file,
        command = paste("-clip", shQuote(mask_file), "remove-slivers -clean rewind"),
        force_FC = TRUE,
        sys = TRUE,
        sys_mem = mem,
        quiet = TRUE
      )

    on.exit(unlink(out), add = TRUE)

    clipped <-
      out %>%
      sf::read_sf() %>%
      sf::st_cast("MULTIPOLYGON", warn = FALSE)

    suppressWarnings(sf::st_crs(clipped) <- sf::st_crs(x))

    clipped
  }

## The escape hatch that lets the clipped form promise s2 validity rather than
## hope for it: a valid county intersected with a valid mask in spherical
## geometry is valid by construction. Re-clips from the raw vintage, not from
## the damaged output. Costs almost nothing — on the 13 counties mapshaper left
## invalid before -clean rewind, it matched their areas to six figures.
s2_clip <-
  function(x, mask){
    m <-
      mask %>%
      sf::st_geometry() %>%
      sf::st_as_binary() %>%
      s2::s2_geog_from_wkb(check = FALSE)

    x %>%
      s2_apply(\(g) s2::s2_intersection(g, m)) %>%
      ## An intersection can graze an edge and return the touch as a line, and
      ## can collapse a multipart county to one part. Neither may reach the
      ## writer: the rest of the archive is MULTIPOLYGON.
      sf::st_collection_extract("POLYGON", warn = FALSE) %>%
      sf::st_cast("MULTIPOLYGON", warn = FALSE)
  }

## ---- Raw TIGER/Line, one parquet per vintage ----
## Column names drift across vintages — COUNTYFP00, COUNTYFP10, plain COUNTYFP
## — so select on the prefix. County names arrive latin1 and must be recoded or
## every accented name is mojibake downstream.
##
## Repaired under both s2 and planar geometry, since a ring one engine accepts
## the other can reject. Exploding to POLYGON first keeps a single bad ring
## from condemning a whole multipart county.
tl_parquet <-
  tl_urls %>%
  purrr::imap_chr(\(url, year){
    outfile <-
      file.path(bag_dir, "data", "parquet", paste0(year, "-counties.parquet"))

    if (!file.exists(outfile) &&
        !(paste0("data/parquet/", basename(outfile)) %in% archived)) {
      zipfile <-
        file.path(bag_dir, "data", "raw", basename(url))

      if (!file.exists(zipfile))
        curl::multi_download(urls = url,
                             destfiles = zipfile,
                             resume = TRUE)

      source_sf <-
        zipfile %>%
        file.path("/vsizip", .) %>%
        sf::read_sf() %>%
        dplyr::select(
          STATEFP = dplyr::starts_with("STATEFP"),
          COUNTYFP = dplyr::starts_with("COUNTYFP"),
          County = dplyr::starts_with("NAME") & !dplyr::starts_with("NAMELSAD"),
          `CountyLSAD` = dplyr::starts_with("NAMELSAD")
        ) %>%
        dplyr::mutate(
          County = iconv(County, from = "latin1", to = "UTF-8"),
          `CountyLSAD` = iconv(`CountyLSAD`, from = "latin1", to = "UTF-8"),
          year = as.integer(year)
        )

      raw_sf <-
        source_sf %>%
        sf::st_cast("MULTIPOLYGON") %>%
        sf::st_cast("POLYGON", warn = FALSE, do_split = TRUE) %>%
        sf::st_make_valid() %T>%
        {suppressMessages(sf::sf_use_s2(FALSE))} %>%
        sf::st_make_valid() %T>%
        {suppressMessages(sf::sf_use_s2(TRUE))} %>%
        # Group by county and generate multipolygons
        dplyr::group_by(STATEFP, COUNTYFP, County, `CountyLSAD`, year) %>%
        dplyr::summarise(.groups = "drop",
                         is_coverage = TRUE) %>%
        sf::st_cast("MULTIPOLYGON", warn = FALSE) %>%
        sf::st_transform("EPSG:4269") %>%
        dplyr::mutate(Area = sf::st_area(geometry)) %>%
        dplyr::select(STATEFP, COUNTYFP, County, `CountyLSAD`, year, Area) %T>%
        sf::write_sf(
          outfile,
          driver = "Parquet",
          layer_options = c("COMPRESSION=ZSTD",
                            "COMPRESSION_LEVEL=13"),
          delete_dsn = TRUE
        )

      ## What the repair above cost, per county. The summarise() is a coverage
      ## union, so the comparison has to be county to county: one row per
      ## county on both sides, matched on FIPS, because a tl county file
      ## carries one row per county and the summarise sorts by the group keys.
      before <-
        source_sf %>%
        sf::st_cast("MULTIPOLYGON", warn = FALSE) %>%
        sf::st_transform("EPSG:4269") %>%
        dplyr::mutate(fips = paste0(STATEFP, COUNTYFP)) %>%
        dplyr::arrange(fips)

      after <-
        raw_sf %>%
        dplyr::mutate(fips = paste0(STATEFP, COUNTYFP)) %>%
        dplyr::arrange(fips)

      stopifnot(identical(before$fips, after$fips))

      log_change(
        before = before,
        after = after,
        fips = before$fips,
        year = year,
        stage = "raw_repair",
        method = "st_make_valid + s2_coverage_union"
      ) %>%
        quality_append()
    }

    return(outfile)
  })

## ---- Clip each vintage to its own waterline ----
## tl boundaries are the legal ones and what the usdm-counties aggregations are
## computed against, so the raw form above stays unaltered. But tl does not stop
## at water — coastal and Great Lakes counties run far offshore, correct as a
## boundary and misleading as a picture. This form is for display, and derived.
##
## One clip, one round of validation, no loop. The loop that used to live here
## (explode, repair, dissolve, repair, six passes) could not converge, because
## mapshaper introduces the damage and the loop kept running it last. With a
## valid mask and -clean rewind nothing is left for a second pass: 0 s2-invalid
## of 3,219 on the 2000 vintage, against 123 before. The repair and the
## spherical fallback stay as guards.
##
## Geometry travels through mapshaper carrying only `id`; attributes are joined
## back afterwards from the raw vintage.
clipped_parquet <-
  tl_urls %>%
  names() %>%
  magrittr::set_names(., .) %>%
  purrr::imap_chr(\(year, .y){
    outfile <-
      file.path(bag_dir, "data", "clipped", paste0(year, "-counties.parquet"))

    if (!file.exists(outfile) &&
        !(paste0("data/clipped/", basename(outfile)) %in% archived)) {
      message("=== ", year, " ===")

      tl <-
        file.path(bag_dir, "data", "parquet", paste0(year, "-counties.parquet")) %>%
        sf::read_sf() %>%
        sf::st_transform("EPSG:4269") %>%
        dplyr::mutate(id = paste0(STATEFP, COUNTYFP)) %>%
        dplyr::arrange(id)

      waterline <- census_waterline(year, unique(tl$STATEFP))
      quality_append(waterline$log)

      ## Per county, because the mask can be composite: on tl 2009 and 2011 the
      ## mainland is cut at the cb 2010 coastline and the four island
      ## territories at cb 2013, and a reader should be able to see which.
      county_mask_year <-
        unname(waterline$mask_year_by_state[tl$STATEFP])

      stopifnot(!anyNA(county_mask_year))

      clipped <-
        tl %>%
        dplyr::select(id) %>%
        census_clip(waterline$mask) %>%
        dplyr::arrange(id)

      if (!identical(tl$id, clipped$id)) {
        lost  <- setdiff(tl$id, clipped$id)
        extra <- setdiff(clipped$id, tl$id)

        stop("the clip lost ", length(lost), " and gained ", length(extra),
             " counties on ", year, ": ",
             paste(head(c(lost, extra), 20), collapse = ", "),
             call. = FALSE)
      }

      clip_stats <- geom_stats(clipped)

      ## The clip is meant to change coastal counties, so a row here does not
      ## mean the clip worked — it means the clip broke something.
      log_change(
        before = tl,
        after = clipped,
        fips = clipped$id,
        year = year,
        stage = "clip",
        method = "mapshaper_clip",
        mask_year = county_mask_year,
        keep = with(clip_stats, !s2_valid | !geos_valid)
      ) %>%
        quality_append()

      message("  clip returned ", sum(!clip_stats$s2_valid), " s2-invalid, ",
              sum(!clip_stats$geos_valid), " GEOS-invalid")

      repaired <- census_repair(clipped)

      log_change(
        before = clipped,
        after = repaired,
        fips = clipped$id,
        year = year,
        stage = "clip_repair",
        method = repair_method(repaired),
        mask_year = county_mask_year
      ) %>%
        quality_append()

      ## Anything the repair could not make s2-valid is re-clipped from the raw
      ## vintage in spherical geometry, where the result cannot be invalid.
      residual <- !s2_valid(repaired)

      if (any(residual)) {
        message("  ", sum(residual), " county(s) still s2-invalid; ",
                "re-clipping those spherically")

        fallback <-
          tl[residual, ] %>%
          dplyr::select(id) %>%
          s2_clip(waterline$mask)

        log_change(
          before = repaired[residual, ],
          after = fallback,
          fips = repaired$id[residual],
          year = year,
          stage = "clip_s2_fallback",
          method = "s2_intersection",
          mask_year = county_mask_year[residual],
          keep = rep(TRUE, sum(residual))
        ) %>%
          quality_append()

        sf::st_geometry(repaired)[residual] <- sf::st_geometry(fallback)
      }

      ## The clipped form promises s2 validity rather than hoping for it.
      stopifnot(all(s2_valid(repaired)),
                !any(sf::st_is_empty(repaired)),
                all(planar_area(repaired) > 0))

      message("  ", nrow(repaired), " counties, all s2-valid")

      repaired %>%
        dplyr::left_join(
          tl %>%
            sf::st_drop_geometry() %>%
            dplyr::select(id, STATEFP, COUNTYFP, County, `CountyLSAD`, year),
          by = dplyr::join_by(id)
        ) %>%
        dplyr::mutate(
          mask_year = unname(waterline$mask_year_by_state[STATEFP]),
          Area = sf::st_area(geometry)
        ) %>%
        dplyr::arrange(id) %>%
        dplyr::select(STATEFP, COUNTYFP, County, `CountyLSAD`,
                      year, mask_year, Area) %>%
        sf::write_sf(
          outfile,
          driver = "Parquet",
          layer_options = c("COMPRESSION=ZSTD",
                            "COMPRESSION_LEVEL=13"),
          delete_dsn = TRUE
        )
    }

    return(outfile)
  })

## ---- Stack every clipped vintage into one file ----
## One row per county per vintage, sorted by fips then year. The order is doing
## real work: Parquet compresses a ~1 MB page at a time and a county averages
## 39 kB, so a page holds ~26 features — one county's eighteen near-identical
## vintages, which ZSTD collapses, rather than 26 unrelated counties. Over all
## 58,182 rows: 867.1 MB by (year, fips), 107.5 MB by (fips, year).
##
## ROW_GROUP_SIZE is not tuning, it is what makes the write possible. GDAL
## defaults to 65,536 rows per group, more than this file has, so the stack
## landed in one row group whose geometry column became a single Arrow
## BinaryArray — capped at 2 GiB against 2.26 GB of WKB, failing on feature
## 55,354. 2,000 also compresses best (107.5 MB, vs 109.5 at 5,000 and 110.6 at
## 40,000) and leaves 27x headroom under the cap for future vintages.
census_counties <-
  clipped_parquet %>%
  purrr::map(sf::read_sf) %>%
  dplyr::bind_rows() %>%
  dplyr::mutate(fips = paste0(STATEFP, COUNTYFP)) %>%
  dplyr::relocate(fips) %>%
  dplyr::arrange(fips, year) %T>%
  sf::write_sf(
    "census-counties.parquet",
    driver = "Parquet",
    layer_options = c("COMPRESSION=ZSTD",
                      "COMPRESSION_LEVEL=13",
                      "ROW_GROUP_SIZE=2000"),
    delete_dsn = TRUE
  )

message(nrow(census_counties), " rows, ",
        dplyr::n_distinct(census_counties$fips), " counties, ",
        dplyr::n_distinct(census_counties$year), " vintages")

# ---- Write bagit.txt ----
writeLines(c(
  "BagIt-Version: 0.97",
  "Tag-File-Character-Encoding: UTF-8"
), file.path(bag_dir, "bagit.txt"))

# ---- Write bag-info.txt ----
writeLines(c(
  paste("Bag-Software-Agent:", "R Census Counties Archive BagIt Pipeline"),
  paste("Bagging-Date:", Sys.Date()),
  "Contact-Name: R. Kyle Bocinsky",
  "Contact-Email: kyle.bocinsky@umontana.edu",
  "Source-Organization: Montana Climate Office, University of Montana",
  "External-Description: Vintage-matched GeoParquet archive of US Census county boundaries, raw and clipped to each vintage's cartographic waterline"
), file.path(bag_dir, "bag-info.txt"))

# ---- Update manifest-sha256.txt with newly created files ----
# On a fresh (CI) runner the local bag holds only this run's new files, so
# merge their hashes into the pulled manifest rather than dropping the rest.
new_files <-
  list.files(file.path(bag_dir, "data"),
             recursive = TRUE,
             full.names = TRUE)

new_hashes <-
  tibble::tibble(
    file = gsub(paste0(bag_dir, "/"), "", new_files),
    hash = purrr::map_chr(new_files, digest::digest,
                          algo = "sha256", file = TRUE)
  )

manifest_updated <-
  {if (inherits(manifest, "data.frame")) dplyr::anti_join(manifest, new_hashes, by = "file")
   else tibble::tibble(hash = character(0), file = character(0))} %>%
  dplyr::bind_rows(new_hashes) %>%
  dplyr::arrange(file)

writeLines(paste0(manifest_updated$hash, "  ", manifest_updated$file),
           file.path(bag_dir, "manifest-sha256.txt"))

## ---- Publish to S3 (append-only: never --delete) ----------------------
if (!publish) {
  message("PUBLISH=0 — built locally, nothing uploaded")
} else {
  s3_push(s3_bucket_name, s3_prefix, bag_dir, delete = FALSE)
  s3_verify(s3_bucket_name, s3_prefix, bag_dir,
            allow_extra = character(0),
            expect_exact = FALSE)

  s3_put(s3_bucket_name,
         paste0(s3_prefix, "/census-counties.parquet"),
         "census-counties.parquet",
         content_type = "application/vnd.apache.parquet",
         cache_control = "max-age=3600")

  # ---- Regenerate census-counties-manifest.json from the S3 listing ----
  generate_tree_flat <- function(
    output_file = file.path("census-counties-manifest.json")) {

    hashes <-
      manifest_updated %>%
      {magrittr::set_names(as.list(.$hash), .$file)}

    entries <-
      s3_list_keys(s3_bucket_name, s3_prefix) %>%
      dplyr::mutate(path = stringr::str_remove(Key, paste0("^", s3_prefix, "/"))) %>%
      dplyr::filter(!startsWith(path, "_")) %>%
      dplyr::arrange(path) %>%
      purrr::pmap(\(Key, Size, path){
        entry <- list(path = path, size = Size)
        if (!is.null(hashes[[path]])) entry$hash <- hashes[[path]]
        entry
      })

    jsonlite::write_json(entries, output_file, pretty = TRUE, auto_unbox = TRUE)
    message("✅ Wrote ", length(entries), " entries to ", output_file)
  }

  generate_tree_flat()

  s3_put(s3_bucket_name,
         paste0(s3_prefix, "/census-counties-manifest.json"),
         "census-counties-manifest.json",
         content_type = "application/json",
         cache_control = "max-age=3600")

  s3_write_manifest(s3_bucket_name, s3_prefix)

  cf_invalidate(
    c(paste0("/", s3_prefix, "/census-counties.parquet"),
      paste0("/", s3_prefix, "/census-counties-manifest.json"),
      paste0("/", s3_prefix, "/manifest-sha256.txt"),
      paste0("/", s3_prefix, "/data/quality/geometry_validation.csv"),
      paste0("/", s3_prefix, "/_manifest.txt"))
  )

  cf_wait_manifest(
    paste0(Sys.getenv("CLOUDFRONT_BASE",
                      unset = "https://data.sustainable-fsa.com"),
           "/", s3_prefix, "/census-counties-manifest.json"),
    "census-counties-manifest.json")

  ## Only after publishing: the Quick Start chunk reads the archive from the
  ## CDN, so rendering before the upload documents whatever was there before.
  rmarkdown::render("README.Rmd")
}
