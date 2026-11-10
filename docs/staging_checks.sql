
-- 1,0 Row counts (every view = raw, customers = raw − 73)
select 'customers' as t, count(*) as n from `fennmark-analytics.dbt_dev_staging.stg_backend__customers`
union all select 'orders', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__orders`
union all select 'order_items', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__order_items`
union all select 'order_status_events', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__order_status_events`
union all select 'products', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__products`
union all select 'returns', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__returns`
union all select 'refunds', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__refunds`
union all select 'nps_surveys', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__nps_surveys`
union all select 'marketing_spend', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__marketing_spend`
union all select 'experiment_assignments', count(*) from `fennmark-analytics.dbt_dev_staging.stg_backend__experiment_assignments`


-- 2,0 Staging ledger
select 'duplicate customers (cookie)' as problem, count(*) - count(distinct user_pseudo_id) as n
  from `fennmark-analytics.dbt_dev_staging.stg_backend__customers` where user_pseudo_id is not null   -- 0
union all select 'unparseable event_at', countif(event_at is null)
  from `fennmark-analytics.dbt_dev_staging.stg_backend__order_status_events`                           -- 0
union all select 'late-arriving flagged', countif(is_late_arriving)
  from `fennmark-analytics.dbt_dev_staging.stg_backend__order_status_events`                           -- 2226
union all select 'null consent (bool)', countif(has_email_consent is null)
  from `fennmark-analytics.dbt_dev_staging.stg_backend__customers`                                     -- ~700
union all select 'currency mismatch flagged', countif(has_currency_mismatch)
  from `fennmark-analytics.dbt_dev_staging.stg_backend__orders`                                        -- 20
union all select 'null shipping_country', countif(shipping_country is null)
  from `fennmark-analytics.dbt_dev_staging.stg_backend__orders`                                        -- 0
union all select 'category Other', countif(category = 'Other')
  from `fennmark-analytics.dbt_dev_staging.stg_backend__products`                                      -- 0

-- ============================================================================
-- GA4 staging checks. Run against the dev staging dataset after dbt build.
-- Results recorded in docs/dbt_notes.md, "Staging checks (GA4)".
-- Raw reads (q1, q6b) filter _table_suffix and cost ~1-1.5 GB each; the rest read the
-- staging table or views and are cheap.
-- ============================================================================

-- q1 · candidate event key unique on raw?  expected: events = distinct_keys = 4,295,584
with events as (
    select
        user_pseudo_id, event_timestamp, event_name, event_bundle_sequence_id,
        (select any_value(value.int_value) from unnest(event_params)
            where key = 'ga_session_id')                                  as ga_session_id,
        (select any_value(value.int_value) from unnest(event_params)
            where key = 'engagement_time_msec')                           as engagement_time_msec,
        (select any_value(value.string_value) from unnest(event_params)
            where key = 'page_location')                                  as page_location
    from `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    where _table_suffix between '20201101' and '20210131'
)
select
    count(*)                                                          as events,
    count(distinct concat(
        user_pseudo_id, event_timestamp, event_name,
        ifnull(cast(event_bundle_sequence_id as string), ''),
        ifnull(cast(ga_session_id as string), ''),
        ifnull(cast(engagement_time_msec as string), ''),
        ifnull(page_location, '')
    ))                                                                as distinct_keys
from events;

-- q2 · nothing dropped; monthly split matches week 2 q2.  expected total 4,295,584
select
    format_date('%Y-%m', event_date) as month,
    count(*)                         as events
from dbt_dev_staging.stg_ga4__events
group by 1
union all
select 'total', count(*) from dbt_dev_staging.stg_ga4__events
order by 1;

-- q3 · sessions by key vs by session_start event.  expected 360,129 vs 354,857 (1.5% gap)
select
    count(distinct session_key)                        as sessions_by_key,
    countif(event_name = 'session_start')              as session_start_events
from dbt_dev_staging.stg_ga4__events;

-- q4 · purchase event buckets.  expected 5,692 = 4,786 identified + 906 unidentified
select
    count(*)                                           as purchase_events,
    countif(transaction_id is not null)                as identified_events,
    countif(transaction_id is null)                    as unidentified_events,
    count(distinct transaction_id)                     as identified_transactions   -- 4,451
from dbt_dev_staging.stg_ga4__events
where event_name = 'purchase';

-- q5 · placeholders among the unidentified.  expected 448
select countif(purchase_revenue is null) as placeholder_events
from dbt_dev_staging.stg_ga4__events
where event_name = 'purchase' and transaction_id is null;

-- q6 · duplicates kept visible.  expected 335 events on 326 transactions
select
    count(*)                                           as transactions,          -- 4,451
    sum(purchase_event_count - 1)                      as duplicate_events,
    countif(has_duplicate_events)                      as transactions_with_duplicates
from dbt_dev_staging.stg_ga4__purchases;

-- q6b · do duplicate events of one transaction agree on revenue? (raw)  expected 311 / 15
with p as (
    select
        coalesce(
            nullif(ecommerce.transaction_id, '(not set)'),
            nullif((select any_value(value.string_value) from unnest(event_params)
                    where key = 'transaction_id'), '(not set)')
        )                                   as transaction_id,
        ecommerce.purchase_revenue          as revenue
    from `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    where _table_suffix between '20201101' and '20210131'
        and event_name = 'purchase'
)
select
    countif(n_revenues = 1) as agree,
    countif(n_revenues > 1) as disagree
from (
    select transaction_id, count(distinct revenue) as n_revenues
    from p
    where transaction_id is not null
    group by 1
    having count(*) > 1
);

-- q7 · lines, and header revenue vs sum of net lines inside GA4.  expected 13,218 lines
with lines as (
    select transaction_id, sum(net_line_amount) as net_lines, count(*) as n_lines
    from dbt_dev_staging.stg_ga4__purchase_items
    group by 1
)
select
    sum(n_lines)                                                   as lines,
    count(*)                                                       as transactions,
    countif(p.purchase_revenue = l.net_lines)                      as header_equals_lines,
    countif(p.purchase_revenue != l.net_lines)                     as header_differs,
    countif(p.total_item_quantity = (
        select sum(quantity) from dbt_dev_staging.stg_ga4__purchase_items i
        where i.transaction_id = p.transaction_id))                as quantity_matches
from dbt_dev_staging.stg_ga4__purchases p
join lines l using (transaction_id);

-- q8 · gross vs net on lines.  expected 1,072 differ, 495 net > gross
select
    count(*)                                           as lines,
    countif(gross_line_amount != net_line_amount)      as lines_with_gap,
    countif(net_line_amount > gross_line_amount)       as net_above_gross,
    countif(item_variant is null)                      as single_option_lines,   -- 8,338
    countif(raw_item_category is null
            or raw_item_category = '')                 as blank_category_lines   -- 204
from dbt_dev_staging.stg_ga4__purchase_items;

-- q9 · bytes per model from the last build: see the python one-liner in dbt_notes.md