# Decisions

A short log of design decisions that changed the project's direction. One entry per decision:
context, decision, consequence. Newest at the bottom.

## 2026-10-18 · Fennmark is a direct-to-consumer merchandise brand, not a car-rental company (week 2)

**Context.** The v1 plan mapped the GA4 sample's ecommerce events onto a car-rental booking flow. Exploring the data in week 2 showed the mapping was thin: GA4 has no dates, branches or vehicles anywhere, the join to a rental backend would have been invented, and funnel steps were being renamed by storytelling. The sample is the Google Merchandise Store's own export.

**Decision.** Model the data as what it is. Fennmark is a D2C merchandise and apparel brand; GA4 is its web-behaviour source, unchanged; the generated backend is the order system behind that website, seeded from GA4 purchases (`ecommerce.transaction_id` = `orders.order_id`) and enriched with what the website cannot see: order lifecycle, returns, refunds, NPS, cost and margin, marketing spend.

**Consequence.** The join between sources is real, so GA4-versus-backend reconciliation becomes a feature of the project rather than a wart. Lifecycle, cancellation and NPS modelling carry over with renamed tables. Rental-specific metrics (stations, pick-up and return dates, no-shows) are dropped. Plan v2 records the change.

## 2026-10-27 · Order status is derived from status events, never stored on the order (week 3)

**Context.** The generator will deliver status events late (`loaded_at` 1-3 days after `event_timestamp` for ~10% of events). A `status` column on `orders` would disagree with the event history as soon as an event arrived late, and there would be no way to say what an order's status was on a given date.

**Decision.** `orders` carries no status column. An order's status at time T is the state of its latest status event with `event_timestamp` ≤ T; its current status is its latest event overall. Allowed and illegal transitions are listed in `domain_spec.md` section 4. Cancellation and
return reasons live on the event (`reason`), not on the order.

**Consequence.** Late events are a modelling problem with a correct answer, not a data corruption: Week 9's incremental lookback window re-derives status once they land. Week 10's singular tests check the illegal transitions directly. `fct_orders` (Week 8) gets a denormalised `current_status` computed from events, which is the only place a status column appears.

## 2026-11-05 · Product category is a curated seed, not the GA4 breadcrumb (week 5)

**Context.** GA4's `item_category` is the navigation path the shopper came through, not a product taxonomy: the same SKU appears under `Home/Apparel/Men's / Unisex/`, `New`, `Sale`, `Campus Collection` and an empty string. The generator kept the modal raw value per SKU, which left navigation labels, audience segments and pricing states mixed in with real categories.

**Decision.** `stg_backend__products` maps the raw value to one canonical category through the `product_category_overrides` seed (raw-value rows for the bulk, per-SKU rows for the cases a value cannot settle; per-SKU wins). The list is Apparel, Drinkware, Bags, Accessories, Stationery, Lifestyle, Electronics, Gift Cards and Other. The rule: a category is what the product is, one per product, the thing margin is reported by. Audience segments (Men's, Women's, Kids), pricing and time states (New, Sale, Clearance), collections and attributes (Campus Collection, Eco-Friendly) and catch-all shop sections (Small Goods, Uncategorized Items) are not categories. Office merges into Stationery. Gift Cards stays separate because it has no cost of goods and no returns. The raw value is kept beside the canonical one as `raw_category`.

**Consequence.** `dim_products` and every margin and return-rate breakdown use one stable category per SKU, with an `accepted_values` test on the list. The mapping is reference data a human maintains in version control, visible in a pull request, rather than logic buried in SQL. Anything the seed does not cover lands in Other, and the share of Other is the health check for the seed. If segments or sale state are ever needed analytically, they become separate attributes, not category values.