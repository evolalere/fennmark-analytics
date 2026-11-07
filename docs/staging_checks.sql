
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