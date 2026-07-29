-- ============================================================
-- NYC Fire Hydrant Coverage Analysis (PostGIS)
--
-- Tables expected (loaded via ogr2ogr from data/raw/*.geojson):
--   hydrants(boro, latitude, longitude, geom)               -- geom: Point, EPSG:4326
--   neighborhoods(boroname, borocode, ntaname, nta2020,
--                 countyfips, geom)                          -- geom: MultiPolygon, EPSG:4326
-- ============================================================


-- ============================================================
-- SETUP — spatial indexes (run once, right after loading the data)
-- ============================================================

##If present deleting the indexes 
DROP INDEX IF EXISTS hydrants_geom_idx;
DROP INDEX IF EXISTS neighborhoods_geom_idx;


CREATE INDEX IF NOT EXISTS hydrants_geom_idx ON hydrants USING GIST (geom);
CREATE INDEX IF NOT EXISTS neighborhoods_geom_idx ON neighborhoods USING GIST (geom);




-- ============================================================
-- 1. FILTER — Manhattan neighborhoods, plus a sanity check that
--    both tables actually loaded with the geometry/SRID we expect
-- ============================================================
SELECT
    'hydrants' AS table_name,
    COUNT(*) AS row_count,
    ST_SRID(geom) AS srid,
    GeometryType(geom) AS geom_type
FROM hydrants
GROUP BY ST_SRID(geom), GeometryType(geom)

UNION ALL

SELECT
    'neighborhoods',
    COUNT(*),
    ST_SRID(geom),
    GeometryType(geom)
FROM neighborhoods
GROUP BY ST_SRID(geom), GeometryType(geom);

-- All Manhattan neighborhoods
SELECT
    ntaname,
    nta2020,
    countyfips,
    geom
FROM neighborhoods
WHERE boroname = 'Manhattan'
ORDER BY ntaname;


-- ============================================================
-- 2. SPATIAL JOIN — match each hydrant to the neighborhood that
--    contains it, using ST_Contains(polygon, point)
-- ============================================================
-- Both tables are already in EPSG:4326, so no ST_Transform is needed
-- for a plain point-in-polygon test.
SELECT
    h.boro,
    h.latitude,
    h.longitude,
    n.ntaname,
    n.boroname
FROM hydrants h
JOIN neighborhoods n
    ON ST_Contains(n.geom, h.geom);

-- Hydrants that don't fall inside any neighborhood polygon (e.g. piers,
-- causeways, or other unmapped land) — mirrors the `unmatched` check in
-- analysis.ipynb, so nothing silently disappears from the join.
SELECT
    h.boro,
    h.latitude,
    h.longitude
FROM hydrants h
WHERE NOT EXISTS (
    SELECT 1 FROM neighborhoods n WHERE ST_Contains(n.geom, h.geom)
);


-- ============================================================
-- 3. AGGREGATE — hydrant count per neighborhood
-- ============================================================
-- LEFT JOIN (not JOIN) so neighborhoods with zero matched hydrants are
-- kept in the result as a count of 0, instead of dropping out entirely.



-- ============================================================
-- 4. NORMALIZE — hydrant density per km² (HEADLINE RESULT)
-- ============================================================
-- Area must be computed in a projected, distance-accurate CRS rather than
-- EPSG:4326 (degrees). EPSG:2263 (NY State Plane, feet) is standard for
-- NYC; ST_Area returns square feet, so divide by ft²-per-km² to convert.
-- NULLIF guards against divide-by-zero for any (near) zero-area polygon.


-- ============================================================
-- 5. BUFFER + UNION + INTERSECTION — % of each neighborhood within
--    100m of a hydrant (coverage analysis; the deeper finding)
-- ============================================================
-- Buffering in real meters requires a metric CRS — EPSG:2263 above is in
-- feet, so switch to EPSG:32618 (UTM zone 18N, meters), which covers all
-- of NYC with acceptable distortion for a 100m buffer.
--
-- Only hydrant buffers that actually intersect a given neighborhood are
-- unioned against it (via the ST_Intersects join condition), rather than
-- unioning all ~110k buffers up front — that keeps ST_Union's input per
-- neighborhood small and lets the GIST index do the filtering.

