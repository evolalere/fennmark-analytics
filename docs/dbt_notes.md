# dbt: exploration notes

## Staging conventions (week 5)

Decided once, applied to every `stg_` model:

- **One source per model.** Every staging model selects from exactly one `{{ source() }}`: no
  joins between sources, no `ref()` to another staging model, no business logic. The single
  exception is `stg_backend__products`, which `ref()`s the `product_category_overrides` seed
  (reference data, not a model).
- **One row per key, or a surrogate.** Where raw has a natural key, staging guarantees it is
  unique (customers are deduplicated). Where raw has none (marketing_spend, experiment_assignments),
  staging builds one with `dbt_utils.generate_surrogate_key`. Every key carries `unique` + `not_null`.
- **Types are fixed here, once.** FLOAT64 money -> NUMERIC; the consent STRING -> BOOL (NULL kept);
  the two-format timestamp STRING -> TIMESTAMP in UTC via `parse_mixed_timestamp`. Downstream
  models never cast.
- **House naming.** snake_case; `_at` for timestamps, `_date` for dates, `is_` / `has_` for
  booleans, `_amount` for money; ids keep their raw names.
- **Fix where cheapest, prove with a test.** Each ledger row staging owns gets one expression and
  one test that fails if the expression is removed. Problems that need another table or a business
  decision are flagged (`has_currency_mismatch`, `is_late_arriving`), not fixed.
- **Views.** Staging is `materialized: view` at the folder level; week 9 decides what becomes
  incremental.
- **Layout.** `with source as (...)`, `renamed as (...)`, `select * from renamed`; a `deduplicated`
  CTE where needed. Lowercase keywords, four-space indent, aliases aligned. The marketing_spend
  model names its first CTE `raw` because the table has a column called `source`.
- **Tests at error severity by default.** `severity: warn` only where a failure is expected and
  explained: the `relationships` tests from orders and nps_surveys to customers (7 and 5 rows that
  point at removed duplicate customers, until week 7's stitching).
- **Week 6 addenda (GA4).** (1) Views, with one exception: `stg_ga4__events` is a table
  partitioned by `event_date` and clustered by `event_name, user_pseudo_id`, because a view
  over 92 wildcard shards would re-scan the sample (~2 GB) on every downstream query and
  test; the deviation is set in the model's `config()` where it is visible. (2) Every GA4
  model filters `_table_suffix` from `ga4_start_date` / `ga4_end_date` in
  `dbt_project.yml`; nothing reads `events_*` unfiltered. (3) `ga4_event_param` is the
  only place `UNNEST(event_params)` is written. (4) Keys may be built in staging
  (`event_key`, `session_key`, `purchase_item_key`); sessionising and joining may not.
  (5) `stg_ga4__purchase_items` repeats the `stg_ga4__purchases` dedup CTEs rather than
  `ref()` them: one source per staging model holds. The `relationships` test between the
  two is a test, not a model dependency. (6) Row filters in staging are exclusions with a
  counted reason only: the 906 unidentified purchase events are excluded from the two
  purchase models and counted in *Staging checks (GA4)*; `stg_ga4__events` excludes nothing.

## Staging reconciliation targets

Expected row counts of each stg_backend__ view

| Table | Raw | Staging expected | Staging actual (2026-11-07) |
| --- | --- | --- | --- |
| customers | 4,724 | 4,651 (minus the 73 duplicates) | 4,651 |
| experiment_assignments | 102,443 | identical | 102,443 |
| marketing_spend | 917 | identical | 917 |
| nps_surveys | 4,918 | identical | 4,918 |
| order_items | 14,958 | identical | 14,958 |
| order_status_events | 21,766 | identical | 21,766 |
| orders | 5,458 | identical | 5,458 |
| products | 1,231 | identical | 1,231 |
| refunds | 456 | identical | 456 |
| returns | 373 | identical | 373 |

Values obtained from raw tables
```sql
SELECT table_id, row_count
FROM fm_raw.__TABLES__
ORDER BY table_id;
```

## Staging checks (week 5)

`docs/staging_checks.sql` holds the row-count query above (against the staging views) and the
ledger query below. Run after `dbt build`; results on 2026-11-07:

| Check | Expected | Actual |
| --- | --- | --- |
| duplicate customers by cookie, staging | 0 | 0 |
| unparseable `event_at` | 0 | 0 |
| late-arriving events flagged | 2,226 | 2,226 |
| NULL `has_email_consent` | ~711 | 705 (6 of the 711 raw NULLs sat on duplicate rows removed by the dedup) |
| `has_currency_mismatch` | 20 | 20 |
| NULL `shipping_country` | 0 | 0 |
| `category = 'Other'` | 0 | 0 |

`dbt build` on the same day: 1 seed, 10 views, 82 tests; 91 pass, 2 warn (the relationships
tests above: 7 and 5), 0 errors. The full ledger with the guarding test per row is in
`generator/README.md`, section "Problem ledger: handled in staging".

## Staging checks (GA4, week 6)

Queries in `docs/staging_checks.sql`, GA4 section. Run 2026-11-10 against `dbt_dev_staging`
after a green `dbt build` (13 staging models, 1 seed, 111 tests; the only warns are the
two Week 5 `relationships` warns, 7 and 5 rows, cleared by Week 7's stitching).

| # | Check | Expected (Week 2 / issue) | Actual | Note |
| --- | --- | --- | --- | --- |
| q1 | Candidate event key unique on raw | 4,295,584 = 4,295,584 | 4,295,584 = 4,295,584 | Seven columns are a true key; no tiebreaker |
| q2 | stg_ga4__events rows, by month | 4,295,584 | 4,295,584 total; Nov 2020 1,472,712 / Dec 2020 1,612,725 / Jan 2021 1,210,147 | Nothing dropped |
| q3 | Sessions by session_key vs session_start events | 360,129 vs 354,857 | 360,129 vs 354,970 | Week 2 counted 354,857 (113 fewer; likely a different suffix bound or count form in ga4_queries.sql q3). Gap to the key count is ~1.4% either way; Week 7 sessionises on the key, not on session_start |
| q4 | Purchase events: identified + unidentified | ~4,784 + 883 | 4,786 + 906 = 5,692 | 906 = 883 '(not set)' + 23 NULL; Week 2 missed the NULLs |
| q5 | Empty purchase events (no id, no revenue) | 448 | 450 | 448 carry one '(not set)' placeholder item (the Week 2 figure); 2 more have an empty items array (week 7 i8b) |
| q6 | Transactions after dedup; duplicate events | ~4,451; ~324 | 4,451; 335 on 326 transactions | First event wins |
| q6b | Duplicates agree on revenue? | — | 311 agree, 15 disagree | Small ambiguity GA4 cannot resolve; backend has the real figure |
| q7 | Lines; GA4 header revenue = sum of net lines? | 13,218 | 13,218 lines; quantity matches on 4,451/4,451; header = lines on 3,618 (81%); differs on 833 (447 above, 386 below), not explained by shipping + tax | GA4 disagrees with itself on revenue before any backend comparison |
| q8 | Lines where gross != net; net > gross | — | 1,072 (8.1%); 495 | item_revenue is not price x quantity; known reconciliation reason |
| q8 | Single-option lines; blank breadcrumb lines | — | 8,338; 204 | item_variant NULLed; raw_item_category is found-via only |
| q9 | Bytes processed per model, last build | events: low GB | events 2.05 GB (~15 s, table build); purchases 1.61 GB; purchase_items 1.65 GB (views: per query, taken from each model's `unique` test) | Console estimate for events was 2.35 GB; the model reads named sub-fields only. The views cost ~1.6 GB per query because the event_name filter cuts rows, not scanned bytes; a Week 9 argument for making them tables too |

Bytes per node (tables from the model row, views from their `unique` test):

```bash
python3 - <<'EOF'
import json
for r in json.load(open('target/run_results.json'))['results']:
    b = (r.get('adapter_response') or {}).get('bytes_processed')
    if b and 'ga4' in r['unique_id']:
        print(r['unique_id'].split('.')[-1][:60], round(b / 1e9, 2), 'GB')
EOF
```

Numbers that replace earlier estimates from here on: **906** unidentified purchase events
(not 883), **4,451** transactions, **335** duplicate events on **326** transactions,
**354,970** session_start events (not 354,857).

## Intermediate conventions (week 7)

- **Refs only.** Intermediate models `ref()` staging models or each other, never `source()`. Joins,
  whole-entity window functions and changes of grain start here.
- **Naming.** `int_<source>__<what>`; the one model that crosses sources is `int_reconciliation__`.
- **Views, two exceptions.** `int_ga4__sessions` (aggregates 4.3M events, 904 MiB per build) and
  `int_reconciliation__ga4_vs_backend` (reads both GA4 purchase views, 2.0 GiB) are tables, set in
  the model's own `config()`.
- **Layout.** Import CTEs named after what they hold, then logic CTEs, then `final`.
- **Label what the data shows.** A GA4 purchase without an order is `ga4_only_no_backend_order`,
  not "payment declined". The generator's answer key checks results; it is never an input.
- **A cookie is not a person.** Stitching is `user_pseudo_id` to customer; `user_id` is never populated.
- **No warn-level tests.** The two week 5 warns were split into two error-level questions
  (id exists in the source; id resolves to a surviving customer).

## Intermediate checks (week 7)

Queries in `docs/intermediate_checks.sql`. Run 2026-11-11 to 2026-11-15 against `dbt_dev_staging`
and `dbt_dev_intermediate`. Full build 2026-11-15: 1 seed, 18 models (14 staging, 4 intermediate),
143 tests, PASS=162, WARN=0, 100 s. The two week 5 relationships warns are gone.

| # | Check | Expected | Actual | Note |
| --- | --- | --- | --- | --- |
| i1 | Events; events without a session id | 4,295,584; unknown | 4,295,584; 0 | Filter is a guard only; nothing excluded |
| i1 | Sessions by key vs session_start events | 360,129 vs 354,970 | 360,129 vs 354,970 | 5,159 sessions have no session_start |
| i1b | Sessions on two event dates | unknown | 845 (0.23%) | Session keeps its start date; Week 9 lookback must cover them |
| i2 | Sessions without a session_start event | about 5,159 (360,129 − 354,970) | 5,272 (1.5%) | The subtraction assumed one session_start per session. 354,857 sessions have one (360,129 − 5,272) and they carry 354,970 session_start events, so 113 events are duplicates. This is the 113 gap between Week 2 (354,857, sessions counted) and Week 6 (354,970, events counted). |
| i3 | Status events; orders with events; late events | ~21,800; 5,458; 2,226 | 21,766; 5,458; 2,226 (10.2%) | ~4.0 events per order; first 2020-11-02 00:22 UTC, last 2021-03-03 16:09 UTC |
| i3b | Instants where one order has two events | unknown | 160 pairs (320 events), never more than 2 | Time alone cannot order them; status_rank breaks the tie |
| i3c | Which statuses tie | placed + paid (guess) | paid + placed: 160, nothing else | Instant payment; rank orders placed before paid |
| i3d | History rows; current rows; illegal transitions; instant payments | 21,766; 5,458; 0; 160 | 21,766; 5,458; 0; 160 | One current status per order; tiebreak orders all 160 ties correctly |
| i4 | Current status of every order | sums to 5,458 | delivered 4,605 / refunded 451 / cancelled 290 / shipped 112 | 4,605 = 4,918 delivered − 313 returned; 451 = 456 refunds − 5 bad; none left in placed, paid or returned |
| i5 | Status at 2020-12-24 12:00 UTC | orders placed by then | 4,041: delivered 2,945 / shipped 485 / paid 203 / cancelled 197 / refunded 187 / returned 14 / placed 10 | Shipped 12.0% vs 2.1% at the end: the December shipping lag |
| i6 | Illegal transitions | no rows | no rows | Saved as is; becomes a singular test in week 10 |
| i7 | Identity map: ids; customers; duplicate ids | 4,724; 4,651; 73 | 4,724; 4,651; 73 | Matches the week 5 dedup exactly |
| i7 | Orders and surveys on a duplicate id, now resolved | 7; 5 | 7; 5 | The two week 5 relationships warns are gone; build has WARN=0 |
| i8 | Reconciliation rows by category and detail | 4,212 / 239 / 458 / 448 / 1,246 = 6,603 | matched 4,212 / no_backend_order 239 / unidentified 456 / placeholder 450 / backend_only 1,246 = 6,603 | GA4 side 5,357, backend side 5,458; placeholder is 450 by the model's definition, not 448. GA4 revenue 339,457 vs backend gross 356,422 (95.2%); matched agree at 289,997 |
| i8b | What the 450 empty purchase events carry in items | 448 placeholder + 2 unknown | 448 single placeholder item; 2 no items; 0 with several | Explains 450 vs 448; the model's definition (no id, no revenue) covers both |
| i9 | Revenue reason on matched orders | discount ~628; small ga4_header_differs | exact 3,571 / backend_discount 626 / currency_mismatch 15; no ga4_header_differs | Gross delta 0 on every order; net gap 4,588.13 (1.6%), all backend discount; 2 discounted orders are EUR-flagged, hence 626 not 628 |
| i10 | Flags on matched orders | discount 628; line sums differ 0 | discount 628 / header-vs-lines 781 (18.5%) / line discount 556 / line sums differ 0 / same cookie 4,212 / same timestamp 4,212 / EUR 15 | Stitching and timestamps agree on all matched orders |
| i11 | Orders placed on or after 2021-02-01 UTC | unknown | 27; first order 2020-11-02 00:22 UTC, last 2021-02-07 09:20 UTC | Split by category in i11b; decides the week 8 reporting-period filter |
| i11b | Category of the 27 orders after 2021-01-31 UTC | backend_only | backend_only 27 (1 to 7 Feb); no matched | UTC cut-off is safe; in-window 5,431 orders, 4,212 matched (77.6%) |
| i12 | ga4_only_no_backend_order vs generator answer key | 239 | 239 (file has 240 lines incl. header) | Found from data alone; file never used as input |

- int_ga4__sessions: 360.1k rows, 904.4 MiB processed per full build (table).
- int_ga4__sessions

| Figure | Value | Reading |
| --- | --- | --- |
| Sessions; events in sessions | 360,129; 4,295,584 | Exact; nothing dropped |
| Without session_start	 | 5,272 (1.5%) | 113 duplicate session_start events account for the difference from 5,159 |
| Engaged | 241,932 (67.2%)	 |  |
| With a purchase event | 4,848 |  |
| With an identified purchase | 4,044 | The 4,451 transactions sit in 4,044 sessions, so some sessions hold more than one |
| Purchase events all unidentified | 804 (4,848 − 4,044) | Consistent with the 906 unidentified events |
| Zero duration | 58,370 (16.2%)	 | One-event sessions, or all events at the same instant |
| Median duration | 13 s | approx_quantiles is approximate; treat as “about 13 s” |


## Mart checks (week 8)

| m1 | Orders; in period; in stub week; EUR; discounted | 5,458; 5,431; n/a; ~20; ≥628 | 5,458; 5,431; 0; 20; 628 | No orders on 1 Nov, so no stub order week; discounts only on GA4-seeded orders |
| m2 | fct_orders shape | 5,458; ≤4,651 customers; 5,431 in period; 428 cancelled; 4,918 delivered; 313 returned; 456 with refund; 5 refunded while shipped | 5,458; 4,491; 5,431; 428; 4,918; 313; 456; 5; max 16 orders per customer | 160 customers have no order (m2b); 1.8 MiB per build |
| m2b | Customers with no order; without cookie; cookie has a GA4-only purchase | 160; 0; ~160 | 160; 0; 160 | All 160 are GA4 purchasers whose only purchase got no backend order |
| m3 | Orders; not cancelled; net revenue USD; refunded USD; GA4 missed; share | 5,431; >5,003; n/a; n/a; 1,219; 22.45% | 5,431; 5,006; 321,733.25; 23,236.36; 1,219; 22.45% | 425 cancelled in period; refunds 7.2% of net revenue, reported beside it |
| m4 | Orders and net revenue by week and channel | 39 rows; sums to m3 | 38 rows; web 4,212 / 263,229.25; app 743 / 35,521.00; phone 476 / 22,983.00; peak week 2020-12-07 (939 / 57,989.82) | No web orders in week of 2 Nov; GA4 missed 100% of app and phone, 0% of web |
| m5 | Orders with lines; lines = gross; lines ≠ gross; negative-margin lines | 5,458; n/a; several hundred (≤833 among matched); n/a | 5,458; 4,677; 781; 26 | 14.3% of orders: GA4 header vs line revenue gap carried through; revenue from fct_orders, margin from fct_order_items |
| m6 | Margin by category (period, not cancelled, USD) | 7 categories, no Other; rates ~0.30 to 0.60 | Apparel 210,261 / 109,114 / 51.9%; Drinkware 43,727 / 19,683 / 45.0%; Bags 27,490 / 12,340 / 44.9%; Accessories 19,797 / 9,054 / 45.7%; Stationery 17,705 / 7,835 / 44.3%; Lifestyle 4,121 / 1,741 / 42.2%; Gift Cards 2,800 / 1,435 / 51.2% | Total 325,901 / 161,202 / 49.5%; Apparel 67.7% of margin; Stationery 24.3% of units, 4.9% of margin |
| m7 | Customers; buyers in period; repeat buyers; share; consented / declined / unknown; linked to GA4 | 4,651; <4,491; n/a; n/a; unknown ~700; n/a | 4,651; 4,168; 577; 13.84%; 2,544 / 1,402 / 705; 4,514 | 323 customers have only cancelled or February orders; 137 customers have no cookie |
| m8 | SKUs; sold; launched in period; launched and sold; avg days to first sale; min days | 1,231; n/a; small or 0; n/a; n/a; ≥0 | 1,231; 786; 12; 8; 42.4; 13 | 445 SKUs (36.1%) never sold; no sale before launch |
| m9 | Return rate by category (lines) | 7 rows; returned lines ≤650 | Gift Cards 5 / 64 = 7.81%; Apparel 354 / 6,064 = 5.84%; Lifestyle 12 / 259 = 4.63%; Bags 40 / 918 = 4.36%; Stationery 91 / 2,218 = 4.10%; Accessories 65 / 1,612 = 4.03%; Drinkware 83 / 2,239 = 3.71% | 650 / 13,374 = 4.86% overall; Gift Cards base too small to rank |
| m9 | Return rate by channel (orders) | requests ≤373; ~7.6% overall | app 52 / 670 = 7.76%; web 291 / 3,807 = 7.64%; phone 30 / 417 = 7.19% | 373 / 4,894 = 7.62%; no channel effect |
| m9 | Return reasons (requests / accepted) | 4 rows; ≤373 / ≤313 | changed_mind 151 / 133; wrong_size 109 / 84; damaged 63 / 52; not_as_described 50 / 44 | 373 / 313; wrong_size has the lowest acceptance (77.1%) |
| m9a | Returned lines; requests; accepted; whole-order; days from delivery | >373; 373; 313; ~150; 0 to 30 | 650; 373; 313; 161; 1 to 30 | 212 item returns + 161 whole-order returns expanded to 438 lines; 83.9% accepted |
| m10 | NPS by delivery month (responses / NPS / avg days) | sums 4,918 and 1,947; December dip | Nov 362 / 1.1 / 6.2; Dec 1,095 / 7.0 / 7.5; Jan 429 / 9.1 / 6.6; Feb 61 / −6.6 / 7.4 | No December dip, contrary to the generator README; monthly gaps within sampling error |
| m10 | NPS by delivery-time band | responses 496 / 957 / 494; falling with time | 16.9 / 11.3 / −15.4 | 32 points from fastest to slowest; the drop is past 8 days |
| m10a | Surveys; responses; promoters / passives / detractors; NPS; days to deliver; band responses | 4,918; ~1,970; sum = responses; n/a; n/a; three usable bands | 4,918; 1,947 (39.6%); 722 / 619 / 606; 6.0; 2 to 12; 496 / 957 / 494 | Band edges at 5 and 8 days kept |
| m10b | By delivery month: slow carrier share; NPS fast / slow carrier leg; avg days paid to shipped | fast ~+20, slow ~−20; December share not higher; December warehouse lag | Nov 29.6% / 20.0 / −43.9 / 1.9; Dec 33.4% / 21.4 / −21.6 / 2.9; Jan 36.6% / 22.4 / −14.0 / 2.0; Feb 70.5% / 22.2 / −18.6 / 2.2 | Pooled +21.3 (1,274) vs −23.2 (673). December lag is paid to shipped, which does not drive the score. Open: November slow group at −43.9 on 107 responses |
| m10c | NPS by whole days in transit (responses / NPS) | sums to 1,947; step from ~+20 to ~−20 | 2: 310 / 15.2; 3: 332 / 28.0; 4: 320 / 16.9; 5: 312 / 25.0; 6: 320 / −24.7; 7: 353 / −21.8 | A step between 5 and 6 days, not a slope; no trend inside either group |
| m11 | Closed funnel by device (viewed / cart / checkout / purchased) and open purchases | sessions 208,942 / 143,185 / 8,002; open purchases sum to 4,848 | desktop 44,819 / 8,780 / 3,425 / 1,606, open 2,749; mobile 30,501 / 6,072 / 2,404 / 1,180, open 1,995; tablet 1,700 / 321 / 130 / 62, open 104 | Biggest drop view to cart (19.7%); devices within ~2 points; 2,000 of 4,848 purchase sessions (41.3%) fall outside the closed funnel |
| m11a | Device categories in int_ga4__sessions | desktop / mobile / tablet, sum 360,129 | 208,942 / 143,185 / 8,002; no NULL | Sets the accepted_values list for fct_sessions |
| m11b | Sessions; of known customers; customers with sessions; with purchase; with identified purchase; abandoned checkouts | 360,129; n/a; 4,514; 4,848; 4,044; n/a | 360,129; 14,676 (4.1%); 4,514; 4,848; 4,044; 6,261 | Cookie join adds no rows; ~3.3 sessions per customer |
| m11c | Purchase sessions by funnel depth | depth 4 = 2,848; rest sums to 2,000 | depth 0: 150 (147 with checkout, 22 first sessions); depth 1: 1,850 (all with checkout, none with cart, 644 first sessions); depth 4: 2,848 (1,114 first sessions) | Missing step is add_to_cart; first-session share similar to complete funnels, so not returning shoppers |
| m12 | Repeat purchase by weeks since first order (complete weeks, zeros kept) | week 0 = 4,168 at 1.0; 13 cohorts falling to 1 | w1 103 / 4,043 = 2.55%; w2 1.93%; w3 1.68%; w4 1.26%; w5 1.16%; w6 1.02%; w7 0.61%; w8 0.68%; w9 0.50%; w10 0; w11 0.34%; w12 0 | Per-week, not cumulative; 377 customer-weeks in weeks 1 to 12, so ≥200 of 577 repeat buyers reordered in week 0; first cohort 55 customers |
| m12 | Retention of new visitors by weeks since first session | week 0 at 1.0; 13 cohorts falling to 1 | 259,174 new visitors; w1 3.80%; w2 1.55%; w3 1.09%; w4 0.91%; w6 0.43%; w8 0.30%; w12 0.08% | Cohorts large enough to read throughout |

Full build 2026-11-19: 1 seed, 27 models, 217 tests, PASS=245, WARN=0, 154 s.

## Mart conventions (week 8)

- **One question per mart.** Every description opens with its business question (domain_spec section 9).
- **Naming.** `fct_` facts, `dim_` dimensions, `agg_` pre-aggregated cohorts. `marts/core` is the order
  system; `marts/product` is behaviour, returns, NPS and cohorts.
- **Tables** in `dbt_dev_marts`; `fct_sessions` is partitioned by `session_date`.
- **No logic of their own.** Status, customer and reconciliation category are read from intermediate.
- **Grain is stated and tested.** Every fact has a row-count test against the model that defines its
  grain. `fct_returns` is one row per returned line; `return_line_number = 1` gives requests.
- **Flags, not filters.** All orders are kept; `is_in_reporting_period`, `is_cancelled` and
  `has_currency_mismatch` are applied in the query.
- **Amounts and counts, never rates.** Rates are computed at query time from sums.
- **Revenue from `fct_orders`, margin from `fct_order_items`.** Their totals differ by design
  (lines differ from order gross on 781 orders).
- **Cohort cells with no row are zeros.** Pooled cohort rates are computed over the full grid (m12).

## Open after week 8

- November's slow-carrier NPS is −43.9 on 107 responses, against about −20 in other months (m10b).
- README limitations (week 14): every web order is matched and every app/phone order is missed;
  Gift Cards carry a generated cost of goods; the funnel's view-to-cart rate is a lower bound.

## Source freshness

Thresholds in `models/staging/backend/_backend__sources.yml` follow each feed's real cadence,
not the data:

| Feed | warn / error | Why |
| --- | --- | --- |
| orders, order_items, order_status_events, customers | 1 h / 1 day | the order system writes continuously |
| returns, refunds, nps_surveys, marketing_spend | 1 day / 2 days | daily batch feeds (spend is a nightly file) |
| products, experiment_assignments | none | reference data; changes with a release or an experiment, not on a clock |

The raw layer is a frozen snapshot (generator seed 20201101, events 2020-11-01 to 2021-03-15),
so `dbt source freshness` reports every checked table as **ERROR STALE** by design. The
thresholds are kept realistic rather than inflated to pass. CI gates on `dbt build`;
freshness is run for the report, not as a gate.

Max `loaded_at` per table, run 2026-11-03:

| Table | max loaded_at (UTC) | Note |
| --- | --- | --- |
| orders | 2021-02-07 09:36:00 | a week past the GA4 window: the 825 forced A/B orders are placed up to 7 days after first exposure |
| order_items | 2021-02-07 09:36:00 | = orders (a line is loaded with its order) |
| customers | 2021-02-23 17:42:26 | duplicate customer rows are created 1-30 days after the original |
| marketing_spend | 2021-02-01 06:00:00 | nightly file for 31 Jan |
| nps_surveys | 2021-02-18 03:18:48 | sent 2-3 days after the last deliveries |
| refunds | 2021-03-03 16:17:35 | lifecycle tail: return window + refund lag |
| order_status_events | 2021-03-06 16:09:35 | lifecycle tail |
| returns | 2021-03-07 04:59:54 | lifecycle tail: up to 30 days after delivery |

## Snapshot and incremental checks (week 9)

| Check | What | Expected | Actual | Note |
| --- | --- | --- | --- | --- |
| r2 (early) | Raw orders; discounted; status events | 5,458; 0; 19,540 | 5,458; 0; 19,540 | 2,226 late events held back |
| r3 (early) | Current status per order | differs from week 7 | delivered 4,157; shipped 498; refunded 403; cancelled 275; paid 56; placed 35; returned 31 | Sums to 5,455: 3 orders have no status event yet |
| r3b (early) | History rows; illegal transitions | 19,540; > 0 | 19,540; 1,514 | 7.7% of transitions look illegal until late events land |
| r2 (final) | Raw orders; discounted; status events | 5,458; 628; 21,766 | 5,458; 628; 21,766 | Raw restored |
| r3 (final) | Current status per order | = week 7 i4 | delivered 4,605; refunded 451; cancelled 290; shipped 112 | Sums to 5,458 |
| r3b (final) | History rows; illegal transitions | 21,766; 0 | 21,766; 0 | Late events landed; history correct with no code change |
| r4 | Versions; orders; current; closed; runs with changes | 6,086; 5,458; 5,458; 628; 2 | 6,086; 5,458; 5,458; 628; 2 | Second run merged 1.3k rows (628 closed + 628 inserted) |
| r5 | Orders changed; net as first seen; net now; discount applied later | 628; n/a; n/a; n/a | 628; 356,422.00; 351,833.87; 4,588.13 | All orders incl. cancelled and EUR; not the week 8 net revenue |
| r6 | Events in window; events in another day's shard | 4,295,584; 0 | 4,295,584; 0 | One shard holds exactly one event_date |
| r7 (baseline) | Events; days; last date; purchase events; key fingerprint | 4,295,584; 92; 2021-01-31; 5,692; n/a | 4,295,584; 92; 2021-01-31; 5,692; 1318486233096451813 | Week 8 table, before the incremental change |
| r7 (after run 1) | Events; days; last date; purchase events; key fingerprint | = baseline | 4,295,584; 92; 2021-01-31; 5,692; 1318486233096451813 | Incremental: SCRIPT, 93.2 MiB, 13 s (full build 2.05 GB) |
| r7 (after run 2) | same | = baseline | 4,295,584; 92; 2021-01-31; 5,692; 1318486233096451813 | Idempotent: second run 93.2 MiB, table unchanged |
| r8 | Sessions by days spanned past their first date | 359,284 at 0; 845 at 1 | 359,284 at 0; 843 at 1; 1 at 2; 1 at 5 | Buffer set to 5, not 1; the 845 from week 7 counted all sessions on more than one date |
| r9 (baseline) | Sessions; distinct; events; with purchase; last date; row fingerprint | 360,129; 360,129; 4,295,584; 4,848; 2021-01-31; n/a | 360,129; 360,129; 4,295,584; 4,848; 2021-01-31; 1712534599991345720 | Week 8 table, before the incremental change |
| r9 (after run) | same | = baseline | 360,129; 360,129; 4,295,584; 4,848; 2021-01-31; 1712534599991345720 | Incremental: SCRIPT, 15.9 MiB, 13 s (full build 904.4 MiB); buffer 5 |
| Exp 1, as of 24 Jan | r7: events; days; last date; purchases · r9: sessions; with purchase | 85 days; last date 2021-01-24 | 4,022,077; 85; 2021-01-24; 5,349 · 333,787; 4,537 | Full refresh with ga4_end_date 2021-01-24: 1.8 GiB + 847.3 MiB |
| Exp 1, after catch-up | r7 and r9 | = baselines | 4,295,584; 92; 5,692; 1318486233096451813 · 360,129; 4,848; 1712534599991345720 | Equal to a full build; 204.4 MiB + 23.0 MiB |
| Exp 2, late rows missing | Rows removed (30 Jan purchases) · r7: events; purchases · r9: with purchase | r7 short by the rows removed | 31 · 4,295,553; 5,661 · 4,820 | 31 events in 28 sessions; session count unchanged at 360,129 |
| Exp 2, after next run | r7 and r9 | = baselines | 4,295,584; 5,692; 1318486233096451813 · 360,129; 4,848; 1712534599991345720 | Repaired by the lookback; 93.2 MiB + 15.9 MiB |
| Exp 3, after incremental run | Rows removed (15 Jan purchases) · r7: events; purchases · r9 | r7 still short; r9 = baseline | 47 · 4,295,537; 5,645 · baseline | Not repaired: outside the lookback. Events and sessions disagree; no test fails |
| Exp 3, after full refresh | r7 and r9 | = baselines | 4,295,584; 5,692; 1318486233096451813 · (r9 confirmed in C7) | Only a full refresh repairs it |

## Snapshot and incremental strategy (week 9)

- **What is incremental, and why only that.** stg_ga4__events and int_ga4__sessions: 2.05 GB and
  904.4 MiB per full build. Every backend model is a view or a table of a few MiB; rebuilding in
  full is the cheapest way to be right about late data, so they stay as they are.
- **Strategy.** insert_overwrite by date partition, no unique_key. A run replaces whole days:
  idempotent, and rows that vanish from the source vanish here. Rejected: merge (scans the key,
  never deletes); microbatch (batches follow today's clock, the sample ends 2021-01-31).
- **Lookback: 3 days.** Backend status events arrive 0 to 3 days late (r1: 19,540 / 765 / 723 /
  738); GA4 updates a daily table for up to 72 hours. The start date is resolved at compile time
  (lookback_start_date) so BigQuery prunes shards and partitions.
- **Session buffer: 5 days.** One session spans 5 dates past its first, one spans 2, 843 span 1
  (r8). Sessions are rebuilt from newest date minus lookback minus buffer (9 partitions); events
  are read from one buffer earlier (14 days). Guard: unique on session_key.
- **Cost.** Events 93.2 MiB per run (was 2.05 GB); sessions 15.9 MiB (was 904.4 MiB). Measured over
  the whole build (INFORMATION_SCHEMA.JOBS): 29.10 GiB at PASS=252, against 31.52 GiB at PASS=245
  in week 8, a saving of 2.42 GiB (7.7%). Elapsed time did not improve (162 s against 154 s).
  The build is dominated by tests on two views over the raw GA4 sample: each test on
  stg_ga4__purchase_items or stg_ga4__purchases scans about 1.34 GiB, and the top 15 nodes
  account for 20.8 GiB. Earlier notes that put a full build at "about 5 GB" were an estimate.
- **Tested (r7, r9 fingerprints against a full refresh).** A week of new days: equal, for 204.4 MiB
  + 23.0 MiB. 31 late rows inside the lookback: 28 sessions under-reported for one run, repaired
  by the next. 47 late rows outside it: not repaired, events and sessions disagree, no test fails,
  until --full-refresh.
- **Backstop.** A scheduled full refresh of the two models (about 2.9 GB). Not automated in this
  project.
- **Snapshot.** snp_backend__orders, check strategy on eight columns because raw orders has no
  updated_at. Validity dates are snapshot-run times. 6,086 versions of 5,458 orders after the
  week 9 exercise; 628 orders changed, 4,588.13 of discount applied after first sight.
- **Late status events.** With the 2,226 late events held back, the history showed 1,514 illegal
  transitions of 19,540, 122 orders at placed, paid or returned, and 3 orders with no status at
  all (r3, r3b); after they landed, 0 of 21,766. Transition tests must allow for this.

## How product_category_overrides was built

Two passes against `fm_raw.products`:

1. **By raw value.** `select category, count(*) from fm_raw.products group by 1 order by 2 desc`
   gave 52 distinct values. The 29 that name a product type map by value (one row each,
   product_id empty). The 15 navigation-style values (Campus Collection, Sale, New, Shop by Brand,
   Eco-Friendly, Small Goods, Uncategorized Items, Lifestyle, Black Lives Matter, Fun, Google,
   and their Home/ variants) plus NULL get no value row.
2. **By SKU.** The 564 SKUs under those values were mapped from product_name by keyword
   (tee/hoodie/jacket -> Apparel, bottle/mug/tumbler -> Drinkware, ...), one row each,
   raw_category empty. Per-SKU rows win over value rows in stg_backend__products.

To rebuild after a catalogue change: re-run the group-by and add value rows for any new product-type
value; then query the SKUs whose category is NULL or a navigation-style value (docs/ga4_queries.sql, fm03)
and append a per-SKU row for every id not already in the seed.

**Health check.** `stg_backend__products` falls back to 'Other' for any SKU the seed does not
cover, so the share of Other measures how complete the seed is. Week 5 run (2026-11-06):
0 of 1,231 SKUs. Distribution: Apparel 734, Stationery 134, Drinkware 123, Accessories 111,
Bags 91, Lifestyle 30, Gift Cards 8. If a generator re-run or a catalogue change puts SKUs
into Other, query `where category = 'Other'` on the staging view and add per-SKU rows for them.