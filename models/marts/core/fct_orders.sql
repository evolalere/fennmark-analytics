-- What were net revenue and order count per week by channel, and what share of orders did GA4 miss?
-- One row per backend order (the system of record). No logic of its own: customer, status and
-- reconciliation category are read from intermediate; this model only pivots, joins and flags.
-- Every CTE is brought to one row per order BEFORE the join, so nothing can fan out.

with

orders as (

    select * from {{ ref('stg_backend__orders') }}

),

customers as (

    select * from {{ ref('int_backend__customer_identity_map') }}

),

status_history as (

    select * from {{ ref('int_backend__order_status_history') }}

),

reconciliation as (

    select * from {{ ref('int_reconciliation__ga4_vs_backend') }}
    where is_in_backend

),

order_items as (

    select * from {{ ref('stg_backend__order_items') }}

),

refunds as (

    select * from {{ ref('stg_backend__refunds') }}

),

-- status history pivoted: one row per order, one column per milestone
milestones as (

    select
        order_id,
        max(if(is_current, status, null))                      as current_status,
        max(if(status = 'paid', valid_from, null))             as paid_at,
        max(if(status = 'shipped', valid_from, null))          as shipped_at,
        max(if(status = 'delivered', valid_from, null))        as delivered_at,
        max(if(status = 'cancelled', valid_from, null))        as cancelled_at,
        max(if(status = 'returned', valid_from, null))         as returned_at,
        max(if(status = 'refunded', valid_from, null))         as refunded_at,
        max(if(status = 'cancelled', reason, null))            as cancellation_reason
    from status_history
    group by order_id

),

lines as (

    select
        order_id,
        count(*)                                               as line_count,
        sum(quantity)                                          as unit_count
    from order_items
    group by order_id

),

refunded as (

    select
        order_id,
        count(*)                                               as refund_count,
        sum(refund_amount)                                     as refunded_amount
    from refunds
    group by order_id

),

joined as (

    select
        -- keys
        orders.order_id,
        customers.customer_id,                                 -- canonical: duplicate ids resolved

        -- when
        orders.placed_at,
        date(orders.placed_at)                                 as order_date,
        date_trunc(date(orders.placed_at), week(monday))       as order_week,

        -- attributes
        orders.channel,
        orders.payment_method,
        orders.shipping_country,
        orders.currency,

        -- money, in the order's own currency (see has_currency_mismatch)
        orders.gross_revenue,
        orders.discount_amount,
        orders.net_revenue,
        coalesce(refunded.refunded_amount, 0)                  as refunded_amount,
        coalesce(lines.line_count, 0)                          as line_count,
        coalesce(lines.unit_count, 0)                          as unit_count,

        -- lifecycle
        milestones.current_status,
        milestones.paid_at,
        milestones.shipped_at,
        milestones.delivered_at,
        milestones.cancelled_at,
        milestones.returned_at,
        milestones.refunded_at,
        milestones.cancellation_reason,
        timestamp_diff(milestones.delivered_at, orders.placed_at, day) as days_to_deliver,
        timestamp_diff(milestones.delivered_at, milestones.shipped_at, day) as days_in_transit,

        -- reconciliation with ga4
        reconciliation.reconciliation_category,
        reconciliation.ga4_purchase_revenue,
        reconciliation.revenue_delta_reason,

        -- flags
        milestones.cancelled_at is not null                    as is_cancelled,
        milestones.delivered_at is not null                    as is_delivered,
        milestones.returned_at is not null                     as is_returned,
        orders.discount_amount > 0                             as has_discount,
        orders.is_backend_only,
        orders.has_currency_mismatch,
        date(orders.placed_at) between date '{{ var("reporting_start_date") }}'
            and date '{{ var("reporting_end_date") }}'         as is_in_reporting_period

    from orders
    left join customers
        on orders.customer_id = customers.source_customer_id
    left join milestones
        on orders.order_id = milestones.order_id
    left join lines
        on orders.order_id = lines.order_id
    left join refunded
        on orders.order_id = refunded.order_id
    left join reconciliation
        on orders.order_id = reconciliation.order_id

),

final as (

    select
        *,
        row_number() over (
            partition by customer_id
            order by placed_at, order_id
        )                                                      as customer_order_number
    from joined

)

select * from final
