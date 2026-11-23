-- docs/incremental_checks.sql · week 9 checks (r1 to r9). Results go in docs/dbt_notes.md.

-- r1 · how late do status events arrive? (decides the lookback)
select
    div(timestamp_diff(loaded_at, event_at, minute), 1440)     as days_late,
    count(*)                                                    as status_events
from dbt_dev_staging.stg_backend__order_status_events
group by days_late
order by days_late;

-- r2 · which state is raw in?  final: 5,458 / 628 / 21,766   early: 5,458 / 0 / 19,540
select
    (select count(*) from fm_raw.orders)                        as orders,
    (select countif(discount_amount > 0) from fm_raw.orders)    as discounted_orders,
    (select count(*) from fm_raw.order_status_events)           as status_events;

-- r3 · what the status history says right now (views, so it follows raw without a dbt run)
select
    status                                                      as current_status,
    count(*)                                                    as orders
from dbt_dev_intermediate.int_backend__order_status_history
where is_current
group by status
order by orders desc;

-- r3b · and how many transitions it finds illegal (includes histories that do not start at placed)
select
    count(*)                                                    as status_rows,
    countif(not is_legal_transition)                            as illegal_transitions
from dbt_dev_intermediate.int_backend__order_status_history;

-- r4 · shape of the snapshot
select
    count(*)                                                    as version_rows,
    count(distinct order_id)                                    as orders,
    countif(dbt_valid_to is null)                               as current_rows,
    countif(dbt_valid_to is not null)                           as closed_rows,
    count(distinct dbt_valid_from)                              as snapshot_runs_with_changes
from dbt_dev_snapshots.snp_backend__orders;

-- r5 · what changed between the first version of an order and the current one
with

versions as (

    select
        order_id,
        discount_amount,
        gross_revenue - discount_amount                         as net_revenue,
        dbt_valid_from,
        dbt_valid_to,
        row_number() over (partition by order_id order by dbt_valid_from) as version_number
    from dbt_dev_snapshots.snp_backend__orders

)

select
    countif(first_version.discount_amount != current_version.discount_amount) as orders_changed,
    sum(first_version.net_revenue)                              as net_revenue_as_first_seen,
    sum(current_version.net_revenue)                            as net_revenue_now,
    sum(current_version.discount_amount)                        as discount_applied_later
from versions as first_version
inner join versions as current_version
    on first_version.order_id = current_version.order_id
where first_version.version_number = 1
    and current_version.dbt_valid_to is null;

-- r6 · does every shard hold exactly its own date? (insert_overwrite depends on it)
select
    count(*)                                                    as events,
    countif(_table_suffix != event_date)                        as events_in_another_days_shard
from `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
where _table_suffix between '20201101' and '20210131';

-- r7 · fingerprint of stg_ga4__events (run before and after every experiment)
select
    count(*)                                                    as events,
    count(distinct event_date)                                  as days,
    max(event_date)                                             as last_date,
    countif(event_name = 'purchase')                            as purchase_events,
    bit_xor(farm_fingerprint(event_key))                        as key_fingerprint
from dbt_dev_staging.stg_ga4__events;

-- r8 · over how many dates does one session stretch? (decides the session buffer)
select
    date_diff(max_event_date, min_event_date, day)              as days_spanned,
    count(*)                                                    as sessions
from (
    select
        session_key,
        min(event_date)                                         as min_event_date,
        max(event_date)                                         as max_event_date
    from dbt_dev_staging.stg_ga4__events
    where ga_session_id is not null
    group by session_key
)
group by days_spanned
order by days_spanned;

-- r9 · fingerprint of int_ga4__sessions (run before and after every experiment)
select
    count(*)                                                    as sessions,
    count(distinct session_key)                                 as distinct_sessions,
    sum(event_count)                                            as events,
    countif(has_purchase)                                       as sessions_with_purchase,
    max(session_date)                                           as last_date,
    bit_xor(farm_fingerprint(concat(
        session_key, '|', cast(event_count as string), '|',
        cast(session_end_at as string), '|', cast(has_purchase as string)
    )))                                                         as row_fingerprint
from dbt_dev_intermediate.int_ga4__sessions;

-- r10a · late-data experiment, inside the lookback: remove one recent day's purchase events
-- from OUR table, as if they had not been exported yet. Run only in step C5.
delete from dbt_dev_staging.stg_ga4__events
where event_date = date '2021-01-30'
    and event_name = 'purchase';

-- r10b · the same, outside the lookback. Run only in step C6; it needs a full refresh to undo.
delete from dbt_dev_staging.stg_ga4__events
where event_date = date '2021-01-15'
    and event_name = 'purchase';
