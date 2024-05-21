BEGIN;

-- Ensure all package hashes exist in this dimension
INSERT INTO core_packagehashdimension (
    hash
)
VALUES ('')  -- Include empty hash value
UNION ALL
SELECT
    DISTINCT (hash)
FROM
    core_timer
;
-- Takes ~32 seconds, Scans ~50M rows, Inserts ~1M rows


-- This table is odd because it has one boolean column, so a maximum of two rows
INSERT INTO core_timerdatadimension (
    cache
)
VALUES
    (TRUE),
    (FALSE)
;


-- Ensure all types of phases exist in this dimension
INSERT INTO core_timerphasedimension (
    path,
    is_subphase
)
SELECT
    DISTINCT ON (
        path,
        is_subphase
    )

    path,
    is_subphase
FROM core_timerphase
;
-- Takes ~3 minutes, Scans ~240M rows, Inserts 21 rows


-- Ensure that for all timer facts an entry in the package dimension
-- exists that consists of the package name with all other columns empty.
INSERT INTO core_packagedimension (
    name,
    version,
    compiler_name,
    compiler_version,
    arch,
    variants
)
SELECT
    DISTINCT (name),
    '',
    '',
    '',
    '',
    ''
FROM
    core_timer
ON CONFLICT DO NOTHING
;
-- Takes ~15 seconds, Scans ~50M rows, Inserts ~1500 rows


-- Create all timer facts from the existing timer table
INSERT INTO core_timerfact (
    job_id,
    timer_data_id,
    package_id,
    package_hash_id,
    total_time
)
SELECT
    job_id,
    tdd.id,
    pd.id,
    phd.id,
    time_total
FROM core_timer
LEFT JOIN core_timerdatadimension tdd ON
    core_timer.cache = tdd.cache
LEFT JOIN core_packagedimension pd ON
    pd.name                     = core_timer.name
    AND pd.version              = ''
    AND pd.compiler_name        = ''
    AND pd.compiler_version     = ''
    AND pd.arch                 = ''
    AND pd.variants             = ''
LEFT JOIN core_packagehashdimension phd ON
    core_timer.hash = phd.hash
;
-- Takes ~20 minutes, Scans ~50M rows, Inserts ~50M rows


-- This query seems scary but it's just creating the upper and lower
-- ID ranges that determine each batch
CREATE TEMP TABLE batches AS (
    SELECT
        lower,
        upper
    FROM (
        SELECT
            id as lower,
            LEAD(id, 1) OVER () as upper
        FROM (
            SELECT generate_series(
                0,
                (FLOOR((MAX(core_timerphase.id) + 5000000) / 5000000)*5000000)::bigint,
                5000000
            ) as id FROM core_timerphase
        ) it
    ) ot
    WHERE ot.upper IS NOT NULL
);

-- Use procedure and for loop to run inserts in batches, to prevent memory / disk issues
DO
$body$
DECLARE
    batch RECORD;
BEGIN
    FOR batch in SELECT * FROM batches ORDER BY LOWER
    LOOP
        INSERT INTO core_timerphasefact (
            job_id,
            timer_data_id,
            phase_id,
            package_id,
            package_hash_id,
            time,
            ratio_of_total
        )
        SELECT
            job_id,
            tdd.id,
            tpd.id,
            pd.id,
            phd.id,
            seconds,
            seconds / time_total
        FROM core_timerphase
        LEFT JOIN
            core_timer ON core_timerphase.timer_id = core_timer.id
        LEFT JOIN core_timerdatadimension tdd ON
            core_timer.cache = tdd.cache
        LEFT JOIN core_packagedimension pd ON
            pd.name                     = core_timer.name
            AND pd.version              = ''
            AND pd.compiler_name        = ''
            AND pd.compiler_version     = ''
            AND pd.arch                 = ''
            AND pd.variants             = ''
        LEFT JOIN core_packagehashdimension phd ON core_timer.hash = phd.hash
        LEFT JOIN core_timerphasedimension tpd ON core_timerphase.path = tpd.path
        WHERE core_timerphase.id > batch.lower AND core_timerphase.id <= batch.upper
        ;
    END LOOP;
END;
$body$
LANGUAGE 'plpgsql'
;
-- Took 2 hours, scanned ~240M rows + joins, inserted ~240M rows


-- Final commit
COMMIT;
