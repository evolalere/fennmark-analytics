-- One row per customer id raw ever issued, mapped to the customer it belongs to.
--   source_customer_id -> customer_id : resolves the 73 duplicate ids (7 orders, 5 surveys)
--   user_pseudo_id     -> customer_id : resolves a ga4 cookie (where is_canonical)
-- The partition and ordering must stay identical to the dedup in stg_backend__customers;
-- the relationships test on customer_id fails if they drift apart.
-- A cookie is a browser, not a person: user_id is never populated in the ga4 sample.

with

customer_ids as (

    select * from {{ ref('stg_backend__customer_ids') }}

),

mapped as (

    select
        customer_id                                            as source_customer_id,
        first_value(customer_id) over (
            partition by coalesce(user_pseudo_id, customer_id)
            order by created_at, customer_id
        )                                                      as customer_id,
        user_pseudo_id
    from customer_ids

),

final as (

    select
        -- keys
        source_customer_id,
        customer_id,
        user_pseudo_id,

        -- flags
        source_customer_id = customer_id                       as is_canonical

    from mapped

)

select * from final

