with source as (

    select * from {{ source('backend', 'customers') }}

),

renamed as (

    select
        -- keys
        customer_id,
        user_pseudo_id,                       -- GA4 cookie; null for backend-only customers

        -- attributes
        full_name,
        email,
        country,
        case email_consent                    -- string in raw; ~15% null stays null
            when 'true'  then true
            when 'false' then false
        end                                   as has_email_consent,

        -- timestamps
        acquisition_date,
        created_at,
        loaded_at

    from source

),

-- ledger: ~2% of customers appear twice (same cookie and email, later created_at).
-- keep the earliest row per cookie. backend-only customers (null cookie) are all kept:
-- partitioning on the cookie alone would collapse every null into one row.
deduplicated as (

    select *
    from renamed
    qualify row_number() over (
        partition by coalesce(user_pseudo_id, customer_id)
        order by created_at, customer_id
    ) = 1

)

select * from deduplicated