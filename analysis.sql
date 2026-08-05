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

SELECT
    h.boro,
    h.latitude,
    h.longitude,
    n.ntaname,
    n.boroname
FROM hydrants h
JOIN neighborhoods n
    ON ST_Contains(n.geom, h.geom);

-- Hydrants that don't fall inside any neighborhood polygon 
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

SELECT 
    n.ntaname,
    n.boroname,
    COUNT(h.geom) AS hydrant_count       -- COUNT(h.geom), not COUNT(*), so unmatched → 0 not 1
FROM neighborhoods n
LEFT JOIN hydrants h
    ON ST_Contains(n.geom, h.geom)
GROUP BY n.ntaname, n.boroname
ORDER BY hydrant_count DESC;


-- ============================================================
-- 4. NORMALIZE — hydrant density per km² (HEADLINE RESULT)
-- ============================================================

with counts AS (
	SELECT 
	    n.ntaname,
	    n.boroname,
		n.geom,
		ST_Area(ST_Transform(n.geom, 2263))/10763910.42 AS area_km2,
	    COUNT(h.geom) AS hydrant_count       -- COUNT(h.geom), not COUNT(*), so unmatched → 0 not 1
	FROM neighborhoods n
	LEFT JOIN hydrants h
	    ON ST_Contains(n.geom, h.geom)
	GROUP BY n.ntaname, n.boroname ,n.geom
)
SELECT 
	ntaname,
	boroname,
	geom,
	hydrant_count,
    ROUND(area_km2::numeric, 3) AS area_km2,
    ROUND((hydrant_count / NULLIF(area_km2, 0))::numeric, 2) AS density_per_km2
FROM counts
ORDER BY density_per_km2 DESC NULLS LAST;

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
SELECT * FROM hydrants LIMIT 10;
SELECT ST_SRID(geom) FROM hydrants LIMIT 1;
SELECT ST_SRID(geom) FROM neighborhoods LIMIT 1;

---------------------
WITH 
buffers AS (
    SELECT ST_Buffer(ST_Transform(h.geom, 2263), 328.084) AS buffer_geom
    FROM hydrants h
),
coverage AS (
    SELECT ST_Union(buffer_geom) AS coverage_geom
    FROM buffers
)
SELECT 
    n.ntaname,
    n.boroname,
    ROUND(
        (ST_Area(ST_Intersection(ST_Transform(n.geom, 2263), c.coverage_geom))
         / NULLIF(ST_Area(ST_Transform(n.geom, 2263)), 0) * 100)::numeric,
        2
    ) AS coverage_pct
FROM neighborhoods n, coverage c
ORDER BY coverage_pct DESC;