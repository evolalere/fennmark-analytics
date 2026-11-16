-- Which products and categories carry the margin, and which sell volume at low margin?
-- One row per product line on an order. Revenue is what the line was sold for (line_revenue,
-- net of the line discount), never products.list_price: the same SKU sells at several prices.
-- Margin is stored as an amount; a margin rate is always sum(margin) / sum(revenue) at query time.

with

order_items as (

    select * from {{ ref('stg_backend__order_items') }}

),

orders as (

    select * from {{ ref('fct_orders') }}

),

products as (

    select * from {{ ref('stg_backend__products') }}

),

final as (

    select
        -- keys
        order_items.order_item_id,
        order_items.order_id,
        order_items.product_id,
        orders.customer_id,

        -- order context, repeated on each line so the fact can be filtered without a join
        orders.order_date,
        orders.order_week,
        orders.channel,
        orders.is_cancelled,
        orders.is_delivered,
        orders.has_currency_mismatch,
        orders.is_in_reporting_period,

        -- measures
        order_items.quantity,
        order_items.unit_price,
        order_items.gross_line_amount,
        order_items.line_revenue,
        products.cost_price                                    as unit_cost,
        products.cost_price * order_items.quantity             as cost_amount,
        order_items.line_revenue
            - products.cost_price * order_items.quantity       as margin_amount

    from order_items
    inner join orders
        on order_items.order_id = orders.order_id
    inner join products
        on order_items.product_id = products.product_id

)

select * from final
