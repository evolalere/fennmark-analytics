with source as (

    select * from {{ source('backend', 'refunds') }}

),

renamed as (

    select
        -- keys
        refund_id,
        order_id,
        return_id,                                                        -- null = cancellation refund (or a bad refund)

        -- attributes
        case when return_id is null then 'cancellation' else 'return' end as refund_type,
        currency,

        -- money (float64 in raw -> numeric)
        cast(amount as numeric)                                           as refund_amount,

        -- timestamps
        refunded_at,
        loaded_at

    from source

)

select * from renamed