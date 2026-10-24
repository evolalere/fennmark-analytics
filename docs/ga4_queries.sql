

-- q1_volume: rows per shard and the date range
SELECT COUNT(*) AS events,
MIN(_TABLE_SUFFIX) AS first_day,
MAX(_TABLE_SUFFIX) AS last_day,
COUNT(DISTINCT _TABLE_SUFFIX) AS shards
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;

-- q2_events_per_day
SELECT PARSE_DATE('%Y%m%d', event_date) AS event_day,
COUNT(*) AS events,
COUNT(DISTINCT user_pseudo_id) AS users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY event_day
ORDER BY event_day;

-- q3_event_types
SELECT event_name,
COUNT(*) AS events,
COUNT(DISTINCT user_pseudo_id) AS users,
ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY event_name
ORDER BY events DESC;

-- q5_users
SELECT 
COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
COUNT(DISTINCT user_id) AS logged_in_users,
COUNTIF(user_id IS NOT NULL) / COUNT(*) AS share_events_with_user_id,
COUNT(DISTINCT CONCAT(user_pseudo_id, '-', (
SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
))) AS sessions
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;

-- q5_pseudo_users_and_event_count
SELECT 
       COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
       COUNT(*)                       AS events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
;

-- q5_pseudo_users across user_first_touch_timestamp
SELECT 
user_first_touch_timestamp,
COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
COUNT(DISTINCT user_id) AS logged_in_users,
COUNTIF(user_id IS NOT NULL) / COUNT(*) AS share_events_with_user_id,
COUNT(DISTINCT CONCAT(user_pseudo_id, '-', (
SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
))) AS sessions
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY user_first_touch_timestamp
ORDER BY pseudo_users DESC;

-- q5_pseudo_users with/without NULL user_first_touch_timestamp
SELECT user_first_touch_timestamp IS NULL AS first_touch_missing,
       COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
       COUNT(*)                       AS events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY 1;

-- q5_users_device
SELECT device.category,
COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
COUNT(DISTINCT user_id) AS logged_in_users,
COUNTIF(user_id IS NOT NULL) / COUNT(*) AS share_events_with_user_id,
COUNT(DISTINCT CONCAT(user_pseudo_id, '-', (
SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
))) AS sessions
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY device.category 
ORDER BY pseudo_users DESC;

-- q5_pseudo_users_by_country
SELECT 
geo.country,
COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
COUNT(DISTINCT user_id) AS logged_in_users,
COUNTIF(user_id IS NOT NULL) / COUNT(*) AS share_events_with_user_id,
COUNT(DISTINCT CONCAT(user_pseudo_id, '-', (
SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
))) AS sessions
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY geo.country 
ORDER BY pseudo_users DESC;

-- q5_pseudo_users_by_city
SELECT 
geo.city,
COUNT(DISTINCT user_pseudo_id) AS pseudo_users,
COUNT(DISTINCT user_id) AS logged_in_users,
COUNTIF(user_id IS NOT NULL) / COUNT(*) AS share_events_with_user_id,
COUNT(DISTINCT CONCAT(user_pseudo_id, '-', (
SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
))) AS sessions
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY geo.city
ORDER BY pseudo_users DESC;

-- q6_purchases
SELECT PARSE_DATE('%Y%m%d', event_date) AS event_day,
COUNT(*) AS purchase_events,
COUNT(DISTINCT ecommerce.transaction_id) AS transactions,
ROUND(SUM(ecommerce.purchase_revenue), 2) AS revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
GROUP BY event_day
ORDER BY event_day;
-- ecommerce.transaction_id is essentially empty in early November. The “1” per day is almost certainly the single value (not set), and the 0 on 1 Nov means it’s NULL on every purchase that day. So for this period (early November) GA4 has purchase events but no order id.

-- q6_purchases_data_summary
SELECT FORMAT_DATE('%Y-%m', PARSE_DATE('%Y%m%d', event_date)) AS month,
       COUNT(*) AS purchase_events,
       COUNTIF(ecommerce.transaction_id IS NULL)        AS ecom_id_null,
       COUNTIF(ecommerce.transaction_id = '(not set)')  AS ecom_id_not_set,
       COUNT(DISTINCT IF(ecommerce.transaction_id NOT IN ('(not set)'), ecommerce.transaction_id, NULL)) AS ecom_real_ids,
       COUNT(DISTINCT (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'transaction_id')) AS param_ids
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
GROUP BY month ORDER BY month;

|  | Nov | Dec | Jan | Total |
| --- | --- | --- | --- | --- |
| purchase events | 2,054 | 2,434 | 1,204 | 5,692 |
| events with a real id | 1,542 | 2,340 | 904 | 4,786 |
| distinct real ids | 1,258 | 2,310 | 894 | 4,462 |
| duplicate events | ~284 | ~30 | ~10 | ~324 |
| (not set) | 489 | 94 | 300 | 883(15.5%) |
| NULL | 23 | 0 | 0 | 23 |

-- about 4,460 real orders over 92 days, duplicates concentrated in November
-- 15.5% of purchases carry no usable id
-- event_params.transaction_id adds only 4 extra ids, so COALESCE(ecommerce.transaction_id, param) is worth using but won’t rescue the (not set) ones

-- q6b_duplicate_purchases: the sample contains repeated purchase events per transaction
SELECT ecommerce.transaction_id, COUNT(*) AS n
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
GROUP BY 1 HAVING n > 1
ORDER BY n DESC LIMIT 20;

-- q7_param_keys: which keys exist, for which events, and which value column they use
SELECT event_name, ep.key,
COUNTIF(ep.value.string_value IS NOT NULL) AS as_string,
COUNTIF(ep.value.int_value IS NOT NULL) AS as_int,
COUNTIF(ep.value.float_value IS NOT NULL) AS as_float,
COUNTIF(ep.value.double_value IS NOT NULL) AS as_double
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
UNNEST(event_params) AS ep
WHERE _TABLE_SUFFIX BETWEEN '20210101' AND '20210107'
GROUP BY 1, 2
ORDER BY 1, 2;

-- q7b_flatten: one row per event with the params you will keep (the week 6 pattern)
SELECT
PARSE_DATE('%Y%m%d', event_date) AS event_day,
TIMESTAMP_MICROS(event_timestamp) AS event_ts,
user_pseudo_id, event_name,
(SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
(SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS ga_session_number,
(SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
(SELECT value.int_value FROM UNNEST(event_params)
WHERE key = 'engagement_time_msec') AS engagement_time_msec,
device.category AS device_category,
traffic_source.source, traffic_source.medium
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20210101' AND '20210107'
LIMIT 100;

-- q8_items_catalogue: products and categories actually bought
SELECT COUNT(DISTINCT i.item_name)     AS items,
       COUNT(DISTINCT i.item_category) AS categories
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
     UNNEST(items) AS i
WHERE event_name = 'purchase';
-- 396 items, 22 categories

-- q8b_items_viewed: products and categories viewed, and obfuscated names
SELECT COUNT(DISTINCT i.item_name)        AS items,
       COUNT(DISTINCT i.item_category)    AS categories,
       COUNTIF(i.item_name = '(not set)') AS not_set
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
     UNNEST(items) AS i
WHERE event_name = 'view_item';
-- 422 items, 75 categories, 9 not-set rows

-- q8c_item_category_values: why 75 categories on views vs 22 on purchases
SELECT i.item_category, COUNT(*) AS item_rows
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
     UNNEST(items) AS i
WHERE event_name = 'view_item'
GROUP BY 1
ORDER BY 2 DESC;

-- q9_item_variants
SELECT
  i.item_id,
  ANY_VALUE(i.item_name) AS item_name,
  COUNT(DISTINCT IF(i.item_variant != '(not set)', i.item_variant, NULL)) AS variants,
  STRING_AGG(DISTINCT IF(i.item_variant != '(not set)', i.item_variant, NULL), ', ' LIMIT 6) AS sample_variants,
  COUNTIF(i.item_variant = '(not set)') / COUNT(*) AS share_not_set
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(items) AS i
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name = 'purchase'
GROUP BY 1
ORDER BY variants DESC
LIMIT 50;

-- q10_item_ids_and_names
SELECT
  i.item_id,
  COUNT(DISTINCT i.item_name) AS names,
  COUNT(DISTINCT i.item_category) AS categories,
  STRING_AGG(DISTINCT i.item_name, ' | ' LIMIT 3) AS sample_names,
  STRING_AGG(DISTINCT i.item_category, ' | ' LIMIT 3) AS sample_categories
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
  UNNEST(items) AS i
WHERE
  _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name = 'purchase'
  AND i.item_id != '(not set)'
GROUP BY 1
HAVING names > 1 OR categories > 1
ORDER BY names DESC;