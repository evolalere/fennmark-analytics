-- One row per identified GA4 purchase (transaction_id present), deduplicated to the
-- first purchase event; purchase_event_count keeps the duplicates visible.
-- GA4 money is indicative; the backend orders table is the source of truth.

with

source as (

    select *
    from {{ source('ga4', 'events') }}
    where _table_suffix between '{{ var("ga4_start_date") | replace("-", "") }}'
                            and '{{ var("ga4_end_date") | replace("-", "") }}'
        and event_name = 'purchase'

),

identified as (

    select
        *,
        coalesce(
            nullif(ecommerce.transaction_id, '(not set)'),
            nullif({{ ga4_event_param('transaction_id') }}, '(not set)')
        )                                                as transaction_id,
        {{ ga4_event_param('ga_session_id', 'int') }}    as ga_session_id,
        {{ ga4_event_param('currency') }}                as currency
    from source
    -- 906 of 5,692 purchase events have no usable id (883 '(not set)' + 23 NULL in raw;
    -- 448 of them are the empty placeholders, ga4_notes q11). They are not transactions,
    -- so they are not rows here; Week 7's reconciliation counts them from
    -- stg_ga4__events where event_name = 'purchase' and transaction_id is null.
    where coalesce(
        nullif(ecommerce.transaction_id, '(not set)'),
        nullif({{ ga4_event_param('transaction_id') }}, '(not set)')
    ) is not null

),

deduplicated as (

    select
        *,
        count(*) over (partition by transaction_id)        as purchase_event_count,
        row_number() over (
            partition by transaction_id order by event_timestamp
        )                                                  as event_rank
    from identified
    qualify event_rank = 1

),

renamed as (

    select
        -- keys
        transaction_id,
        user_pseudo_id,
        {{ dbt_utils.generate_surrogate_key(['user_pseudo_id', 'ga_session_id']) }} as session_key,

        -- when
        parse_date('%Y%m%d', event_date)                   as purchase_date,
        timestamp_micros(event_timestamp)                  as purchased_at,

        -- what GA4 reported (indicative; backend is the source of truth)
        cast(ecommerce.purchase_revenue as numeric)        as purchase_revenue,
        cast(ecommerce.purchase_revenue_in_usd as numeric) as purchase_revenue_in_usd,
        cast(ecommerce.shipping_value as numeric)          as shipping_amount,
        cast(ecommerce.tax_value as numeric)               as tax_amount,
        ecommerce.total_item_quantity                      as total_item_quantity,
        ecommerce.unique_items                             as unique_items,
        currency,

        -- context
        device.category                                    as device_category,
        geo.country                                        as country,

        -- the real duplicates, kept visible for Week 7
        purchase_event_count,
        purchase_event_count > 1                           as has_duplicate_events

    from deduplicated

)

select * from renamed