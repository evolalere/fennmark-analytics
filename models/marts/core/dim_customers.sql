-- What share of customers in the period are repeat buyers, and how many consented to email?
-- One row per customer that survives the dedup in staging. Order figures cover orders placed in
-- the reporting period that were not cancelled. No name or email: nothing downstream needs them.

with

customers as (

    select * from {{ ref('stg_backend__customers') }}

),

orders as (

    select * from {{ ref('fct_orders') }}
    where is_in_reporting_period
        and not is_cancelled

),

order_summary as (

    select
        customer_id,
        count(*)                                               as order_count,
        min(order_date)                                        as first_order_date,
        max(order_date)                                        as last_order_date,
        sum(if(has_currency_mismatch, 0, net_revenue))         as net_revenue_usd
    from orders
    group by customer_id

),

final as (

    select
        -- keys
        customers.customer_id,
        customers.user_pseudo_id,                              -- ga4 cookie; null if backend-only

        -- attributes
        customers.country,
        customers.acquisition_date,
        customers.created_at,

        -- consent: null means we never asked, which is not a yes (spec section 7)
        case
            when customers.has_email_consent then 'consented'
            when not customers.has_email_consent then 'declined'
            else 'unknown'
        end                                                    as email_consent_status,
        coalesce(customers.has_email_consent, false)           as is_email_contactable,

        -- orders in the reporting period, not cancelled
        coalesce(order_summary.order_count, 0)                 as order_count,
        order_summary.first_order_date,
        order_summary.last_order_date,
        coalesce(order_summary.net_revenue_usd, 0)             as net_revenue_usd,

        -- flags
        customers.user_pseudo_id is not null                   as is_linked_to_ga4,
        coalesce(order_summary.order_count, 0) >= 1            as is_buyer,
        coalesce(order_summary.order_count, 0) >= 2            as is_repeat_buyer

    from customers
    left join order_summary
        on customers.customer_id = order_summary.customer_id

)

select * from final
