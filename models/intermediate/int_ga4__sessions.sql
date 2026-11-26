{{
    config(
        materialized='incremental',
        incremental_strategy='insert_overwrite',
        partition_by={'field': 'session_date', 'data_type': 'date'},
        on_schema_change='fail'
    )
}}

-- A session is defined by its events, not by its session_start event: 5,272 sessions
-- have none (docs/dbt_notes.md week 7, i2).
-- Incremental since week 9: a run rebuilds the session_date partitions from window_start
-- on. window_start is the newest loaded session date minus the lookback and the session
-- buffer; events are read from one buffer earlier still, so that a session which started
-- before window_start and ran past midnight is seen whole and can be left out
-- (docs/dbt_notes.md, week 9).

{%- if is_incremental() -%}
    {%- set window_start = lookback_start_date(
            'session_date', var('ga4_lookback_days') + var('ga4_session_buffer_days')) -%}
{%- endif %}

with

events as (

    select *
    from {{ ref('stg_ga4__events') }}
    -- guard only: no event in the sample lacks a session id (i1), but a null would
    -- still hash to a session_key and glue a user's orphan events into one fake session
    where ga_session_id is not null
    {% if is_incremental() %}
      and event_date >= date_sub(date '{{ window_start }}',
                                 interval {{ var('ga4_session_buffer_days') }} day)
    {% endif %}

),

aggregated as (

    select
        -- keys
        session_key,
        any_value(user_pseudo_id)                              as user_pseudo_id,
        any_value(ga_session_id)                               as ga_session_id,
        min(ga_session_number)                                 as ga_session_number,

        -- when (845 sessions cross midnight; a session keeps the date of its first event)
        min(event_date)                                        as session_date,
        min(event_at)                                          as session_start_at,
        max(event_at)                                          as session_end_at,

        -- size and engagement
        count(*)                                               as event_count,
        countif(event_name = 'page_view')                      as page_view_count,
        coalesce(sum(engagement_time_msec), 0)                 as engagement_time_msec,
        coalesce(logical_or(is_session_engaged), false)        as is_engaged,
        countif(event_name = 'session_start') > 0              as has_session_start_event,

        -- attributes of the first event (session-level in ga4)
        array_agg(page_location ignore nulls order by event_at limit 1)[safe_offset(0)]
                                                               as landing_page,
        array_agg(device_category ignore nulls order by event_at limit 1)[safe_offset(0)]
                                                               as device_category,
        array_agg(country ignore nulls order by event_at limit 1)[safe_offset(0)]
                                                               as country,

        -- funnel steps reached (fct_sessions, week 8)
        countif(event_name = 'view_item') > 0                  as has_view_item,
        countif(event_name = 'add_to_cart') > 0                as has_add_to_cart,
        countif(event_name = 'begin_checkout') > 0             as has_begin_checkout,
        countif(event_name = 'purchase') > 0                   as has_purchase,
        count(distinct transaction_id)                         as transaction_count,

        -- acquisition: the user's first touch, repeated on every session; not session attribution
        any_value(first_touch_source)                          as first_touch_source,
        any_value(first_touch_medium)                          as first_touch_medium,
        any_value(first_touch_campaign)                        as first_touch_campaign

    from events
    group by session_key

),

final as (

    select
        *,
        timestamp_diff(session_end_at, session_start_at, second) as session_duration_seconds,
        ga_session_number = 1                                    as is_first_session
    from aggregated
    {% if is_incremental() %}
    -- sessions that started before window_start were read only so they could be recognised
    where session_date >= date '{{ window_start }}'
    {% endif %}

)

select * from final
