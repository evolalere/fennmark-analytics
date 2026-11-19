-- m1 · before building: the period, the stub week, the edge cases
select
    count(*)                                                        as orders,
    countif(date(placed_at) between '2020-11-01' and '2021-01-31')  as orders_in_period,
    countif(date_trunc(date(placed_at), week(monday)) = '2020-10-26') as orders_in_stub_week,
    countif(has_currency_mismatch)                                  as eur_orders,
    countif(discount_amount > 0)                                    as discounted_orders
from dbt_dev_staging.stg_backend__orders;

-- m2 · fct_orders: shape
select
    count(*)                                                        as orders,
    count(distinct customer_id)                                     as customers,
    countif(is_in_reporting_period)                                 as in_period,
    countif(is_cancelled)                                           as cancelled,
    countif(is_delivered)                                           as delivered,
    countif(is_returned)                                            as returned,
    countif(refunded_amount > 0)                                    as with_refund,
    countif(refunded_amount > 0 and current_status = 'shipped')     as refund_while_shipped,
    max(customer_order_number)                                      as most_orders_by_one_customer
from dbt_dev_marts.fct_orders;

-- m2b · customers with no order: who are they?
select
    count(*)                                                        as customers_without_order,
    countif(customers.user_pseudo_id is null)                       as without_cookie,
    countif(ga4_only.ga4_user_pseudo_id is not null)                as cookie_has_ga4_only_purchase
from dbt_dev_staging.stg_backend__customers as customers
left join (
    select distinct customer_id from dbt_dev_marts.fct_orders
) as orders
    on customers.customer_id = orders.customer_id
left join (
    select distinct ga4_user_pseudo_id
    from dbt_dev_intermediate.int_reconciliation__ga4_vs_backend
    where reconciliation_detail = 'ga4_only_no_backend_order'
) as ga4_only
    on customers.user_pseudo_id = ga4_only.ga4_user_pseudo_id
where orders.customer_id is null;

-- m3 · Q1 headline: revenue, orders, and what GA4 missed
select
    count(*)                                                        as orders,
    countif(not is_cancelled)                                       as orders_not_cancelled,
    round(sum(if(not is_cancelled and not has_currency_mismatch, net_revenue, 0)), 2) as net_revenue_usd,
    round(sum(if(not has_currency_mismatch, refunded_amount, 0)), 2) as refunded_usd,
    countif(reconciliation_category = 'backend_only')               as orders_ga4_missed,
    round(safe_divide(countif(reconciliation_category = 'backend_only'), count(*)), 4) as share_ga4_missed
from dbt_dev_marts.fct_orders
where is_in_reporting_period;

-- m4 · Q1 breakdown: per week by channel
select
    order_week,
    channel,
    count(*)                                                        as orders,
    round(sum(if(not is_cancelled and not has_currency_mismatch, net_revenue, 0)), 2) as net_revenue_usd,
    round(safe_divide(countif(reconciliation_category = 'backend_only'), count(*)), 3) as share_ga4_missed
from dbt_dev_marts.fct_orders
where is_in_reporting_period
group by order_week, channel
order by order_week, channel;

-- m5 · fct_order_items: do lines add up to the order?
select
    count(*)                                                        as orders,
    countif(round(lines.line_revenue, 2) = round(orders.gross_revenue, 2)) as lines_equal_gross,
    countif(round(lines.line_revenue, 2) != round(orders.gross_revenue, 2)) as lines_differ_from_gross,
    sum(lines.negative_margin_lines)                                as negative_margin_lines
from dbt_dev_marts.fct_orders as orders
inner join (
    select
        order_id,
        sum(line_revenue)                                           as line_revenue,
        countif(margin_amount < 0)                                  as negative_margin_lines
    from dbt_dev_marts.fct_order_items
    group by order_id
) as lines
    on orders.order_id = lines.order_id;

-- m6 · Q2: margin by category
select
    products.category,
    sum(items.quantity)                                             as units,
    round(sum(items.line_revenue), 2)                               as revenue,
    round(sum(items.margin_amount), 2)                              as margin,
    round(safe_divide(sum(items.margin_amount), sum(items.line_revenue)), 3) as margin_rate
from dbt_dev_marts.fct_order_items as items
inner join dbt_dev_marts.dim_products as products
    on items.product_id = products.product_id
where items.is_in_reporting_period
    and not items.is_cancelled
    and not items.has_currency_mismatch
group by products.category
order by margin desc;

-- m7 · Q3: repeat buyers and consent
select
    count(*)                                                        as customers,
    countif(is_buyer)                                               as buyers_in_period,
    countif(is_repeat_buyer)                                        as repeat_buyers,
    round(safe_divide(countif(is_repeat_buyer), countif(is_buyer)), 4) as repeat_share,
    countif(email_consent_status = 'consented')                     as consented,
    countif(email_consent_status = 'declined')                      as declined,
    countif(email_consent_status = 'unknown')                       as unknown,
    countif(is_linked_to_ga4)                                       as linked_to_ga4
from dbt_dev_marts.dim_customers;

-- m8 · Q4: launches and time to first sale
select
    count(*)                                                        as skus,
    countif(is_sold)                                                as skus_sold,
    countif(is_launched_in_period)                                  as launched_in_period,
    countif(is_launched_in_period and is_sold)                      as launched_and_sold,
    round(avg(if(is_launched_in_period, days_to_first_sale, null)), 1) as avg_days_to_first_sale,
    min(days_to_first_sale)                                         as min_days_to_first_sale
from dbt_dev_marts.dim_products;

-- m9 · Q6: return rate by category (lines), then by channel (orders), then reasons
select
    products.category,
    countif(items.is_delivered)                                     as delivered_lines,
    count(returns.return_line_id)                                   as returned_lines,
    round(safe_divide(count(returns.return_line_id), countif(items.is_delivered)), 4) as return_rate
from dbt_dev_marts.fct_order_items as items
inner join dbt_dev_marts.dim_products as products
    on items.product_id = products.product_id
left join dbt_dev_marts.fct_returns as returns
    on items.order_item_id = returns.order_item_id
where items.is_in_reporting_period
group by products.category
order by return_rate desc;

select
    orders.channel,
    countif(orders.is_delivered)                                    as delivered_orders,
    count(returns.return_id)                                        as orders_with_return_request,
    round(safe_divide(count(returns.return_id), countif(orders.is_delivered)), 4) as return_rate
from dbt_dev_marts.fct_orders as orders
left join (
    select * from dbt_dev_marts.fct_returns where return_line_number = 1
) as returns
    on orders.order_id = returns.order_id
where orders.is_in_reporting_period
group by orders.channel
order by return_rate desc;

select
    reason,
    count(*)                                                        as requests,
    countif(is_accepted)                                            as accepted
from dbt_dev_marts.fct_returns
where return_line_number = 1
    and is_in_reporting_period
group by reason
order by requests desc;

-- m9a · fct_returns: shape
select
    count(*)                                                        as returned_lines,
    countif(return_line_number = 1)                                 as requests,
    countif(return_line_number = 1 and is_accepted)                 as accepted_requests,
    countif(return_line_number = 1 and is_whole_order_return)       as whole_order_requests,
    min(days_from_delivery)                                         as min_days_from_delivery,
    max(days_from_delivery)                                         as max_days_from_delivery
from dbt_dev_marts.fct_returns;

-- m10 · Q7: NPS by delivery month and by delivery time
select
    delivery_month,
    count(*)                                                        as surveys,
    countif(has_responded)                                          as responses,
    round(avg(nps_points), 1)                                       as nps,
    round(avg(days_to_deliver), 1)                                  as avg_days_to_deliver
from dbt_dev_marts.fct_nps
group by delivery_month
order by delivery_month;

select
    delivery_time_band,
    countif(has_responded)                                          as responses,
    round(avg(nps_points), 1)                                       as nps
from dbt_dev_marts.fct_nps
group by delivery_time_band
order by delivery_time_band;

-- m10a · fct_nps: shape, and whether the delivery-time bands are usable
select
    count(*)                                                        as surveys,
    countif(has_responded)                                          as responses,
    countif(nps_category = 'promoter')                              as promoters,
    countif(nps_category = 'passive')                               as passives,
    countif(nps_category = 'detractor')                             as detractors,
    round(avg(nps_points), 1)                                       as nps,
    min(days_to_deliver)                                            as min_days_to_deliver,
    max(days_to_deliver)                                            as max_days_to_deliver
from dbt_dev_marts.fct_nps;

select
    delivery_time_band,
    count(*)                                                        as surveys,
    countif(has_responded)                                          as responses
from dbt_dev_marts.fct_nps
group by delivery_time_band
order by delivery_time_band;

-- m10c · NPS by whole days in transit (shipped -> delivered)
select
    days_in_transit,
    countif(has_responded)                                          as responses,
    round(avg(nps_points), 1)                                       as nps
from dbt_dev_marts.fct_nps
group by days_in_transit
order by days_in_transit;

-- m11 · Q5: the funnel by device, closed (in order) beside open (each step alone)
select
    device_category,
    count(*)                                                        as sessions,
    countif(funnel_depth >= 1)                                      as viewed_item,
    countif(funnel_depth >= 2)                                      as added_to_cart,
    countif(funnel_depth >= 3)                                      as began_checkout,
    countif(funnel_depth >= 4)                                      as purchased,
    round(safe_divide(countif(funnel_depth >= 2), countif(funnel_depth >= 1)), 3) as view_to_cart,
    round(safe_divide(countif(funnel_depth >= 3), countif(funnel_depth >= 2)), 3) as cart_to_checkout,
    round(safe_divide(countif(funnel_depth >= 4), countif(funnel_depth >= 3)), 3) as checkout_to_purchase,
    countif(has_purchase)                                           as purchased_open,
    countif(has_purchase and funnel_depth < 4)                      as purchased_skipping_a_step
from dbt_dev_marts.fct_sessions
group by device_category
order by sessions desc;

-- m11a · device categories in the sample (sets the accepted_values list for fct_sessions)
select
    device_category,
    count(*)                                                        as sessions
from dbt_dev_intermediate.int_ga4__sessions
group by device_category
order by sessions desc;

-- m11b · fct_sessions: shape
select
    count(*)                                                        as sessions,
    countif(is_known_customer)                                      as sessions_of_known_customers,
    count(distinct customer_id)                                     as customers_with_sessions,
    countif(has_purchase)                                           as sessions_with_purchase,
    countif(has_identified_purchase)                                as sessions_with_identified_purchase,
    countif(is_abandoned_checkout)                                  as abandoned_checkouts
from dbt_dev_marts.fct_sessions;

-- m11c · purchase sessions by closed-funnel depth: which step is missing?
select
    funnel_depth,
    count(*)                                                        as purchase_sessions,
    countif(has_view_item)                                          as with_view_item,
    countif(has_add_to_cart)                                        as with_add_to_cart,
    countif(has_begin_checkout)                                     as with_begin_checkout,
    countif(is_first_session)                                       as first_sessions
from dbt_dev_marts.fct_sessions
where has_purchase
group by funnel_depth
order by funnel_depth;

-- m12 · repeat purchase: share of a cohort ordering again n weeks after its first order (complete weeks only)
with

cohorts as (

    select distinct cohort_week, cohort_size
    from dbt_dev_marts.agg_repeat_purchase_cohorts
    where cohort_week >= date '2020-11-02'

),

grid as (

    select cohorts.cohort_week, cohorts.cohort_size, n
    from cohorts
    cross join unnest(generate_array(0, 12)) as n
    where date_add(cohorts.cohort_week, interval (n + 1) * 7 - 1 day) <= date '2021-01-31'

)

select
    grid.n                                                          as weeks_since_first_order,
    count(*)                                                        as cohorts,
    sum(grid.cohort_size)                                           as customers,
    sum(coalesce(agg.active_customers, 0))                          as ordered_again,
    round(safe_divide(sum(coalesce(agg.active_customers, 0)), sum(grid.cohort_size)), 4) as repeat_rate
from grid
left join dbt_dev_marts.agg_repeat_purchase_cohorts as agg
    on grid.cohort_week = agg.cohort_week
    and grid.n = agg.weeks_since_first_order
group by grid.n
order by grid.n;

-- m12 · retention: share of new visitors returning n weeks after their first session (complete weeks only)
with

cohorts as (

    select distinct cohort_week, cohort_size
    from dbt_dev_marts.agg_retention_cohorts
    where cohort_week >= date '2020-11-02'

),

grid as (

    select cohorts.cohort_week, cohorts.cohort_size, n
    from cohorts
    cross join unnest(generate_array(0, 12)) as n
    where date_add(cohorts.cohort_week, interval (n + 1) * 7 - 1 day) <= date '2021-01-31'

)

select
    grid.n                                                          as weeks_since_first_session,
    count(*)                                                        as cohorts,
    sum(grid.cohort_size)                                           as visitors,
    sum(coalesce(agg.active_visitors, 0))                           as came_back,
    round(safe_divide(sum(coalesce(agg.active_visitors, 0)), sum(grid.cohort_size)), 4) as retention_rate
from grid
left join dbt_dev_marts.agg_retention_cohorts as agg
    on grid.cohort_week = agg.cohort_week
    and grid.n = agg.weeks_since_first_session
group by grid.n
order by grid.n;