
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