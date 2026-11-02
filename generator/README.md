# Column-level schemas in generator

## How to run

    source .venv/bin/activate
    pip install -r generator/requirements.txt
    python generator/generate.py            # extract (cached), build, write CSVs, load to fm_raw
    python generator/generate.py --no-load  # write CSVs only

First run executes four aggregate queries against the GA4 public sample (a few GB scanned in total, once) and caches them as parquet in `generator/cache/`; later runs read the cache and never touch GA4. Runtime: ~1 minute with a warm cache. The load truncates and rebuilds every table in `fm_raw`. Two runs with the same seed produce byte-identical `generator/output/*.csv` (verified with md5sum). Seed, shares and lags live in `generator/config.yml`.

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
| status | STRING | placed, paid, shipped, delivered, cancelled, returned, refunded |
| event_ts_raw | STRING | mixed: '2020-11-14 09:12:33' and '2020-11-14T09:12:33+01:00' |
| reason | STRING | NULL except on cancelled and returned. Cancelled: payment_failed, customer_request, out_of_stock, fraud_check. Returned: wrong_size, damaged, not_as_described, changed_mind (= returns.reason, copied onto the event) |
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

## Catalogue (week 4 extract)

The `items` extract keys on GA4 `item_id`, which is SKU grain (one id per size or option), so its counts differ from the product-name counts in `docs/ga4_notes.md`:

| Measure | Count | Week 2 equivalent |
| --- | --- | --- |
| SKUs (distinct `item_id` on view_item or purchase) | 1,231 | n/a: Week 2 counted names |
| SKUs sold at least once | 809 | 396 product names bought (~2 sizes per product) |
| Distinct product names | 428 | 422 viewed; the extra are spelling variants across ids (q10) |
| SKUs viewed but never sold | 422 | n/a |

- All 1,231 SKUs go into `products`; the 422 never sold are what dim_products' time-to-first-sale question needs. Source extract: 4,451 identifiable purchases, 13,218 purchase lines (after dropping the placeholder lines and `(not set)` ids); 354,857 sessions by source/medium/campaign (917 rows); 102,443 promotion-exposed users.
- NULLs in products: variant 157, category and supplier 6 (SKUs with no non-empty value on any event).

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
| reason | STRING | wrong_size, damaged, not_as_described, changed_mind |
| accepted | BOOL | ~85% true; refused returns produce no status event or refund |
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

## Further notes
### Known reasons GA4 and backend revenue do not reconcile

Measured on the week 4 run (seed 20201101). None of these are bugs; each is a documented gap the `rec_ga4_vs_backend` model in week 7 must account for, in this order.

1. **GA4 line revenue is not price × quantity.** On the GA4 side, `item_revenue` is net of line-level discounts and rounding, while `price` is a whole-dollar unit price. `order_items.line_revenue` carries `item_revenue` unchanged; `unit_price × quantity` is the gross line value. Both are kept so the gap is visible, not hidden.
2. **GA4 order revenue is not the sum of its lines.** 18.5% of GA4-seeded orders have `SUM(item_revenue) ≠ purchase_revenue` in the source data itself (tax, shipping and rounding on Google's side). `orders.gross_revenue` is `purchase_revenue`; the line sum is what `order_items` adds up to. This gap exists before the generator touches anything.
3. **Backend discounts applied after the GA4 event.** 14.9% of seeded orders carry a `discount_amount` (5-15% of gross) that GA4 never saw. Net backend revenue = `gross_revenue − discount_amount`; GA4 reports gross.
4. **Orders GA4 never saw.** 421 backend-only orders (`B-` ids, phone and app channel, 9.1% of orders) have no GA4 purchase; they are backend-only in the reconciliation.
5. **GA4 purchases that never became orders.** 239 identifiable GA4 purchases (5.4%) were declined at payment; their ids are in `output/_ga4_only_ids.csv` (not loaded). Together with the 883 purchases with no `transaction_id` they form the GA4-only bucket.
6. **Currency mismatch.** 20 orders are flagged `EUR` with USD amounts unchanged; a naive sum mixes currencies.
7. **Same SKU at different prices in the same week.** `products.list_price` is the modal price; the price actually charged is on `order_items.unit_price`. Reconciling against list price produces an unexplained gap; reconcile against `unit_price`.

Expected outcome in week 7: matched orders reconcile exactly on gross once (2) is accepted as a source-side gap, and the remaining delta is fully explained by (3)-(6).

### Customers
- 72 duplicate customer rows; only 3 orders attributed to the duplicate, since repeat buying is rare in the window.

### Generated figures worth knowing (week 4 run, seed 20201101)

These are properties of the generated backend, not findings about any real business. They are listed so that the marts in weeks 6-8 can be checked against what was put in.

- **NPS overall: +7** (4,195 surveys sent, 40% responded). The score is generated with shipping time and returns as drivers: orders delivered more than 5 days after shipping draw from a detractor-heavy band, and a return requested before the response shifts it further. The peak-season shipping lag (7-23 Dec) therefore pulls December NPS down; `fct_nps` should be able to show NPS by delivery-time bucket and by month, and the December dip is the expected answer.
- **Lifecycle:** 346 cancelled (7.5%; 5% unpaid, the rest after payment), 4,195 delivered, ~2% stuck at shipped at window end.
- **Returns:** 358 (8.5% of delivered), 85% accepted; reasons weighted by category (wrong_size for apparel, damaged for drinkware).
- **Refunds:** 441, of which 4 are deliberately bad (refund on an order whose latest status is shipped, no return, no status event).
- **Duplicate customers:** 72 rows; only 3 orders attributed to the duplicate, since repeat buying is rare in the window.
- **Marketing spend** $27,620 over 92 days (~9% of gross revenue), 10% of source/medium/campaign rows paid, rest zero (organic, direct, (data deleted)).

- **Final run:** NPS +6 (4,918 surveys), 428 cancelled, 4,918 delivered, 373 returns (84% accepted), 456 refunds incl. 5 bad, marketing spend $28,452 (~9% of gross revenue).

### Problem ledger (week 4 run, seed 20201101)

Verified in BigQuery with `generator/checks.sql` after the load. Targets are from `docs/domain_spec.md` section 7; achieved figures are what the generator produced.

| Problem | Table | Target | Achieved | Check |
| --- | --- | --- | --- | --- |
| GA4 purchases with no backend order | orders | ~5% | 239 of 4,451 (5.4%) | `output/_ga4_only_ids.csv` (not loaded; week 7 answer key) |
| Backend orders GA4 never saw | orders | ~10% | 1,246 (22.8%) | `order_id LIKE 'B-%'`. 10% regular phone/app orders plus 825 forced A/B treatment conversions, see below |
| GA4 revenue ≠ backend revenue | orders, order_items | ~15% discounted | 628 (11.5% of all orders; 14.9% of GA4-seeded) | `discount_amount > 0`. Backend-only orders carry no discount, which dilutes the share. Plus 18.5% of seeded orders where line sum ≠ gross in GA4 itself |
| Duplicate customers | customers | ~2% | 73 rows (7 orders re-pointed) | `user_pseudo_id` with more than one row |
| NULL consent | customers | ~15% | 711 (15.1%) | `email_consent IS NULL` |
| Late-arriving status events | order_status_events | ~10% | 2,226 (10.2%) | `loaded_at > event_ts + 1 day` |
| Mixed timestamp formats | order_status_events | ~10% | 2,176 (10.0%) ISO+offset; 0 unparseable | `event_ts_raw LIKE '%T%'`; both formats parse with the week 5 expression |
| Currency mismatch | orders | 20 | 20 | `currency = 'EUR'`, amounts unchanged |
| Mid-history schema change | orders | all rows | 4,263 `ship_country` / 1,195 `shipping_country`, 0 mismatched | each column NULL exactly where the other is filled |
| Bad refunds | refunds | ~1% | 5 | refund on an order whose latest status is `shipped`, no return, no status event |
| Injected A/B effect | experiment_assignments, orders | +1.5 pp | control 2.66%, treatment 4.15% (+1.49 pp) | 7-day conversion after first `view_promotion`, 102,443 users |

Foreign keys (orders→customers, order_items→orders/products, order_status_events→orders, returns→orders, refunds→returns, nps_surveys→orders): 0 orphans each.

**About the A/B effect.** The lift is injected: 825 treatment users who never bought were given a backend-only (phone/app) order within 7 days of exposure, since GA4 purchase events cannot be generated. The readout in week 13 must therefore count conversions from `orders`, not from GA4 purchases, and the lift appearing only in non-web channels is a known tell that the effect is synthetic. Control conversion was left untouched (2.65% before, 2.66% after).

**Monetary columns** are FLOAT64 in raw (the generator loads pandas floats); staging casts to NUMERIC.

### Fixes
- 2026-11-02: order_items.loaded_at added (= its order’s loaded_at); only order_items.csv hash changed, verified against the Week 4 run.