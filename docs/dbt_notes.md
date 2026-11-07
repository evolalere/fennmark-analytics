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