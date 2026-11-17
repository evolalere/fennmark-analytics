-- What is NPS by delivery month, and does it move with shipping time?
-- One row per survey sent (one per delivered order). The promoter / passive / detractor band
-- is decided here and nowhere earlier. nps_points averages straight to the NPS score.

with

surveys as (

    select * from {{ ref('stg_backend__nps_surveys') }}

),

customers as (

    select * from {{ ref('int_backend__customer_identity_map') }}

),

orders as (

    select * from {{ ref('fct_orders') }}

),

banded as (

    select
        *,
        case
            when score >= 9 then 'promoter'
            when score >= 7 then 'passive'
            when score >= 0 then 'detractor'
        end                                                    as nps_category
    from surveys

),

final as (

    select
        -- keys
        banded.survey_id,
        banded.order_id,
        customers.customer_id,                                 -- canonical

        -- when
        banded.sent_at,
        banded.responded_at,
        orders.delivered_at,
        date_trunc(date(orders.delivered_at), month)           as delivery_month,

        -- attributes
        orders.channel,
        orders.days_to_deliver,
        case
            when orders.days_to_deliver <= 5 then '1: up to 5 days'
            when orders.days_to_deliver <= 8 then '2: 6 to 8 days'
            when orders.days_to_deliver > 8 then '3: 9 days or more'
        end                                                    as delivery_time_band,

        -- measures
        banded.score,
        banded.nps_category,
        case banded.nps_category
            when 'promoter' then 100
            when 'passive' then 0
            when 'detractor' then -100
        end                                                    as nps_points,

        -- flags
        banded.has_responded,
        orders.is_in_reporting_period

    from banded
    inner join orders
        on banded.order_id = orders.order_id
    left join customers
        on banded.customer_id = customers.source_customer_id

)

select * from final
