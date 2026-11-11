
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

