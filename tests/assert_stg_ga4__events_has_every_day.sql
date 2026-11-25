-- An incremental model fails quietly by skipping a day. This test returns a row, and so
-- fails, when the number of event dates in the table is not the number of days in the window.

with

days as (

    select
        count(distinct event_date)                             as days_present,
        date_diff(
            date '{{ var("ga4_end_date") }}',
            date '{{ var("ga4_start_date") }}',
            day
        ) + 1                                                  as days_expected
    from {{ ref('stg_ga4__events') }}

)

select *
from days
where days_present != days_expected
