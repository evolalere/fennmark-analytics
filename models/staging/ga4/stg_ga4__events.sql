{{
    config(
        materialized='table',
        partition_by={'field': 'event_date', 'data_type': 'date'},
        cluster_by=['event_name', 'user_pseudo_id']
    )
}}

-- One row per GA4 event in the project window; nothing dropped.
-- The one staging model that is not a view: a view over 92 wildcard shards would
-- re-scan the sample on every downstream query and test (docs/dbt_notes.md).

with

source as (

    select *
    from {{ source('ga4', 'events') }}
    where _table_suffix between '{{ var("ga4_start_date") | replace("-", "") }}'
                            and '{{ var("ga4_end_date") | replace("-", "") }}'

),

extracted as (

    select
        *,
        {{ ga4_event_param('ga_session_id', 'int') }}        as ga_session_id,
        {{ ga4_event_param('ga_session_number', 'int') }}    as ga_session_number,
        {{ ga4_event_param('page_location') }}               as page_location,
        {{ ga4_event_param('page_referrer') }}               as page_referrer,
        {{ ga4_event_param('page_title') }}                  as page_title,
        {{ ga4_event_param('engagement_time_msec', 'int') }} as engagement_time_msec,
        {{ ga4_event_param('session_engaged') }}             as session_engaged_raw,
        {{ ga4_event_param('transaction_id') }}              as param_transaction_id,
        {{ ga4_event_param('currency') }}                    as currency,
        {{ ga4_event_param('campaign') }}                    as event_campaign
    from source

),

renamed as (

    select
        -- keys
        {{ dbt_utils.generate_surrogate_key([
            'user_pseudo_id', 'event_timestamp', 'event_name', 'event_bundle_sequence_id',
            'ga_session_id', 'engagement_time_msec', 'page_location'
        ]) }}                                                      as event_key,
        {{ dbt_utils.generate_surrogate_key(['user_pseudo_id', 'ga_session_id']) }}
                                                                   as session_key,
        user_pseudo_id,
        ga_session_id,
        ga_session_number,

        -- event
        event_name,
        parse_date('%Y%m%d', event_date)                           as event_date,
        timestamp_micros(event_timestamp)                          as event_at,
        timestamp_micros(user_first_touch_timestamp)               as user_first_touch_at,
        event_bundle_sequence_id,
        platform,
        stream_id,

        -- page and engagement
        page_location,
        page_referrer,
        page_title,
        engagement_time_msec,
        session_engaged_raw = '1'                                  as is_session_engaged,

        -- ecommerce header (purchase events only; NULL elsewhere)
        coalesce(
            nullif(ecommerce.transaction_id, '(not set)'),
            nullif(param_transaction_id, '(not set)')
        )                                                          as transaction_id,
        cast(ecommerce.purchase_revenue as numeric)                as purchase_revenue,
        currency,
        event_campaign,

        -- device and geo: session-level attributes
        device.category                                            as device_category,
        device.operating_system                                    as device_os,
        device.web_info.browser                                    as browser,
        geo.country                                                as country,

        -- first-touch acquisition: user-level, not session-level (docs/ga4_notes.md)
        traffic_source.source                                      as first_touch_source,
        traffic_source.medium                                      as first_touch_medium,
        traffic_source.name                                        as first_touch_campaign

    from extracted

)

select * from renamed