-- the raw table has a column named `source`, so the usual `source` cte would shadow it
with raw as (

    select * from {{ source('backend', 'marketing_spend') }}

),

renamed as (

    select
        -- surrogate key: raw has no natural key; campaign is part of the grain
        {{ dbt_utils.generate_surrogate_key(['spend_date', 'source', 'medium', 'campaign']) }}
                                                      as marketing_spend_id,

        -- grain
        spend_date,
        source,
        medium,
        campaign,

        -- money (float64 in raw -> numeric)
        cast(spend_usd as numeric)                        as spend_amount,

        -- flags
        spend_usd > 0                                     as is_paid,

        -- timestamps
        loaded_at

    from raw

)

select * from renamed