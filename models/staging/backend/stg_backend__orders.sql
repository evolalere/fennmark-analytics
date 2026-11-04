with source as (

    select * from {{ source('backend', 'orders') }}

),

renamed as (

    select
        -- keys
        order_id,
        customer_id,

        -- timestamps
        placed_at,
        loaded_at,

        -- attributes
        channel,
        payment_method,
        currency,
        coalesce(shipping_country, ship_country)         as shipping_country,  -- column renamed 2021-01-01

        -- money (float64 in raw -> numeric)
        cast(gross_revenue as numeric)                   as gross_revenue,
        cast(discount_amount as numeric)                 as discount_amount,
        cast(gross_revenue - discount_amount as numeric) as net_revenue,

        -- flags for downstream models and tests
        starts_with(order_id, 'B-')                      as is_backend_only,
        currency != 'USD'                                as has_currency_mismatch

    from source

)

select * from renamed