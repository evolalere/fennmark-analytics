-- Of the customers who first ordered in week W, how many ordered again 1, 2, 3 ... weeks later?
-- One row per cohort week x weeks since first order. Orders in the reporting period, not cancelled.
-- Stores counts, not rates: the rate is active_customers / cohort_size at query time.

with

orders as (

    select * from {{ ref('fct_orders') }}
    where is_in_reporting_period
        and not is_cancelled

),

first_orders as (

    select
        customer_id,
        min(order_week)                                        as cohort_week
    from orders
    group by customer_id

),

cohort_sizes as (

    select
        cohort_week,
        count(*)                                               as cohort_size
    from first_orders
    group by cohort_week

),

-- distinct: a customer with two orders in one week is active once that week
activity as (

    select distinct
        orders.customer_id,
        first_orders.cohort_week,
        div(date_diff(orders.order_week, first_orders.cohort_week, day), 7)
                                                               as weeks_since_first_order
    from orders
    inner join first_orders
        on orders.customer_id = first_orders.customer_id

),

counted as (

    select
        cohort_week,
        weeks_since_first_order,
        count(*)                                               as active_customers
    from activity
    group by cohort_week, weeks_since_first_order

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'counted.cohort_week', 'counted.weeks_since_first_order'
        ]) }}
                                                               as cohort_period_id,
        counted.cohort_week,
        counted.weeks_since_first_order,
        cohort_sizes.cohort_size,
        counted.active_customers,

        -- the whole 7-day period lies inside the reporting period, so the cell can be compared
        date_add(
            counted.cohort_week, interval (counted.weeks_since_first_order + 1) * 7 - 1 day
        )   <= date '{{ var("reporting_end_date") }}'
            and counted.cohort_week >= date '{{ var("reporting_start_date") }}'
                                                               as is_complete_period

    from counted
    inner join cohort_sizes
        on counted.cohort_week = cohort_sizes.cohort_week

)

select * from final
