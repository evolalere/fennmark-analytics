# Fennmark domain spec
Status: draft, week 3

## 1. Business and sources  
- GA4 is the web-behaviour source
- The generated backend is the system of record for orders, returns and NPS
- They meet on ecommerce.transaction_id = orders.order_id
## 2. Entities                              (A3: the entity table)

| Entity (raw table) | Grain: one row per | Key | Rows come from | Exists to answer |
| --- | --- | --- | --- | --- |
| customers | customer | customer_id | Seeded from distinct user_pseudo_id values that purchased, plus backend-only customers | Who buys, how often, and did they consent to email |
| products | SKU (a product in one size or option) | product_id = GA4 item_id | Distinct items.item_id in GA4, with item_name as the parent product name, item_variant as the size/option, item_category; plus cost, supplier, launch date | What sells, at what margin, and which sizes |
| orders | order | order_id | ~85-90% seeded from deduplicated GA4 purchase events; ~10% backend-only | Revenue, order count, channel, payment method |
| order_items | product line on an order | order_item_id | GA4 items[] on the seeded purchases; generated lines for backend-only orders | Units, line revenue, margin |
| order_status_events | status change on an order | event_id | Generated for every order from the lifecycle | Where is each order now; how long did each step take |
| returns | return request | return_id | Generated for a share of delivered orders | Return rate by product and channel, reasons |
| refunds | refund payment | refund_id | Generated for cancellations and accepted returns | Refunded value; net revenue |
| nps_surveys | survey response | survey_id | Generated after a share of deliveries | NPS by month, product and delivery time |
| marketing_spend | day × source/medium | (spend_date, source, medium) | Generated to match GA4 traffic_source values | CAC and ROAS per channel |
| experiment_assignments | user × experiment | (user_pseudo_id, experiment_id) | Generated for users with a view_promotion event | Did the promotion variant lift conversion |                (B1: state diagram, transitions, timing)

## 5. Returns and refunds                   (B3)

## 6. What is seeded from GA4               (B2: the seeding map, shares, time window)

## 7. Planned data problems                 (C1: table with detection plan)

## 8. Experiment                            (C3: the promotion A/B test)

## 9. Business questions                    (C4: one per mart)

## 10. Out of scope                         (C5)
- multi-touch attribution
- product_variants dimension: not needed, GA4 item_id is already SKU grain; revisit only if per-variant stock is modelled.