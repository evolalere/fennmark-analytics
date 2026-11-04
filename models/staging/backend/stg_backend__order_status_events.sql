with source as (

    select * from {{ source('backend', 'order_status_events') }}

),

renamed as (

    select
        -- keys
        event_id,
        order_id,

        -- attributes
        status,
        reason,                                           -- populated on cancelled / returned only

        -- timestamps
        {{ parse_mixed_timestamp('event_ts_raw') }}       as event_at,         -- ledger: two string formats -> utc
        loaded_at,

        -- flags
        loaded_at > {{ parse_mixed_timestamp('event_ts_raw') }} + interval 1 day
                                                          as is_late_arriving  -- ~10%; week 9 reads this

    from source

)

select * from renamed