# dbt: exploration notes

## Staging reconciliation targets 
Expected row counts of each stg_backend__ view

| Table | Raw | Staging expected |
| --- | --- | --- |
| customers | 4.724 | 4,651 (minus the 73 duplicates) |
| experiment_assignments | 102.443 | identical |
| marketing_spend | 917 | identical |
| nps_surveys | 4.918 | identical |
| order_items | 14.958 | identical |
| order_status_events | 21.766 | identical |
| orders | 5.458 | identical |
| products | 1.231 | identical |
| refunds | 456 | identical |
| returns | 373 | identical |

Values obtained from raw tables
```sql
SELECT table_id, row_count 
FROM fm_raw.__TABLES__
ORDER BY table_id;
```

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
The health check is the share of 'Other' in stg_backend__products; 0 on the run.

**Health check.** `stg_backend__products` falls back to 'Other' for any SKU the seed does not
cover, so the share of Other measures how complete the seed is. Week 5 run (2026-11-06):
0 of 1,231 SKUs. Distribution: Apparel 734, Stationery 134, Drinkware 123, Accessories 111,
Bags 91, Lifestyle 30, Gift Cards 8. If a generator re-run or a catalogue change puts SKUs
into Other, query `where category = 'Other'` on the staging view and add per-SKU rows for them.