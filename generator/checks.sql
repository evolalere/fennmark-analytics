-- 1. schema change: both country columns exist, each NULL exactly where the other is filled
SELECT COUNTIF(ship_country IS NULL AND placed_at < '2021-01-01') AS bad_2020,
       COUNTIF(shipping_country IS NULL AND placed_at >= '2021-01-01') AS bad_2021,
       COUNT(*) AS orders
FROM `fennmark-analytics.fm_raw.orders`;                       -- 0, 0, 5458

-- 2. foreign keys: every count = 0
SELECT 'orders.customer_id' AS fk, COUNT(*) AS orphans
FROM `fennmark-analytics.fm_raw.orders` o LEFT JOIN `fennmark-analytics.fm_raw.customers` c USING (customer_id) WHERE c.customer_id IS NULL
UNION ALL SELECT 'order_items.order_id', COUNT(*)
FROM `fennmark-analytics.fm_raw.order_items` i LEFT JOIN `fennmark-analytics.fm_raw.orders` o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT 'order_items.product_id', COUNT(*)
FROM `fennmark-analytics.fm_raw.order_items` i LEFT JOIN `fennmark-analytics.fm_raw.products` p USING (product_id) WHERE p.product_id IS NULL
UNION ALL SELECT 'order_status_events.order_id', COUNT(*)
FROM `fennmark-analytics.fm_raw.order_status_events` e LEFT JOIN `fennmark-analytics.fm_raw.orders` o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT 'returns.order_id', COUNT(*)
FROM `fennmark-analytics.fm_raw.returns` r LEFT JOIN `fennmark-analytics.fm_raw.orders` o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT 'refunds.return_id', COUNT(*)
FROM `fennmark-analytics.fm_raw.refunds` f LEFT JOIN `fennmark-analytics.fm_raw.returns` r USING (return_id) WHERE f.return_id IS NOT NULL AND r.return_id IS NULL
UNION ALL SELECT 'nps_surveys.order_id', COUNT(*)
FROM `fennmark-analytics.fm_raw.nps_surveys` s LEFT JOIN `fennmark-analytics.fm_raw.orders` o USING (order_id) WHERE o.order_id IS NULL;

-- 3. problem ledger
SELECT 'backend-only orders' AS problem, COUNTIF(order_id LIKE 'B-%') AS n, ROUND(COUNTIF(order_id LIKE 'B-%') / COUNT(*), 3) AS share FROM `fennmark-analytics.fm_raw.orders`
UNION ALL SELECT 'discounted orders', COUNTIF(discount_amount > 0), ROUND(COUNTIF(discount_amount > 0) / COUNT(*), 3) FROM `fennmark-analytics.fm_raw.orders`
UNION ALL SELECT 'EUR orders', COUNTIF(currency = 'EUR'), NULL FROM `fennmark-analytics.fm_raw.orders`
UNION ALL SELECT 'duplicate customers', COUNT(*) - COUNT(DISTINCT user_pseudo_id), NULL FROM `fennmark-analytics.fm_raw.customers` WHERE user_pseudo_id IS NOT NULL
UNION ALL SELECT 'NULL consent', COUNTIF(email_consent IS NULL), ROUND(COUNTIF(email_consent IS NULL) / COUNT(*), 3) FROM `fennmark-analytics.fm_raw.customers`
UNION ALL SELECT 'ISO+offset timestamps', COUNTIF(event_ts_raw LIKE '%T%'), ROUND(COUNTIF(event_ts_raw LIKE '%T%') / COUNT(*), 3) FROM `fennmark-analytics.fm_raw.order_status_events`
UNION ALL SELECT 'late-loaded events', COUNTIF(loaded_at > COALESCE(SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', event_ts_raw), SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', event_ts_raw)) + INTERVAL 1 DAY),
       ROUND(COUNTIF(loaded_at > COALESCE(SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', event_ts_raw), SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', event_ts_raw)) + INTERVAL 1 DAY) / COUNT(*), 3)
  FROM `fennmark-analytics.fm_raw.order_status_events`
UNION ALL SELECT 'bad refunds (order still shipped)', COUNT(*), NULL
  FROM `fennmark-analytics.fm_raw.refunds` f
  JOIN (SELECT order_id, ARRAY_AGG(status ORDER BY COALESCE(SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', event_ts_raw), SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', event_ts_raw)) DESC LIMIT 1)[OFFSET(0)] AS last_status
        FROM `fennmark-analytics.fm_raw.order_status_events` GROUP BY 1) l USING (order_id)
  WHERE l.last_status = 'shipped';

-- 4. unparseable timestamps: 0 (both formats parse)
SELECT COUNT(*) AS unparseable FROM `fennmark-analytics.fm_raw.order_status_events`
WHERE COALESCE(SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', event_ts_raw), SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', event_ts_raw)) IS NULL;