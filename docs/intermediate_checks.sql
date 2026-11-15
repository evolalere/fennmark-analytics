
-- i1 · what a session is made of
select
count(*) as events,                                                           -- 4,295,584
countif(ga_session_id is null) as events_without_session_id,                  -- 0
count(distinct if(ga_session_id is not null, session_key, null)) as sessions, -- 360,129
countif(event_name = 'session_start') as session_start_events -- 354,970
from dbt_dev_staging.stg_ga4__events;

-- i1b · do sessions cross midnight? (one session_key on two event_dates)
select count(*) as sessions_on_two_dates -- 845
from (
select session_key
from dbt_dev_staging.stg_ga4__events
where ga_session_id is not null
group by session_key
having count(distinct event_date) > 1
);

-- i2 · sessions model against the Week 6 figures
select
count(*) as sessions, -- 360,129
sum(event_count) as events_in_sessions, -- i1 events minus events_without_session_id
countif(not has_session_start_event) as without_session_start, -- about 5,159; record the real figure
countif(is_engaged) as engaged_sessions,
countif(has_purchase) as sessions_with_purchase,
countif(transaction_count > 0) as sessions_with_identified_purchase,
countif(session_duration_seconds = 0) as zero_duration_sessions,
approx_quantiles(session_duration_seconds, 2)[offset(1)] as median_duration_seconds
from dbt_dev_intermediate.int_ga4__sessions;

-- i2b · session_start events per session (0: 5,272 · 1: 354,752 · 2: 99 · 3: 4 · 4: 2)
select session_starts, count(*) as sessions
from (
    select session_key, countif(event_name = 'session_start') as session_starts
    from dbt_dev_staging.stg_ga4__events
    group by session_key
)
group by session_starts
order by session_starts;

-- i3 · shape of the status events
select
    count(*)                    as status_events, -- 21,766
    count(distinct order_id)    as orders_with_events, -- 5,458
    countif(is_late_arriving)   as late_events,  -- 2,226
    min(event_at)               as first_event_at, -- 2020-11-02 00:22:16 UTC
    max(event_at)               as last_event_at -- 2021-03-03 16:09:35 UTC
from dbt_dev_staging.stg_backend__order_status_events;

-- i3b · ties: two or more events of one order at the same instant
select
    count(*)                    as tied_instants,       -- 160
    sum(events_at_instant)      as events_involved,     -- 320
    max(events_at_instant)      as max_events_at_one_instant -- 2
from (
    select order_id, event_at, count(*) as events_at_instant
    from dbt_dev_staging.stg_backend__order_status_events
    group by order_id, event_at
    having count(*) > 1
);

-- i3c · which statuses tie
select statuses, count(*) as tied_instants
from (
    select order_id, event_at, string_agg(status, ' + ' order by status) as statuses
    from dbt_dev_staging.stg_backend__order_status_events
    group by order_id, event_at
    having count(*) > 1
)
group by statuses
order by tied_instants desc;

-- i4 · current status of every order
select status, count(*) as orders
from dbt_dev_intermediate.int_backend__order_status_history
where is_current
group by status
order by orders desc; -- sums to 5,458

-- i5 · status at time T: where was every order on Christmas Eve 2020?
select status, count(*) as orders
from dbt_dev_intermediate.int_backend__order_status_history
where valid_from <= timestamp '2020-12-24 12:00:00'
and (valid_to > timestamp '2020-12-24 12:00:00' or valid_to is null)
group by status
order by orders desc; -- only orders placed by then

-- i6 · illegal transitions (expected: no rows). Week 10 turns this into a singular test.
select previous_status, status, count(*) as transitions
from dbt_dev_intermediate.int_backend__order_status_history
where not is_legal_transition
group by previous_status, status
order by transitions desc;

-- i7 · customer id mapping
select
    count(*)                    as ids,              -- 4,724
    countif(is_canonical)       as customers,        -- 4,651
    countif(not is_canonical)   as duplicate_ids     -- 73
from dbt_dev_intermediate.int_backend__customer_identity_map;

select
    (select count(*) from dbt_dev_staging.stg_backend__orders as orders
        join dbt_dev_intermediate.int_backend__customer_identity_map as map
            on orders.customer_id = map.source_customer_id
        where not map.is_canonical)   as orders_restitched,    -- 7
    (select count(*) from dbt_dev_staging.stg_backend__nps_surveys as surveys
        join dbt_dev_intermediate.int_backend__customer_identity_map as map
            on surveys.customer_id = map.source_customer_id
        where not map.is_canonical)   as surveys_restitched;   -- 5

-- i8 · reconciliation
select reconciliation_category, reconciliation_detail, count(*) as purchases,
       round(sum(ga4_purchase_revenue), 2) as ga4_revenue,
       round(sum(gross_revenue), 2)        as backend_gross_revenue
from dbt_dev_intermediate.int_reconciliation__ga4_vs_backend
group by reconciliation_category, reconciliation_detail
order by reconciliation_category, reconciliation_detail;

-- i8b · what the 450 no-id, no-revenue purchase events carry in items
select
    count(*)                                                       as events,
    countif(array_length(items) = 1
            and items[safe_offset(0)].price is null)               as single_placeholder_item,
    countif(array_length(items) = 0)                               as no_items,
    countif(array_length(items) > 1)                               as several_items,
    countif(ecommerce.transaction_id is null)                      as null_transaction_id
from `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
where _table_suffix between '20201101' and '20210131'
    and event_name = 'purchase'
    and ecommerce.purchase_revenue is null
    and coalesce(
        nullif(ecommerce.transaction_id, '(not set)'),
        nullif((select any_value(value.string_value) from unnest(event_params)
                where key = 'transaction_id'), '(not set)')
    ) is null;

-- i9 · why matched orders differ in revenue
select revenue_delta_reason, count(*) as orders,
       round(sum(gross_revenue_delta), 2) as gross_delta,
       round(sum(net_revenue_delta), 2)   as net_delta
from dbt_dev_intermediate.int_reconciliation__ga4_vs_backend
where reconciliation_category = 'matched'
group by revenue_delta_reason
order by orders desc;

-- i10 · independent flags and stitching, matched orders only
select
    countif(has_backend_discount)             as with_backend_discount,
    countif(has_ga4_header_vs_lines_gap)      as ga4_header_vs_lines_gap,
    countif(has_ga4_line_discount)            as ga4_line_discount,
    countif(net_lines_delta != 0)             as line_sums_differ,
    countif(is_same_cookie)                   as same_cookie,
    countif(placed_at = purchased_at)         as same_timestamp,
    countif(has_currency_mismatch)            as eur_flagged
from dbt_dev_intermediate.int_reconciliation__ga4_vs_backend
where reconciliation_category = 'matched';

-- i11 · backend orders placed outside the ga4 window
select
    countif(placed_at >= timestamp '2021-02-01')    as orders_after_window,
    min(placed_at)                                  as first_order_at,
    max(placed_at)                                  as last_order_at
from dbt_dev_staging.stg_backend__orders;

-- i11b · who is placed after 2021-01-31 utc
select reconciliation_category, count(*) as orders,
       min(placed_at) as first_at, max(placed_at) as last_at
from dbt_dev_intermediate.int_reconciliation__ga4_vs_backend
where placed_at >= timestamp '2021-02-01'
group by reconciliation_category;

