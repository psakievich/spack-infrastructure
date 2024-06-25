# Generated by Django 4.2.4 on 2024-05-21 17:05

from django.db import migrations

RAW_SQL = """
-- Create all time entries that exist in a day, with second precision
WITH times as (
    SELECT t::time as ts
    FROM generate_series(
            '2001-10-22 00:00:00'::timestamp,
            '2001-10-22 23:59:59'::timestamp,
            '1 second'
        ) t
)
INSERT INTO core_timedimension (
    time_key,
    time,
    am_or_pm,
    hour_12,
    hour_24,
    minute,
    minute_of_day,
    second,
    second_of_hour,
    second_of_day
)
SELECT
    to_char(ts, 'HH24MISS')::int,
    ts,
    to_char(ts, 'AM'),
    to_char(ts, 'HH12')::int,
    to_char(ts, 'HH24')::int,
    EXTRACT(minute from ts),
    (EXTRACT(hour from ts) * 60) + EXTRACT(minute from ts),
    EXTRACT(second from ts),
    (EXTRACT(minute from ts)*60) + EXTRACT(second from ts) ,
    (EXTRACT(hour from ts) * 3600) + (EXTRACT(minute from ts) * 60) + EXTRACT(second from ts)
FROM times
ON CONFLICT (time_key) DO NOTHING
;


-- Create all dates from existing jobs
WITH dates as (
    SELECT started_at::date as d
    from core_job
)
INSERT INTO core_datedimension (
    date_key,
    date,
    date_description,
    day_of_week,
    day_of_month,
    day_of_year,
    day_name,
    weekday,
    month,
    month_name,
    quarter,
    year
)
SELECT
    to_char(d, 'YYYYMMDD')::int,
    d,
    to_char(d, 'FMMonth DD, YYYY'),
    EXTRACT(dow from d) + 1, -- Add one so the range is [1, 7]
    EXTRACT(day from d),
    EXTRACT(doy from d),
    EXTRACT(isodow from d),
    EXTRACT(dow from d) NOT IN (5, 6), -- days 5 and 6 are saturday and sunday
    EXTRACT(month from d),
    to_char(d, 'FMMonth'),
    EXTRACT(quarter from d),
    EXTRACT(year from d)
FROM dates
ON CONFLICT (date_key) DO NOTHING
;


-- Create all nodes from existing jobs (including the "empty node")
INSERT INTO core_nodedimension (
    system_uuid,
    name,
    cpu,
    memory,
    capacity_type,
    instance_type
)
SELECT
    system_uuid,
    name,
    cpu,
    memory,
    capacity_type,
    instance_type
FROM
    core_node
UNION ALL
SELECT
    gen_random_uuid(),
    '',
    0,
    0,
    '',
    ''
;


-- Fix package names so that there's not duplicates
-- Some have a package name of '<name>@<version>'
UPDATE core_job
SET
    package_name    = split_part(core_job.package_name, '@', 1),
    package_version = split_part(core_job.package_name, '@', 2)
WHERE
    core_job.package_name LIKE '%@%'
;

-- Some have a package name of '(specs) <name>'
UPDATE core_job
SET
    package_name = split_part(core_job.package_name, '(specs) ', 2)
WHERE
    core_job.package_name LIKE '(specs) %'
;

-- Create all packages from existing jobs
INSERT INTO core_packagedimension (name)
SELECT DISTINCT(package_name)
FROM core_job
-- Also include empty row
UNION VALUES ('')
;


INSERT INTO core_packagespecdimension (
    name,
    hash,
    version,
    compiler_name,
    compiler_version,
    arch,
    variants
)
SELECT
    DISTINCT ON (core_timer.hash)

    package_name,
    core_timer.hash,
    package_version,
    compiler_name,
    compiler_version,
    arch,
    package_variants
FROM
    core_job
/*
    Join jobs with all timers that have data for that job's specific spec, which gives us full spec information.
    This relies on the job id, package name, and job name (which contains the first 7 characters of the hash).
    Usually just the job_id and package_name would suffice, but sometimes the same package under two different
    hashes is built for a job, so the final conditions resolves that.
*/
INNER JOIN core_timer ON
        core_timer.job_id   = core_job.job_id
    AND core_timer.name     = core_job.package_name
    AND core_job.name LIKE '%' || substring(core_timer.hash, 1, 7) || '%'
WHERE
        COALESCE(package_name, '')        != ''
    AND COALESCE(package_version, '')     != ''
    AND COALESCE(compiler_name, '')       != ''
    AND COALESCE(compiler_version, '')    != ''
    AND COALESCE(arch, '')                != ''
    AND COALESCE(package_variants, '')    != ''
ON CONFLICT DO NOTHING
;
-- Takes ~25 seconds, inserts ~26k rows


--- Create the unknown package spec row
INSERT INTO core_packagespecdimension (
    name,
    hash,
    version,
    compiler_name,
    compiler_version,
    arch,
    variants
)
VALUES (
    '',
    '',
    '',
    '',
    '',
    '',
    ''
);



-- Since we don't currently have this info, just create the empty runner
INSERT INTO core_runnerdimension (
    runner_id,
    name,
    platform,
    host,
    arch,
    tags,
    in_cluster
) VALUES (
    0,
    '',
    '',
    '',
    '',
    array[]::text[],
    FALSE
)
;


-- Create job dimensional data from existing jobs
INSERT INTO core_jobdatadimension (
    -- These fields exist on every job row
    job_id,
    job_url,
    name,
    ref,
    tags,
    job_size,
    stack,
    unnecessary,

    -- These fields may or may not exist, and so need to be handled specially
    commit_id,
    is_retry,
    is_manual_retry,
    attempt_number,
    final_attempt,
    status,
    error_taxonomy,
    pod_name,
    gitlab_runner_version,
    is_build
)
SELECT
    -- These fields exist on every job row
    core_job.job_id,
    FORMAT('https://gitlab.spack.io/spack/spack/-/jobs/%s', core_job.job_id),
    core_job.name,
    core_job.ref,
    tags,
    job_size,
    stack,
    unnecessary,

    -- These fields may or may not exist, and so need to be handled specially
    commit_id,
    COALESCE(is_retry, FALSE),
    COALESCE(is_manual_retry, FALSE),
    COALESCE(attempt_number, 1),
    COALESCE(final_attempt, FALSE),
    COALESCE(status, 'success'),
    error_taxonomy,
    core_jobpod.name,
    '',  -- We don't have this  info yet, so just store the empty string for now
    TRUE
FROM core_job
    LEFT JOIN core_jobattempt ON core_job.job_id = core_jobattempt.job_id
    LEFT JOIN core_jobpod ON core_job.pod_id = core_jobpod.id
;


/*
    Create all job facts from existing jobs. Since we've created all
    other dimensions prior to this, this step isn't too complicated.
*/
INSERT INTO core_jobfact (
    start_date_id,
    start_time_id,
    node_id,
    runner_id,
    package_id,
    spec_id,
    job_id,

    duration,
    duration_seconds,

    pod_node_occupancy,
    pod_cpu_usage_seconds,
    pod_max_mem,
    pod_avg_mem,
    node_price_per_second,
    node_cpu,
    node_memory,

    build_jobs,
    pod_cpu_request,
    pod_cpu_limit,
    pod_memory_request,
    pod_memory_limit,

    cost
)
SELECT
    to_char(started_at, 'YYYYMMDD')::int,
    to_char(started_at, 'HH24MISS')::int,
    COALESCE(
        core_node.system_uuid,
        (SELECT system_uuid FROM core_nodedimension WHERE name = '' LIMIT 1)
    ),
    -- Insert empty runner since we don't have this data yet
    (SELECT runner_id FROM core_runnerdimension WHERE name = '' LIMIT 1),
    pd.name,
    -- Default to the "empty spec" if join failed
    COALESCE(
        psd.id,
        (SELECT id FROM core_packagespecdimension WHERE hash = '')
    ),
    core_jobdatadimension.job_id,

    -- Numeric data
    duration,
    EXTRACT(EPOCH FROM core_job.duration),

    core_jobpod.node_occupancy,
    core_jobpod.cpu_usage_seconds,
    core_jobpod.max_mem,
    core_jobpod.avg_mem,
    core_node.instance_type_spot_price / 3600,
    core_node.cpu,
    core_node.memory,

    build_jobs::int,
    core_jobpod.cpu_request,
    core_jobpod.cpu_limit,
    core_jobpod.memory_request,
    core_jobpod.memory_limit,

    EXTRACT(EPOCH FROM core_job.duration) * core_jobpod.node_occupancy * (core_node.instance_type_spot_price / 3600)
FROM core_job
    LEFT JOIN core_node ON core_job.node_id = core_node.id
    LEFT JOIN core_jobpod ON core_job.pod_id = core_jobpod.id
    LEFT JOIN core_jobdatadimension ON core_job.job_id = core_jobdatadimension.job_id
    LEFT JOIN core_packagedimension pd ON core_job.package_name = pd.name

    -- The below joins might be NULL, which is why the coalesce above is present
    LEFT JOIN core_timer ON
            core_timer.job_id   = core_job.job_id
        AND core_timer.name     = core_job.package_name
        AND core_job.name LIKE '%' || substring(core_timer.hash, 1, 7) || '%'
    LEFT JOIN core_packagespecdimension psd ON
        psd.hash = core_timer.hash
;
"""
# Migration takes ~5 minutes


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0014_job_models"),
    ]

    operations = [migrations.RunSQL(RAW_SQL, reverse_sql="")]