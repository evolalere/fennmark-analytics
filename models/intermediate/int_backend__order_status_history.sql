-- One row per status event, with the interval during which that status was the order's status.
-- Status is derived from events, never stored on the order (docs/decisions.md 2026-10-27):
--   status at time t = the row where valid_from <= t and (valid_to > t or valid_to is null)
--   current status   = the row where is_current
-- Ordered by when the event happened (event_at), not when it was loaded, so the 2,226
-- late-arriving events land in their true place.

with

events as (

    select * from {{ ref('stg_backend__order_status_events') }}

),

ranked as (

    select
        *,
        -- tiebreak: 160 orders have placed and paid at the same instant (i3b, i3c);
        -- every legal transition goes from a lower rank to a higher one
        case status
            when 'placed'    then 1
            when 'paid'      then 2
            when 'shipped'   then 3
            when 'delivered' then 4
            when 'cancelled' then 5
            when 'returned'  then 6
            when 'refunded'  then 7
        end                                                    as status_rank
    from events

),

sequenced as (

    select
        *,
        row_number() over order_timeline                       as status_sequence,
        lag(status) over order_timeline                        as previous_status,
        lag(event_at) over order_timeline                      as previous_event_at,
        lead(event_at) over order_timeline                     as next_event_at,
        logical_or(status = 'paid') over (partition by order_id) as has_paid_event
    from ranked
    window order_timeline as (partition by order_id order by event_at, status_rank)

),

final as (

    select
        -- keys
        event_id,
        order_id,
        status_sequence,

        -- transition
        previous_status,
        status,
        reason,
        case
            when previous_status is null         then status = 'placed'
            when previous_status = 'placed'      then status in ('paid', 'cancelled')
            when previous_status = 'paid'        then status in ('shipped', 'cancelled')
            when previous_status = 'shipped'     then status = 'delivered'
            when previous_status = 'delivered'   then status = 'returned'
            when previous_status = 'cancelled'   then status = 'refunded' and has_paid_event
            when previous_status = 'returned'    then status = 'refunded'
            else false                           -- refunded is terminal
        end                                                    as is_legal_transition,

        -- validity: half-open interval [valid_from, valid_to)
        event_at                                               as valid_from,
        next_event_at                                          as valid_to,
        next_event_at is null                                  as is_current,
        timestamp_diff(event_at, previous_event_at, minute) / 60
                                                               as hours_since_previous_status,

        -- lateness (week 9 reads these)
        loaded_at,
        is_late_arriving

    from sequenced

)

select * from final