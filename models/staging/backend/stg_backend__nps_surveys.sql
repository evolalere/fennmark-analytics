with source as (

    select * from {{ source('backend', 'nps_surveys') }}

),

renamed as (

    select
        -- keys
        survey_id,
        order_id,
        customer_id,

        -- attributes
        score,                                        -- 0-10; null when unanswered. promoter/passive/detractor bands belong to fct_nps
        verbatim,

        -- flags
        responded_at is not null                      as has_responded,

        -- timestamps
        sent_at,
        responded_at,
        loaded_at

    from source

)

select * from renamed