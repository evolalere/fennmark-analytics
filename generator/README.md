# Column-level schemas in generator

## Note
- Every table has loaded_at. It is what Week 5's freshness checks and Week 9's incremental models key on.
- Foreign keys are written as -> table comments. Week 8's relationships tests are this list, verbatim.
- Deliberate problems are marked with <- comments so the Week 4 generator author does not forget one.
- No column exists without a consumer. If no mart, test or dashboard in the project plan reads it, it's cut out. customers.phone_number is an example.
- products.list_price vs order_items.unit_price is the per-order price point from Saturday: the same journal sold at 6.0 and 8.0 in one week, so the generator reads the price off each purchase and the product table only carries a reference. Without that split the reconciliation would show a gap nobody can explain.
- line_revenue = GA4 item_revenue, not unit_price × quantity, the other Saturday finding. Put a line in section 7 of the spec saying GA4 line revenue is item_revenue (net) and price × quantity is gross, and that the difference is one of the known reasons GA4 and backend revenue won’t match.

## orders (one row per order; seeded from GA4 purchase + backend-only)

| Column | Type | Note |
| --- | --- | --- |
| order_id | STRING | GA4 transaction_id, or 'B-' + 6 digits for backend-only |
| customer_id | STRING | -> customers |
| placed_at | TIMESTAMP UTC | = GA4 event timestamp for seeded orders |
| channel | STRING | web | app | phone (web for all seeded orders) |
| payment_method | STRING | card | paypal | invoice | giftcard |
| currency | STRING | USD, except the deliberate EUR rows |
| gross_revenue | NUMERIC | before discount, = GA4 purchase_revenue for seeded orders |
| discount_amount | NUMERIC | applied after the GA4 event (reconciliation delta) |
| ship_country | STRING | files before 2021-01-01 <- schema change |
| shipping_country | STRING | files from 2021-01-01 <- schema change |
| loaded_at | TIMESTAMP | when the row reached raw |

## order_status_events (one row per status change)

| Column | Type | Note |
| --- | --- | --- |
| event_id | STRING |  |
| order_id | STRING | -> orders |
| status | STRING | placed | paid | shipped | delivered | cancelled | returned | refunded |
| event_ts_raw | STRING | mixed: '2020-11-14 09:12:33' and '2020-11-14T09:12:33+01:00' |
| loaded_at | TIMESTAMP | 1-3 days late for ~10% of rows |

## customers  (one row per customer; ~90% seeded from purchasing user_pseudo_id)

| Column | Type | Note |
| --- | --- | --- |
| customer_id | STRING | 'C-' + 6 digits |
| user_pseudo_id | STRING | GA4 cookie id; NULL for customers behind backend-only orders |
| full_name | STRING | Faker |
| email | STRING | Faker; same email on the duplicate rows |
| country | STRING | ISO-2; = GA4 geo.country for seeded customers |
| email_consent | STRING | 'true' | 'false' | NULL (~15% NULL)   <- NULL consent flags |
| acquisition_date | DATE | date of first order |
| created_at | TIMESTAMP | ~2% of customers appear twice: same user_pseudo_id and email, new customer_id, later created_at   <- duplicate customers |
| loaded_at | TIMESTAMP |  |

## products  (one row per SKU; 100% from GA4 items, keyed on item_id)

| Column | Type | Note |
| --- | --- | --- |
| product_id | STRING | = GA4 items.item_id (already one id per size) |
| product_name | STRING | = item_name, most frequent non-empty spelling per id |
| variant | STRING | = item_variant; 'Single Option Only' kept raw, NULL in staging |
| category | STRING | = item_category as GA4 reports it, nav labels and blanks included (seed-file override happens in Week 5, not here) |
| list_price | NUMERIC | reference selling price = mode of items.price over the window; the price actually charged lives on order_items |
| cost_price | NUMERIC | 40-70% of list_price, range set per category in config.yml |
| supplier | STRING | Faker company, one per category |
| launch_date | DATE | before the product's first GA4 appearance |
| loaded_at | TIMESTAMP |  |

## order_items  (one row per product line on an order)

| Column | Type | Note |
| --- | --- | --- |
| order_item_id | STRING | order_id + '-' + line number |
| order_id | STRING | -> orders |
| product_id | STRING | -> products; NULL never occurs here (the 448 placeholder purchases are dropped before seeding) |
| quantity | INT64 | = items.quantity for seeded lines |
| unit_price | NUMERIC | = items.price on that purchase, not products.list_price |
| line_revenue | NUMERIC | = items.item_revenue for seeded lines (net of line discount; not always unit_price × quantity) |
| loaded_at | TIMESTAMP |  |

## returns  (one row per return request; delivered orders only)

| Column | Type | Note |
| --- | --- | --- |
| return_id | STRING | 'R-' + 6 digits |
| order_id | STRING | -> orders |
| order_item_id | STRING | -> order_items; NULL = whole-order return |
| requested_at | TIMESTAMP | within 30 days of delivery |
| reason | STRING | wrong_size | damaged | not_as_described | changed_mind | other |
| accepted |  BOOL | ~85% true; refused returns produce no status event or refund |
| loaded_at | TIMESTAMP |  |

## refunds  (one row per refund payment)

| Column | Type | Note |
| --- | --- | --- |
| refund_id | STRING | 'RF-' + 6 digits |
| order_id | STRING | -> orders |
| return_id | STRING | -> returns; NULL = refund for a paid-then-cancelled order |
| amount | NUMERIC | ≤ order value; whole-order for cancellations, line value for item returns |
| currency | STRING | = orders.currency |
| refunded_at | TIMESTAMP | 1-5 days after the return acceptance or cancellation ~1% reference an order still in 'shipped'   <- bad refunds |
| loaded_at | TIMESTAMP |  |

## nps_surveys  (one row per survey response; sent after delivery)

| Column | Type | Note |
| --- | --- | --- |
| survey_id | STRING | 'S-' + 6 digits |
| order_id | STRING | -> orders (delivered only) |
| customer_id | STRING | -> customers |
| sent_at | TIMESTAMP | 2-3 days after delivery |
| responded_at | TIMESTAMP | NULL for ~60% (sent, no answer) |
| score | INT64 | 0-10; NULL when responded_at is NULL; skew lower when shipping took > 5 days |
| verbatim | STRING | short Faker sentence; NULL for ~70% of responses |
| loaded_at | TIMESTAMP |  |

## marketing_spend  (one row per day × source × medium; no natural key)

| Column | Type | Note |
| --- | --- | --- |
| spend_date | DATE | every day 2020-11-01 .. 2021-01-31 |
| source | STRING | = GA4 traffic_source.source values (google, facebook, ...) |
| medium | STRING | = GA4 traffic_source.medium (cpc, organic, referral, ...); spend is 0 for organic/referral/(none), > 0 for paid |
| campaign | STRING | = GA4 traffic_source.name; '(not set)' allowed |
| spend | NUMERIC | USD; scaled to daily session counts for that source/medium |
| loaded_at | TIMESTAMP |  |

## experiment_assignments  (one row per user × experiment; no natural key)

| Column | Type | Note |
| --- | --- | --- |
| experiment_id | STRING | 'promo_badge_v1' for the one experiment in scope |
| user_pseudo_id | STRING | users with >= 1 view_promotion event |
| variant | STRING | 'control' | 'treatment', 50/50 by hashing the id with the seed |
| assigned_at | TIMESTAMP | = first view_promotion event for that user |
| loaded_at | TIMESTAMP |  |

