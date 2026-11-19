-- Of the visitors whose first-ever session was in week W, how many came back 1, 2, 3 ... weeks later?
-- One row per cohort week x weeks since first session. NEW visitors only (their first session in
-- the window has ga_session_number = 1): a visitor who was already returning on 1 November has a
-- first visit we cannot see, and would be put in the wrong cohort. A visitor is a cookie.

with

sessions as (

    select * from {{ ref('fct_sessions') }}

),

first_sessions as (

    select
        user_pseudo_id,
        min(session_week)                                      as cohort_week,
        min(ga_session_number)                                 as first_session_number
    from sessions
    group by user_pseudo_id

),

new_visitors as (

    select * from first_sessions
    where first_session_number = 1

),

cohort_sizes as (

    select
        cohort_week,
        count(*)                                               as cohort_size
    from new_visitors
    group by cohort_week

),

activity as (

    select distinct
        sessions.user_pseudo_id,
        new_visitors.cohort_week,
        div(date_diff(sessions.session_week, new_visitors.cohort_week, day), 7)
                                                               as weeks_since_first_session
    from sessions
    inner join new_visitors
        on sessions.user_pseudo_id = new_visitors.user_pseudo_id

),

counted as (

    select
        cohort_week,
        weeks_since_first_session,
        count(*)                                               as active_visitors
    from activity
    group by cohort_week, weeks_since_first_session

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'counted.cohort_week', 'counted.weeks_since_first_session'
        ]) }}
                                                               as cohort_period_id,
        counted.cohort_week,
        counted.weeks_since_first_session,
        cohort_sizes.cohort_size,
        counted.active_visitors,
        date_add(
            counted.cohort_week, interval (counted.weeks_since_first_session + 1) * 7 - 1 day
        )   <= date '{{ var("reporting_end_date") }}'
            and counted.cohort_week >= date '{{ var("reporting_start_date") }}'
                                                               as is_complete_period

    from counted
    inner join cohort_sizes
        on counted.cohort_week = cohort_sizes.cohort_week

)

select * from final
