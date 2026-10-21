# GA4 sample: exploration notes (week 2)

## Business framing
- GA4 is the web-behaviour source
- the generated backend is the system of record for orders, returns and NPS
- they meet on ecommerce.transaction_id = orders.order_id

## Dataset
- bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_YYYYMMDD, US multi-region
- Coverage: 2020-11-01 to 2021-01-31 (92 shards); 4,295,584 events, 270,154 pseudo-users
- Grain: one row per event; no primary key yet (at exploration), to be built in staging

## Schema cheat-sheet

### Types to cast
- event_date STRING (YYYYMMDD) -> DATE
- event_timestamp INT64 (microseconds) -> TIMESTAMP

### Three levels
- Top-level scalars: event_date, event_timestamp, event_name, event_previous_timestamp, event_value_in_usd, event_bundle_sequence_id, event_server_timestamp_offset, user_id,  user_pseudo_id,  user_first_touch_timestamp, stream_id, platform
- Nested RECORDs: privacy_info, user_ltv, device, geo, app_info, traffic_source, event_dimensions, ecommerce
- REPEATED RECORDs: event_params, user_properties, items

- HINT
- Mode Column (console’s Schema tab for events_*) -> NULLABLE + Type anything other than RECORD = top-level scalar; 
- Mode Column (console’s Schema tab for events_*) -> NULLABLE + Type RECORD = nested record; 
- Mode Column (console’s Schema tab for events_*) -> REPEATED = array (whatever the type).

## Findings (q2 to q7)
### Daily volume and seasonality
- weak days
- Weekly seasonality (Peak days - Mid week from Tuesdays to Thursdays) During the weeks leading up to Christmas - Thanksgiving, Cyber week - Tuesdays to Fridays tend to be busy.
### Event mix
- page_view, user_engagement, scroll, view_item, session_start, first_visit, view_promotion, add_to_cart, begin_checkout, select_item, view_search_results, add_shipping_info, add_payment_info, select_promotion, purchase, click, view_item_list
### Users 
- user_id almost always NULL -> stitching plan
### event_params keys we keep and their value column
| Keys | Value column |
| --- | --- |
| ga_session_id | int |
| ga_session_number | int |
| page_location | string |
| page_referrer | string |
| page_title | string |
| engagement_time_msec | int |
| session_engaged | string |
| transaction_id | string |
| value | int/double |
| currency | string |
| campaign | string |
### Unnesting (q7, q7b)
- Cross-join UNNEST (q7) multiplies rows, one per parameter; 
- Correlated subquery (q7b) keeps one row per event. 
- Week 6 will use the second.
### Items (q8, q8b, q8c)
- `items` is a top-level REPEATED column with fixed fields (item_name, item_category, price, quantity, item_revenue), separate from `event_params`; read with UNNEST(items).
- 396 distinct products bought across the period; 422 viewed. `(not set)` item names are negligible (9 item rows on view_item).
- `item_category` is NOT a product taxonomy: it is the navigation path the shopper came through (`Home/Apparel/Men's / Unisex/`, `Men's / Unisex`, `Home/Sale/`, `Home/New/` for the same product), with inconsistent trailing slashes and ~8.6k empty values. Hence 75 "categories" on views vs 22 on purchases.
- Decision: the generator's `products` table assigns one canonical category per product (most common path per item_name, with Home/, Sale, New and brand paths collapsed); `dim_products` uses that. Keep the raw path on view_item as a "found via" attribute for merchandising analysis in the funnel.

## Order funnel and what the backend will add

### Funnel table
| GA4 event | Funnel stage  | Used in |
| --- | --- | --- |     
| session_start / first_visit | Session scaffolding (new vs returning) | fct_sessions |
| view_item_list / view_search_results | 1 Browse  | funnel |
| view_item  | 2 Product view  | funnel |
| add_to_cart  | 3 Cart  | funnel |
| begin_checkout  | 4 Checkout started  | funnel |
| add_shipping_info / add_payment_info | 5 Checkout steps  | funnel (optional) |
| purchase  | 6 Order placed on the website  | stg_ga4__purchases → reconciliation with orders |
| view_promotion / select_promotion  | Promotion exposure and click  | experiment_assignments (A/B test) |

### What the backend will add
- order status lifecycle (paid, shipped, delivered, cancelled, returned, refunded), 
- cost price per product (margin),
- customer records and consent, 
- NPS after delivery, 
- marketing spend by channel,
- the orders GA4 never saw,
- During further work (CRM data via salesforce or braze and CEX data via zendesk and amazon connect) 

## Known data problems (feeds week 3 spec and week 5-6 tests)
### Users
- user_id: 0% populated (user_id is only populated when a site sends its own login ID to GA4, and the Merchandise Store sample either never did or stripped it during obfuscation, so there are no user_ids for this dataset).
- 270,154 pseudo-users, 4,295,584 events over 92 days.
- user_first_touch_timestamp NULL for 4,435 users / 86,048 events (2.0%).
- 265,721 + 4,435 = 270,156, but the true distinct count is 270,154. So 2 users appear in both groups (with and without user_first_touch_timestamp), meaning their user_first_touch_timestamp is NULL on some events and populated on others.
- Decision: derive first-seen in Week 7 as MIN(event_timestamp) per user_pseudo_id and treat the column as advisory.

### Devices
- Across devices, users don’t add up. 158,917 + 109,195 + 6,250 = 274,362, but there are 270,154 distinct users, so about 4,200 user_pseudo_ids appear under more than one device category. 
- A pseudo-ID is a per-browser cookie, so the same ID switching between desktop and mobile shouldn’t really happen; likely causes are browsers reporting different user agents (desktop-mode toggles, in-app browsers) or the obfuscation. 
- 360,129 sessions (both the sum across devices 208942 + 143185 + 8002 and the ungrouped session count), 1.33 sessions per user; device category is a clean session-level attribute (goes on fct_sessions); about 1.6% of users have sessions on more than one device type.
- Consequence for Week 7: device_category is a session-level attribute, not a user-level one, so it should be put on fct_sessions. “first seen” or “most frequent” should be taken if it's ever needed on dim_customers.

### Geo Location
- geo.country is fully populated; geo.city is "not set" for ~42% of users (obfuscation). Use country only; the generator should not derive anything from city.

### Purchase
- ids start mid-November; duplicates mostly November; 15.5% (not set).

### Items
- item_category is a breadcrumb path, not a category; canonical category must come from the backend.

## Decisions for week 3 and beyond
- stg_ga4__purchases: coalesce the two id sources, drop (not set)/NULL into a flagged “unidentified purchase” bucket, deduplicate real ids to first event. (See known data problems above and saved queries below for purchases.)
- Generator seeds orders from the ~4,460 real ids. The 883 unidentified purchases are the realistic “GA4 saw a purchase but can’t tell us which order” category in Week 7’s reconciliation; no need to invent a further 5% of failed payments on top, the data already provides it.
- The backend orders table, not GA4, is the source of truth for revenue
- GA4 revenue is whatever the customer’s browser reported at the moment of checkout, and that number is unreliable due to the known data problems above under purchase: Duplicate purchase events double-count (November especially), 15.5% of purchases have no id to attribute it to, ad blockers and closed tabs mean some orders never fire the event at all, and nothing that happens afterwards (cancellations, returns, refunds, failed payments) ever reaches GA4. 
- The order system records the money that actually moved, with its later corrections, so finance-grade metrics (revenue, margin, refund rate) come from orders, and GA4 is used for what it’s good at: how people got there and what they did before buying.
- GA4 revenue is treated as indicative only; the reconciliation model quantifies the duplicates, unidentified purchases and untracked orders.

## Open questions for week 3
1. Customers: how does the generator assign customer_id to user_pseudo_id, given user_id is never populated? One customer per pseudo-id, or merge some pseudo-ids into one customer to simulate multi-device users (~1.6% of users already span device types)?
2. Orders: which purchases become backend orders — only the ~4,460 with a real transaction_id, or also some of the 883 "(not set)" ones (with no GA4 link)?
3. Orders GA4 never saw: what share (phone, app, ad-blocked) and how are they marked?
4. Order id before mid-November: GA4 ids only start part-way through the month; does the backend have orders before that date, and if so how are they keyed?
5. Revenue: backend price = GA4 item price, or generated independently so the two never fully reconcile? Which currency, and do a few orders get a deliberate mismatch?
6. Products: canonical category per product derived from the most common breadcrumb path, or hand-assigned from the 22 purchase categories? What goes in cost price?
7. Order lifecycle: which statuses, in what order, with what typical delays (paid -> shipped -> delivered), and what share cancel, return or refund?
8. Returns and refunds: separate tables or status events? Partial refunds allowed?
9. NPS: who gets surveyed (all delivered orders? a sample?), response rate, score distribution, and does the score correlate with returns or delivery delay?
10. Marketing spend: daily by source/medium matching GA4 traffic_source values; which channels get spend and which are organic?
11. A/B test: which promotion, how is assignment tied to view_promotion/select_promotion, what split, and what effect size is baked in?
12. Deliberate mess: final list of injected problems and where each one lands (duplicate customers, late status events, mixed timestamp formats, NULL consent, currency mismatch, mid-history column rename).
13. First-touch: Week 7 derives first-seen from MIN(event_timestamp); does the backend customer table carry its own acquisition date that may disagree?

## Saved Queries
- See ga4_queries.sql
