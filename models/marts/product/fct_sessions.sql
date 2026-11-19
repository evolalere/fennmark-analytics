{{
    config(
        partition_by={'field': 'session_date', 'data_type': 'date', 'granularity': 'day'}
    )
}}

-- What is the view-to-purchase funnel by device category, and where is the biggest drop?
-- One row per GA4 session. The session logic lives in int_ga4__sessions; this model adds the
-- customer (cookie -> customer, where one exists) and the funnel reading.
-- first_touch_* is the USER's acquisition, repeated on every session; not session attribution.

with

sessions as (

    select * from {{ ref('int_ga4__sessions') }}

),

customers as (

    select * from {{ ref('int_backend__customer_identity_map') }}
    where is_canonical
        and user_pseudo_id is not null

),

final as (

    select
        -- keys
        sessions.session_key,
        sessions.user_pseudo_id,
        customers.customer_id,                                 -- null: cookie never became a customer

        -- when
        sessions.session_date,
        date_trunc(sessions.session_date, week(monday))        as session_week,
        sessions.session_start_at,
        sessions.session_end_at,
        sessions.session_duration_seconds,
        sessions.ga_session_number,

        -- attributes
        sessions.device_category,
        sessions.country,
        sessions.landing_page,
        sessions.first_touch_source,
        sessions.first_touch_medium,
        sessions.first_touch_campaign,

        -- measures
        sessions.event_count,
        sessions.page_view_count,
        sessions.engagement_time_msec,
        sessions.transaction_count,

        -- funnel steps, each on its own (open funnel)
        sessions.has_view_item,
        sessions.has_add_to_cart,
        sessions.has_begin_checkout,
        sessions.has_purchase,

        -- funnel depth: steps reached IN ORDER (closed funnel). 0 = never viewed an item
        case
            when not sessions.has_view_item then 0
            when not sessions.has_add_to_cart then 1
            when not sessions.has_begin_checkout then 2
            when not sessions.has_purchase then 3
            else 4
        end                                                    as funnel_depth,

        -- flags
        sessions.is_engaged,
        sessions.is_first_session,
        sessions.has_session_start_event,
        customers.customer_id is not null                      as is_known_customer,
        sessions.transaction_count > 0                         as has_identified_purchase,
        sessions.has_begin_checkout
            and not sessions.has_purchase                      as is_abandoned_checkout

    from sessions
    left join customers
        on sessions.user_pseudo_id = customers.user_pseudo_id

)

select * from final
