-- How many products were launched in the window, and how long until first sale?
-- One row per SKU (GA4 item_id). The catalogue is every item GA4 ever showed, so most SKUs
-- were viewed but never bought: first_sold_date is NULL for them, and that is a finding.

with

products as (

    select * from {{ ref('stg_backend__products') }}

),

order_items as (

    select * from {{ ref('fct_order_items') }}
    where not is_cancelled

),

sales as (

    select
        product_id,
        min(order_date)                                        as first_sold_date,
        max(order_date)                                        as last_sold_date,
        count(distinct order_id)                               as order_count,
        sum(quantity)                                          as units_sold
    from order_items
    group by product_id

),

final as (

    select
        -- keys
        products.product_id,

        -- attributes
        products.product_name,
        products.variant,
        products.category,
        products.supplier,

        -- money
        products.list_price,                                   -- reference price, not the price charged
        products.cost_price,

        -- dates
        products.launch_date,
        sales.first_sold_date,
        sales.last_sold_date,
        date_diff(sales.first_sold_date, products.launch_date, day)
                                                               as days_to_first_sale,

        -- sales
        coalesce(sales.order_count, 0)                         as order_count,
        coalesce(sales.units_sold, 0)                          as units_sold,

        -- flags
        sales.product_id is not null                           as is_sold,
        products.launch_date between date '{{ var("reporting_start_date") }}'
            and date '{{ var("reporting_end_date") }}'         as is_launched_in_period

    from products
    left join sales
        on products.product_id = sales.product_id

)

select * from final
