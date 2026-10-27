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