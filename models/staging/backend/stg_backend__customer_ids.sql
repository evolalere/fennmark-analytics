-- Every customer id raw has ever issued, duplicates included (4,724 rows).
-- stg_backend__customers keeps one row per customer; this model keeps the ids it dropped,
-- so that an order pointing at a duplicate id can still be resolved (stitching).

with source as (

    select * from {{ source('backend', 'customers') }}

),

renamed as (

    select
        -- keys
        customer_id,
        user_pseudo_id,                               -- ga4 cookie; null for backend-only customers

        -- timestamps
        created_at

    from source

)

select * from renamed