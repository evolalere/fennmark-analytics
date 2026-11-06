with source as (

    select * from {{ source('backend', 'returns') }}

),

renamed as (

    select
        -- keys
        return_id,
        order_id,
        order_item_id,                                -- null = whole-order return

        -- attributes
        reason,
        accepted,                                     -- already bool in raw

        -- flags
        order_item_id is null                         as is_whole_order_return,

        -- timestamps
        requested_at,
        loaded_at

    from source

)

select * from renamed