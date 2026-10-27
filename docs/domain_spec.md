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
| Product | products.product_id = GA4 items.item_id where present; item_name is kept as the display name, item_category as the category. | GA4's items carry an id; inventing a second one would create a mapping problem with no analytical value. GA4 item_id is already SKU grain (one id per size, e.g. three ids for the Navy Crewneck Sweatshirt), so it is the product key as-is. item_id is stable over the window (one id never changes name except one spelling variant); products keys on it. (q10) |tem_id is stable over the window (one id never changes name except one spelling variant); products keys on it. (q10) |tem_id is stable over the window (one id never changes name except one spelling variant); products keys on it. (q10) |tem_id is stable over the window (one id never changes name except one spelling variant); products keys on it. |

- Open question: Do GA4 item ids change over the 92 days for the same name?
- Answer: item_id is a stable key. 154 ids out of a few hundred drift, and almost all of it is one pattern: the second “category” is an empty string, not a different category. So that’s a null-handling issue, not a key problem. The one real rename is 9200364 (the Shoreline bottle, two name spellings) - See [q10](ga4_queries.sql)

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

## 5. Returns and refunds
- Two tables not folded into status events:
### Returns

| return_id | order_id | order_item_id (nullable: whole-order return) | requested_at | reason | accepted |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |
### Refunds

| refund_id | order_id | return_id (nullable: cancellation refund) | amount | currency | refunded_at |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |

- Two tables not folded into status events because: a return is a request that can be refused, a refund is money; they have different grains and different owners, and fct_returns in Week 8 needs reasons and acceptance, which a status event does not carry.
- Also, one of the tests planned "a refund never exceeds the order value" needs refunds.amount to exist as its own column.

## 6. What is seeded from GA4
### The seeding map and shares

| Table | From GA4 | Generated independently | Target share |
| --- | --- | --- | --- |
| orders | Deduplicated purchase events with a usable transaction id: id, timestamp, user, revenue, currency | Payment method, shipping country, discount, status; backend-only orders (phone, app, ad-blocked) | ~90% seeded / ~10% backend-only. Separately, ~5% of GA4 purchases get no order (payment failed) |
| order_items | items[] on seeded purchases: product, quantity, price | Lines for backend-only orders | Follows orders |
| products | Distinct items in GA4 | Cost price (what Fennmark pays the supplier) = 40–70% of the selling price (GA4 items.price), supplier, launch date | 100% of GA4 items; no invented products |
| customers  | Distinct purchasing user_pseudo_id | Name, country, email consent, acquisition date; customers behind backend-only orders | ~90% seeded |
| marketing_spend | traffic_source.source / medium values and their daily session counts, as the shape to spend against | Daily spend per channel | 100% generated, shaped by GA4 |
| experiment_assignments | Users with view_promotion events | Variant assignment | See section 8 below |
| order_status_events, returns, refunds, nps_surveys | Nothing  | Everything, from the lifecycle in section 4 | 100% generated |

### Time window
- GA4 covers 2020-11-01 to 2021-01-31.
- Orders placed on 31 January are still being shipped, delivered, returned and refunded in February and March.
- As a result, backend events run to 2021-03-15; the reporting period in marts is 2020-11-01 to 2021-01-31 by order date; status events after 31 January are kept so that order status is correct as of any date.

### Currency
- GA4 purchase_revenue in the sample is USD.
- The backend's base currency is USD, orders carries a currency column, and a handful of orders will deliberately say EUR (Section 7).

## 7. Planned data problems

| Layer | Problem | Table | How injected (Week 4) | Detected / handled in |
| --- | --- | --- | --- | --- |
| Real GA4 | Duplicate purchase events per transaction (~324) | GA4 events | Already there | Week 6: stg_ga4__purchases dedups, first event wins; unique test on transaction_id |
| Real GA4 | (not set) transaction ids (15.5% of purchases) | GA4 events | Already there | Week 6: excluded from stg_ga4__purchases, counted in reconciliation as unmatchable |
| Real GA4 | user_id never populated | GA4 events | Already there | Week 7: stitching is cookie → customer; documented limitation |
| Real GA4 | item_name / item_category vary for the same item_id (empty strings, one rename, navigation labels like “Shop by Brand”, “Campus Collection” and “New” as category) | GA4 events | Already there | Week 5/6: products takes the most frequent non-empty name and category per id; unique + not_null tests on product_id; navigation labels mapped to a real category per item_id by a small seed file |
| Real GA4 | 448 purchase events with no order data (items array is one (not set) placeholder, NULL price/quantity, transaction id (not set)) | GA4 events | Already there | Week 6: excluded from stg_ga4__purchases and stg_ga4__purchase_items; Week 7: counted as “GA4 purchase with no order data” |
| Reconciliation | GA4 purchases with no backend order (~5%) | orders | Generator skips them: payment declined before the order was created | Week 7: reconciliation category GA4-only; dashboard Week 12 |
| Reconciliation | Backend orders GA4 never saw (~10%) | orders | Generated with B- ids | Week 7: category backend-only |
| Reconciliation | GA4 revenue ≠ backend revenue on matched orders | orders | Discounts applied after the event; rounding | Week 7: revenue delta column; Week 15 case-study trade-off |
| Backend mess | Duplicate customer rows (same cookie, two ids) | customers | ~2% of customers duplicated with a later created_at (a created_at later than the original) | Week 5: dedup in staging, keep earliest; unique test on user_pseudo_id |
| Backend mess | Late-arriving status events | order_status_events | loaded_at 1-3 days after event_timestamp for ~10% of events | Week 9: incremental lookback window; test that status never regresses |
| Backend mess | Mixed timestamp formats | order_status_events | Column exported as string; two formats, one with offset | Week 5: safe.parse_timestamp with both formats; not_null test after parsing |
| Backend mess | NULL consent flags | customers | ~15% NULL in email_consent | Week 5: cast to boolean, keep NULL; accepted_values test; marts treat NULL as not consented |
| Backend mess | Currency mismatch | orders | ~20 orders with currency = 'EUR' | Week 5: flag column; Week 10 singular test that revenue is reported in one currency |
| Backend mess | Mid-history schema change | orders | ship_country renamed to shipping_country from 2021-01-01 (two raw files) | Week 5: coalesce in staging; documented in sources.yml |
| Backend mess | Refunds for orders never delivered or cancelled | refunds | ~1% of refunds reference an order in shipped | Week 10: singular test; surfaces as a data-quality metric, not silently dropped |

- The ~ figures are targets for the generator, not promises. 

## 8. Experiment Design

| Element | Decision | Because |
| --- | --- | --- |
| Hypothesis | Showing the promotion banner variant B (bigger discount badge) increases purchase conversion among users who see a promotion | One metric, one direction |
| Unit of assignment | user_pseudo_id | The only stable id in GA4; a user keeps one variant across sessions |
| Population | Users with at least one view_promotion event in the window | No exposure, no assignment; keeps the readout honest |
| Split | 50 / 50, assigned by hashing the cookie id with the fixed seed | Reproducible from the generator's seed |
| Primary metric | Purchase conversion within 7 days of first exposure (any order, GA4 or backend) | Orders are the system of record; 7 days covers the sample's typical consideration time |
| Guardrail | Return rate within 30 days | A bigger badge that increases returns is not a win |
| Injected effect | +1.5 percentage points absolute on conversion for B; no effect on return rate | Big enough to detect at the sample's size, small enough to need a confidence interval; Week 13 checks the sample-size maths |
| Duration | Entire GA4 window; assignment timestamp = first Entire GA4 window; assignment timestamp = first exposure | The readout filters by exposure date |

- **Why a 50/50 split, not exposed vs. unexposed.** The design is: everyone in the population saw a promotion banner. Half were shown the existing one (control, variant A), half the new one with the bigger badge (treatment, variant B). Because the assignment is random, the two halves are alike in every way except the banner, so any difference in conversion is the banner’s effect. 50/50 is simply the split that gives the most statistical power for a given number of exposed users; you’d only go unequal if the treatment was risky and you wanted to limit exposure. That’s also why the population is “users with at least one view_promotion”: in GA4 terms that event is the exposure, and assignment happens at the moment of first exposure.

- **Why a guardrail.** A guardrail is a second metric to watch, not to win on, but to make sure the win isn’t fake. The primary metric says whether variant B sells more; the guardrail says whether it does so by causing harm somewhere else. Here it’s the 30-day return rate: a louder discount badge could push people into impulse orders they then send back, so conversion goes up, returns go up, and net revenue is flat or worse. The decision rule is “ship B if conversion rises and return rate doesn’t”, and the Week 13 memo reports both.

- **Injected effect.** Because the backend is generated, there’s no real banner effect to discover; the generator has to put one in. “Injected effect: +1.5 percentage points” means the generator gives treatment users a conversion probability 1.5 pp higher than control (say 3.5% vs 2.0%), and leaves the return rate identical in both groups so the guardrail stays clean. The Week 13 readout then has a known answer to check itself against: if the analysis finds roughly +1.5 pp with a confidence interval that excludes zero, the statistics are right. It’s chosen small enough that you need a proper test to see it, not so small that the sample can’t detect it. The README states plainly that the effect is injected, which is the honesty test.

- **Limitation.** The effect is injected into the generated backend orders, not into GA4 behaviour, so the readout tests the statistics, not a real finding. The README (Week 14) says so.

## 9. Business questions

- Week 8's done-when is "each mart answers one written business question". Writing the questions now, before any model exists, is what keeps the marts honest. One question per planned mart; a question is good when the answer is a number with a breakdown and a time period.

| Mart (Week 8) | Question |
| --- | --- |
| fct_orders | What were net revenue and order count per week by channel, and what share of orders did GA4 miss? |
| fct_order_items | Which products and categories carry the margin, and which sell volume at low margin? |
| dim_customers | What share of customers in the period are repeat buyers, and how many consented to email? |
| dim_products | How many products were launched in the window, and how long until first sale? |
| fct_sessions | What is the view-to-purchase funnel by device category, and where is the biggest drop? |
| fct_returns | What is the return rate by product category and channel, and what are the top reasons? |
| fct_nps | What is NPS by delivery month, and does it move with shipping time? |
| Reconciliation (Week 7) | For the period, how many orders are matched, GA4-only and backend-only, and what is the revenue gap on matched orders? |

- **Reconciliation.** The last row in the table isn’t a mart; it’s the Week 7 intermediate model that compares the two sources order by order. It takes every deduplicated GA4 purchase and every backend order, joins them on transaction_id = order_id, and sorts the result into three buckets: matched (in both), GA4-only (purchase event, no order: payment failed), backend-only (order, no event: phone, app, ad blocker). For matched orders it also computes the revenue difference, which is rarely zero (discounts after the event, item_revenue vs gross, rounding).
- The business question for it is therefore: how many orders fall in each bucket, and how big is the revenue gap on matched orders? It’s the one answer to the question that frequently arise when finance and marketing report different numbers.

## 10. Out of scope
- Inventory and stock levels
- Multi-currency conversion
- Customer support tickets
- Product reviews
- Multi-touch attribution
- product_variants dimension: not needed, GA4 item_id is already SKU grain; revisit only if per-variant stock is modelled.
- Checkout and web errors: not an order-system concern; the sample has no exception events, so begin_checkout without purchase in fct_sessions is the only abandonment proxy.