-- One row per item line (array position) on an identified, deduplicated GA4 purchase.
-- gross_line_amount = price x quantity; net_line_amount = GA4 item_revenue, which has
-- discounts and rounding applied and is not always price x quantity (domain_spec s.7).
-- The first three CTEs repeat stg_ga4__purchases on purpose: one source per model, no
-- ref() between staging models (dbt_notes.md). Week 9 may factor them into a macro.

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
        )                                                as transaction_id
    from source
    where coalesce(
        nullif(ecommerce.transaction_id, '(not set)'),
        nullif({{ ga4_event_param('transaction_id') }}, '(not set)')
    ) is not null

),

deduplicated as (

    select
        *,
        row_number() over (
            partition by transaction_id order by event_timestamp
        )                                                  as event_rank
    from identified
    qualify event_rank = 1

),

unnested as (

    select
        deduplicated.transaction_id,
        deduplicated.user_pseudo_id,
        deduplicated.event_timestamp,
        line_offset + 1                                    as line_number,
        item.item_id,
        item.item_name,
        item.item_variant,
        item.item_category,
        item.price,
        item.quantity,
        item.item_revenue
    from deduplicated
    cross join unnest(deduplicated.items) as item with offset as line_offset
    -- Placeholder line shape (ga4_notes q11): item_id '(not set)' with NULL price. Already
    -- excluded by the transaction_id filter above; stated here too, where lines are made.
    where item.item_id != '(not set)'
        and item.price is not null

),

renamed as (

    select
        -- keys
        {{ dbt_utils.generate_surrogate_key(['transaction_id', 'line_number']) }} as purchase_item_key,
        transaction_id,
        line_number,
        item_id,
        user_pseudo_id,

        -- product as GA4 saw it (the canonical catalogue is the backend's, Week 8 dim_products)
        item_name,
        nullif(item_variant, 'Single Option Only')         as item_variant,
        item_category                                      as raw_item_category,

        -- line money
        cast(price as numeric)                             as unit_price,
        quantity,
        cast(price * quantity as numeric)                  as gross_line_amount,
        cast(item_revenue as numeric)                      as net_line_amount,

        timestamp_micros(event_timestamp)                  as purchased_at

    from unnested

)

select * from renamed