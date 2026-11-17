-- What is the return rate by product category and channel, and what are the top reasons?
-- One row per RETURNED ORDER LINE, not per return request. A whole-order return has no line of
-- its own (order_item_id is NULL in raw), so it is expanded to every line of its order: a rate
-- by category needs numerator and denominator at the same grain, and the denominator is lines.
-- return_line_number = 1 gives back one row per request (373).

with

returns as (

    select * from {{ ref('stg_backend__returns') }}

),

order_items as (

    select * from {{ ref('fct_order_items') }}

),

orders as (

    select * from {{ ref('fct_orders') }}

),

return_lines as (

    select
        returns.return_id,
        returns.order_id,
        order_items.order_item_id,
        order_items.product_id,
        returns.reason,
        returns.accepted                                       as is_accepted,
        returns.is_whole_order_return,
        returns.requested_at,
        order_items.quantity,
        order_items.line_revenue
    from returns
    inner join order_items
        on returns.order_id = order_items.order_id
        and (
            returns.order_item_id is null
            or returns.order_item_id = order_items.order_item_id
        )

),

final as (

    select
        -- keys
        {{ dbt_utils.generate_surrogate_key([
            'return_lines.return_id', 'return_lines.order_item_id'
        ]) }}
                                                               as return_line_id,
        return_lines.return_id,
        row_number() over (
            partition by return_lines.return_id
            order by return_lines.order_item_id
        )                                                      as return_line_number,
        return_lines.order_id,
        return_lines.order_item_id,
        return_lines.product_id,
        orders.customer_id,

        -- when
        return_lines.requested_at,
        date(return_lines.requested_at)                        as return_date,
        orders.delivered_at,
        timestamp_diff(return_lines.requested_at, orders.delivered_at, day) as days_from_delivery,

        -- attributes
        return_lines.reason,
        orders.channel,

        -- measures
        return_lines.quantity                                  as returned_quantity,
        return_lines.line_revenue                              as returned_amount,

        -- flags
        return_lines.is_accepted,
        return_lines.is_whole_order_return,
        orders.is_in_reporting_period

    from return_lines
    inner join orders
        on return_lines.order_id = orders.order_id

)

select * from final
