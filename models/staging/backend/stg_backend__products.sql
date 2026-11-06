with source as (

    select * from {{ source('backend', 'products') }}

),

-- reference data, the one ref() allowed in staging: a human-maintained seed, not another model
overrides as (

    select * from {{ ref('product_category_overrides') }}

),

renamed as (

    select
        -- keys
        s.product_id,

        -- attributes
        s.product_name,
        nullif(s.variant, 'Single Option Only')               as variant,        -- sentinel for non-sized merch
        s.category                                            as raw_category,   -- as ga4 reported it: breadcrumbs and nav labels
        coalesce(by_sku.category, by_value.category, 'Other') as category,       -- ledger: canonical category; per-sku row wins
        s.supplier,

        -- money (float64 in raw -> numeric)
        cast(s.list_price as numeric)                         as list_price,
        cast(s.cost_price as numeric)                         as cost_price,

        -- dates
        s.launch_date,
        s.loaded_at

    from source as s
    left join overrides as by_sku
        on by_sku.product_id = s.product_id
    left join overrides as by_value
        on by_value.product_id is null
       and by_value.raw_category = s.category

)

select * from renamed