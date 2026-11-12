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
| q5 | Placeholder events (NULL revenue, no id) | 448 | 448 | Sub-bucket "GA4 purchase with no order data" |
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

## Intermediate checks (week 7)

| # | Check | Expected | Actual | Note |
| --- | --- | --- | --- | --- |
| i1 | Events; events without a session id | 4,295,584; unknown | 4,295,584; 0 | Filter is a guard only; nothing excluded |
| i1 | Sessions by key vs session_start events | 360,129 vs 354,970 | 360,129 vs 354,970 | 5,159 sessions have no session_start |
| i1b | Sessions on two event dates | unknown | 845 (0.23%) | Session keeps its start date; Week 9 lookback must cover them |
| i2 | Sessions without a session_start event | about 5,159 (360,129 − 354,970) | 5,272 (1.5%) | The subtraction assumed one session_start per session. 354,857 sessions have one (360,129 − 5,272) and they carry 354,970 session_start events, so 113 events are duplicates. This is the 113 gap between Week 2 (354,857, sessions counted) and Week 6 (354,970, events counted). |
| i3 | Status events; orders with events; late events | ~21,800; 5,458; 2,226 | 21,766; 5,458; 2,226 (10.2%) | ~4.0 events per order; first 2020-11-02 00:22 UTC, last 2021-03-03 16:09 UTC |
| i3b | Instants where one order has two events | unknown | 160 pairs (320 events), never more than 2 | Time alone cannot order them; status_rank breaks the tie |
| i3c | Which statuses tie | placed + paid (guess) | paid + placed: 160, nothing else | Instant payment; rank orders placed before paid |

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