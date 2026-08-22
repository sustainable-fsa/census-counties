# census-counties

An archive of **vintage-matched US Census county boundaries** — the boundaries
the county-level determinations in the [Sustainable
FSA](https://sustainable-fsa.com) project were computed against.

Three artifacts, all in real coordinate systems (NAD83, EPSG:4269):

| artifact | what it is |
|---|---|
| `data/parquet/YYYY-counties.parquet` | raw TIGER/Line counties, exactly as Census published them |
| `data/clipped/YYYY-counties.parquet` | the same, cut at that vintage's cb 500k waterline |
| `census-counties.parquet` | every clipped vintage stacked, one row per county per year |

## Why both raw and clipped

TIGER/Line (`tl_`) county boundaries are the legal ones, and they are what the
weekly USDM county aggregations in
[`usdm-counties`](https://github.com/sustainable-fsa/usdm-counties) are computed
against. So `tl` is the analytical truth and this archive keeps it unaltered.

But `tl` does not stop at water. Coastal counties and the Great Lakes states
extend far offshore — correct as a legal boundary, useless as a picture. The
clipped form exists so a map can show a county's land without pretending the
lake is part of it. **It is derived, never authoritative.**

## The clip mask matches the vintage

Cutting 2012 land with a 2024 coastline produces a boundary belonging to neither
year. So each vintage is clipped with the cartographic-boundary (`cb`) 500k file
of the same year.

Census does not publish one for every vintage. Measured against
`www2.census.gov`:

| vintage | cb 500k county file |
|---|---|
| 2010 | `GENZ2010/gz_2010_us_050_00_500k.zip` |
| 2013 | `GENZ2013/cb_2013_us_county_500k.zip` |
| 2014–2025 | `GENZ<year>/shp/cb_<year>_us_county_500k.zip` |
| **2000, 2009, 2011, 2012** | **none exists** |

Those four fall back to the nearest available vintage, and the substitution is
recorded per row in a `mask_year` column — so a reader can see which coastline
was used rather than having to reconstruct it.

Note that the mask only ever changes the coast. Measured on an interior county,
clipping to cb 5m and to cb 500k produced byte-identical geometry: inland
boundaries keep full TIGER detail either way.

## Not deduplicated

`census-counties.parquet` stores every county in every vintage, even though
**99.18% of vertices are unchanged between adjacent vintages** (measured 2012 →
2013, 834,662 of 841,535).

Collapsing runs of identical geometry into `from`/`to` eras was tried and does
not pay: over 2020 and 2021 it reduced 6,468 rows to 6,466. The clip mask moves
each year, and `st_intersection`/`st_make_valid` re-node and reorder rings even
where the shape is untouched, so byte comparison finds almost nothing.
Recovering the saving would mean freezing one mask across all vintages, or
canonicalising coordinates before hashing — both trade fidelity or complexity
for space that is not worth saving here.

## This repo publishes no tiles

The [LFP Explorer](https://github.com/sustainable-fsa/lfp-explorer) renders a
dummy-Albers coordinate space that exists only so MapLibre can draw an Albers
composite. That transform lives in exactly one place —
[`data-tiles`](https://github.com/sustainable-fsa/data-tiles),
`R/dummy-space.R` — because two implementations that drift misregister layers by
up to 765 m with nothing on screen to show it. Tiles are built there, from this
archive. This repository stays in real coordinate systems.

## Provenance

The per-vintage TIGER download and parquet conversion previously lived inside
`usdm-counties`, which was carrying ~1.23 GB of Census boundaries that are not
its subject. Moving it here gives the boundaries their own archive and lets
`usdm-counties` be about drought aggregation.

## Usage

```sh
Rscript census-counties.R                              # all vintages, publish
VINTAGES=2020,2021 PUBLISH=0 Rscript census-counties.R  # two vintages, local
```

## Citation

Bocinsky, R. Kyle. *Vintage-Matched US Census County Boundaries*. Montana
Climate Office, University of Montana. Sustainable FSA project.
<https://sustainable-fsa.com/census-counties/>

Source data are US Census Bureau TIGER/Line and Cartographic Boundary files,
which are in the public domain.

**Acknowledgment**: This work is part of the [*Enhancing Sustainable Disaster
Relief in FSA Programs*](https://www.ars.usda.gov/research/project/?accnNo=444612)
project, supported by the USDA Office of the Chief Economist, Office of Energy
and Environmental Policy, and the USDA Climate Hubs.
