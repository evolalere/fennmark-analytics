with source as (

    select * from {{ source('backend', 'order_items') }}

),

renamed as (

    select
        -- keys
        order_item_id,
        order_id,
        product_id,

        -- quantities
        quantity,

        -- money (float64 in raw -> numeric)
        cast(unit_price as numeric)              as unit_price,         -- price on this purchase, not list_price
        cast(line_revenue as numeric)            as line_revenue,       -- ga4 item_revenue: net of line discount
        cast(unit_price * quantity as numeric)   as gross_line_amount,  -- gross; the gap to line_revenue is a known reconciliation reason

        -- timestamps
        loaded_at

    from source

)

select * from renamed