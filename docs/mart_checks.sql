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

