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

-- m9a · fct_returns: shape
select
    count(*)                                                        as returned_lines,
    countif(return_line_number = 1)                                 as requests,
    countif(return_line_number = 1 and is_accepted)                 as accepted_requests,
    countif(return_line_number = 1 and is_whole_order_return)       as whole_order_requests,
    min(days_from_delivery)                                         as min_days_from_delivery,
    max(days_from_delivery)                                         as max_days_from_delivery
from dbt_dev_marts.fct_returns;

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