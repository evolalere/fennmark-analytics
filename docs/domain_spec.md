# Fennmark domain spec
Status: draft, week 3

## 1. Business and sources  
- GA4 is the web-behaviour source
- The generated backend is the system of record for orders, returns and NPS
- They meet on ecommerce.transaction_id = orders.order_id
## 2. Entities

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

## 3. Identity rules

| Identity | Rule | Because |
| --- | --- | --- |
| Customer | customers.customer_id is a generated surrogate; customers.user_pseudo_id holds the GA4 cookie id it was seeded from (NULL for backend-only customers). One cookie (user_pseudo_id) maps to at most one customer in the generator; Week 7 stitching goes cookie → customer. | user_id is 0% populated in the sample, so the cookie is the only identifier GA4 offers. Saying "at most one" now is what makes the duplicate-customer problem in C1 a deliberate injection rather than an accident. |
| Order | orders.order_id = GA4 ecommerce.transaction_id for seeded orders; backend-only orders get ids in the same format with a distinguishable prefix (e.g. B-). | The join must need no mapping table. The prefix lets Week 7's reconciliation count GA4-only, matched and backend-only without a flag column. |
| Product | products.product_id = GA4 items.item_id where present; item_name is kept as the display name, item_category as the category. | GA4's items carry an id; inventing a second one would create a mapping problem with no analytical value. GA4 item_id is already SKU grain (one id per size, e.g. three ids for the Navy Crewneck Sweatshirt), so it is the product key as-is. |

- Open question: Do GA4 item ids change over the 92 days for the same name?

## 4. Order lifecycle
### State diagram

```
        placed      ->      paid        ->      shipped     ->      delivered           happy path
        placed      ->      cancelled                                                   never paid: no refund
        paid        ->      cancelled   ->      refunded                                cancelled before shipping
        delivered   ->      returned    ->      refunded                                return within 30 days of delivery

        Terminal states: delivered (closed), cancelled (unpaid), refunded.
```

### Transitions
| From | To | Typical lag (generator) | Who triggers it | Notes |
| --- | --- | --- | --- | --- |
| (none) | placed | = GA4 purchase timestamp for seeded orders | customer | The only event every order has |
| placed | paid | 0-30 min; ~5% never pay | payment provider | Unpaid orders are cancelled after 48 h |
| paid | shipped | 1-3 days | warehouse  | Longer in the December peak |
| shipped | delivered | 2-7 days | carrier | Delivery date drives NPS send |
| placed / paid | cancelled | before shipped only | customer or system | Cancelling after shipping is not allowed; becomes a return. Unpaid orders are cancelled after 48 h; cancellation carries a reason (payment_failed, customer_request, out_of_stock, fraud_check) |
| delivered | returned | within 30 days | customer | Only delivered orders can be returned |
| cancelled (paid) / returned | refunded | 1-5 days | finance | Refund value ≤ order value, always |

### Status rule (timing)
- an order's status at time T is the state of its latest status event with event_timestamp ≤ T; its current status is the state of its latest event overall.
- Every status event has a nullable reason; it is populated on cancelled and returned and NULL otherwise.

### Illegal transitions
-   The generator never produces these, and Week 10 tests that the data never contains them:

| From | To | Why it is illegal |
| --- | --- | --- |
| shipped, delivered | cancelled | Once shipped, the customer must return it; cancellation is pre-shipment only |
| placed, paid, shipped | returned | Only delivered orders can be returned |
| placed (unpaid) | refunded | Nothing was paid, so nothing is refunded |
| refunded | any state | Refunded is terminal |
| delivered | any state except returned | Delivered is terminal unless a return is requested |
| any state | placed | Placed is the first event and happens once |

## 5. Returns and refunds                   (B3)

## 6. What is seeded from GA4               (B2: the seeding map, shares, time window)

## 7. Planned data problems                 (C1: table with detection plan)

## 8. Experiment                            (C3: the promotion A/B test)

## 9. Business questions                    (C4: one per mart)

## 10. Out of scope                         (C5)
- multi-touch attribution
- product_variants dimension: not needed, GA4 item_id is already SKU grain; revisit only if per-variant stock is modelled.