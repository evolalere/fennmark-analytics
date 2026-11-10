# Fennmark Analytics

End-to-end analytics for a direct-to-consumer merchandise and apparel brand: Google's public GA4
e-commerce sample joined to a generated, deliberately messy order backend, modelled with dbt on
BigQuery, tested, and reconciled source against source.

**Status:** Phase 2, week 6 of 16: backend and GA4 staged and tested; dbt build green.
(1 seed, 13 models). Next: Reconciliation (week 7), marts (week 8).

**Stack:** BigQuery, dbt 1.12, Python (pandas, Faker), GitHub Actions, Tableau Public

> The backend is generated and seeded from the public GA4 sample; nothing here is real company
> data. The value is in the modelling, testing and reconciliation, not in the data being real.

## What's here

| Layer | What | Where |
| --- | --- | --- |
| Source: GA4 | Google Merchandise Store events, 2020-11-01 .. 2021-01-31 (4.3 M events, public) | `bigquery-public-data.ga4_obfuscated_sample_ecommerce` |
| Source: backend | 10 tables behind those events (orders, lifecycle, returns, refunds, NPS, spend, A/B test) with 11 injected data problems | `generator/` |
| Staging | One model per raw table: rename, cast, dedup, parse; every key tested | `models/staging/backend/` |
| Seed | Canonical product category, mapped from GA4's navigation breadcrumbs | `seeds/product_category_overrides.csv` |
| Macro | `parse_mixed_timestamp`: two string formats to one UTC timestamp | `macros/` |

## Docs

- [Domain spec](docs/domain_spec.md) — entities, order lifecycle, planned data problems, experiment design
- [Decisions](docs/decisions.md) — the design choices that changed direction, newest first
- [Generator README](generator/README.md) — column-level schemas, how to run, problem ledger (targets vs achieved)
- [dbt notes](docs/dbt_notes.md) — staging conventions, freshness, reconciliation checks
- [GA4 exploration notes](docs/ga4_notes.md) and [queries](docs/ga4_queries.sql)