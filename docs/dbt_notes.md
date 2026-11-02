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



