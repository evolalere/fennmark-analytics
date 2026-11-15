{{ config(materialized='table') }}

-- One row per purchase that either system knows about:
--   an order id seen by ga4, by the backend, or by both; plus one row per ga4 purchase
--   event that carries no transaction id at all (906 events; they can never be matched).
-- The backend is the system of record; ga4 figures are compared, never trusted.
-- Headline revenue comparison: ga4 header purchase_revenue vs backend gross_revenue
-- (docs/decisions.md, week 7). Line values come from order_items, never products.list_price.
-- A table: both ga4 purchase models are views over the public sample (~1.6 gb per read).

with

ga4_purchases as (

    select * from {{ ref('stg_ga4__purchases') }}

),

ga4_lines as (

    select
        transaction_id,
        sum(gross_line_amount)                                 as ga4_gross_lines_amount,
        sum(net_line_amount)                                   as ga4_net_lines_amount
    from {{ ref('stg_ga4__purchase_items') }}
    group by transaction_id

),

ga4_unidentified as (

    select
        event_key,
        user_pseudo_id,
        session_key,
        event_at,
        purchase_revenue
    from {{ ref('stg_ga4__events') }}
    where event_name = 'purchase'
        and transaction_id is null

),

orders as (

    select * from {{ ref('stg_backend__orders') }}

),

backend_lines as (

    select
        order_id,
        sum(line_revenue)                                      as backend_net_lines_amount
    from {{ ref('stg_backend__order_items') }}
    group by order_id

),

customers as (

    select * from {{ ref('int_backend__customer_identity_map') }}

),

identified as (

    select
        -- keys
        coalesce(orders.order_id, ga4_purchases.transaction_id) as reconciliation_key,
        ga4_purchases.transaction_id,
        orders.order_id,
        customers.customer_id,

        -- ga4 side
        ga4_purchases.user_pseudo_id                           as ga4_user_pseudo_id,
        ga4_purchases.session_key,
        ga4_purchases.purchased_at,
        ga4_purchases.purchase_event_count,
        ga4_purchases.purchase_revenue                         as ga4_purchase_revenue,
        ga4_lines.ga4_gross_lines_amount,
        ga4_lines.ga4_net_lines_amount,

        -- backend side
        customers.user_pseudo_id                               as customer_user_pseudo_id,
        orders.placed_at,
        orders.channel,
        orders.currency,
        orders.gross_revenue,
        orders.discount_amount,
        orders.net_revenue,
        backend_lines.backend_net_lines_amount,
        orders.is_backend_only,
        orders.has_currency_mismatch

    from ga4_purchases
    full outer join orders
        on ga4_purchases.transaction_id = orders.order_id
    left join ga4_lines
        on ga4_purchases.transaction_id = ga4_lines.transaction_id
    left join backend_lines
        on orders.order_id = backend_lines.order_id
    left join customers
        on orders.customer_id = customers.source_customer_id

),

-- same columns, same order as identified: union all matches by position
unidentified as (

    select
        -- keys
        concat('ga4-event-', event_key)                        as reconciliation_key,
        cast(null as string)                                   as transaction_id,
        cast(null as string)                                   as order_id,
        cast(null as string)                                   as customer_id,

        -- ga4 side
        user_pseudo_id                                         as ga4_user_pseudo_id,
        session_key,
        event_at                                               as purchased_at,
        1                                                      as purchase_event_count,
        purchase_revenue                                       as ga4_purchase_revenue,
        cast(null as numeric)                                  as ga4_gross_lines_amount,
        cast(null as numeric)                                  as ga4_net_lines_amount,

        -- backend side
        cast(null as string)                                   as customer_user_pseudo_id,
        cast(null as timestamp)                                as placed_at,
        cast(null as string)                                   as channel,
        cast(null as string)                                   as currency,
        cast(null as numeric)                                  as gross_revenue,
        cast(null as numeric)                                  as discount_amount,
        cast(null as numeric)                                  as net_revenue,
        cast(null as numeric)                                  as backend_net_lines_amount,
        cast(null as bool)                                     as is_backend_only,
        cast(null as bool)                                     as has_currency_mismatch

    from ga4_unidentified

),

unioned as (

    select * from identified
    union all
    select * from unidentified

),

categorised as (

    select
        *,
        purchased_at is not null                               as is_in_ga4,
        order_id is not null                                   as is_in_backend,

        -- the plan's three buckets
        case
            when purchased_at is not null and order_id is not null then 'matched'
            when order_id is not null                              then 'backend_only'
            else 'ga4_only'
        end                                                    as reconciliation_category,

        -- ga4_only split by what the data shows, not by what the generator knows
        case
            when purchased_at is not null and order_id is not null then 'matched'
            when order_id is not null                              then 'backend_only'
            when transaction_id is not null                        then 'ga4_only_no_backend_order'
            when ga4_purchase_revenue is null                      then 'ga4_only_placeholder'
            else 'ga4_only_unidentified'
        end                                                    as reconciliation_detail

    from unioned

),

final as (

    select
        *,

        -- revenue on matched orders: ga4 header vs backend gross, then vs backend net
        ga4_purchase_revenue - gross_revenue                   as gross_revenue_delta,
        ga4_purchase_revenue - net_revenue                     as net_revenue_delta,
        ga4_net_lines_amount - backend_net_lines_amount        as net_lines_delta,

        -- one primary reason per matched order, first match wins
        case
            when reconciliation_category != 'matched'          then null
            when has_currency_mismatch                         then 'currency_mismatch'
            when round(ga4_purchase_revenue, 2) is distinct from round(gross_revenue, 2)
                                                               then 'ga4_header_differs'
            when discount_amount > 0                           then 'backend_discount'
            else 'exact'
        end                                                    as revenue_delta_reason,

        -- independent flags: an order can carry several
        discount_amount > 0                                    as has_backend_discount,
        round(ga4_purchase_revenue, 2) is distinct from round(ga4_net_lines_amount, 2)
            and transaction_id is not null                     as has_ga4_header_vs_lines_gap,
        ga4_gross_lines_amount != ga4_net_lines_amount         as has_ga4_line_discount,
        ga4_user_pseudo_id = customer_user_pseudo_id           as is_same_cookie

    from categorised

)

select * from final