"""Fennmark backend generator.

Reads the GA4 public sample once (four cached extracts), builds the ten backend
tables around its purchases with the problems listed in docs/domain_spec.md
section 7, and loads them into the raw dataset.

Run:  python generator/generate.py [--config generator/config.yml]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from faker import Faker
from google.cloud import bigquery

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache"
OUTPUT = HERE / "output"

# --------------------------------------------------------------------------- #
# GA4 extracts (run once; cached as parquet)
# --------------------------------------------------------------------------- #

GA4 = "bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*"

SQL_PURCHASE_LINES = f"""
-- purchase_lines: one row per item line on a deduplicated, identifiable purchase
WITH purchases AS (
  SELECT ecommerce.transaction_id AS order_id,
         TIMESTAMP_MICROS(event_timestamp) AS placed_at,
         user_pseudo_id, geo.country AS country,
         ecommerce.purchase_revenue AS purchase_revenue, items,
         ROW_NUMBER() OVER (PARTITION BY ecommerce.transaction_id
                            ORDER BY event_timestamp) AS rn
  FROM `{GA4}`
  WHERE event_name = 'purchase'
    AND ecommerce.transaction_id IS NOT NULL
    AND ecommerce.transaction_id != '(not set)'
)
SELECT p.order_id, p.placed_at, p.user_pseudo_id, p.country, p.purchase_revenue,
       i.item_id, i.item_name, i.item_variant, i.item_category,
       i.price, i.quantity, i.item_revenue
FROM purchases p, UNNEST(p.items) AS i
WHERE p.rn = 1
  AND i.item_id != '(not set)' AND i.price IS NOT NULL   -- drops the 448 placeholder lines
ORDER BY p.placed_at, p.order_id, i.item_id
"""

SQL_ITEMS = f"""
-- items: product catalogue from view_item and purchase events, keyed on item_id
WITH lines AS (
  SELECT i.item_id, i.item_name, i.item_category, i.item_variant, i.price,
         TIMESTAMP_MICROS(event_timestamp) AS event_ts,
         event_name
  FROM `{GA4}`, UNNEST(items) AS i
  WHERE event_name IN ('view_item', 'purchase')
    AND i.item_id IS NOT NULL AND i.item_id != '(not set)'
),
mode_name AS (
  SELECT item_id, item_name
  FROM (SELECT item_id, item_name, COUNT(*) n,
               ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY COUNT(*) DESC, item_name) rn
        FROM lines WHERE item_name IS NOT NULL AND item_name NOT IN ('', '(not set)')
        GROUP BY 1, 2)
  WHERE rn = 1
),
mode_category AS (
  SELECT item_id, item_category
  FROM (SELECT item_id, item_category, COUNT(*) n,
               ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY COUNT(*) DESC, item_category) rn
        FROM lines WHERE item_category IS NOT NULL AND item_category NOT IN ('', '(not set)')
        GROUP BY 1, 2)
  WHERE rn = 1
),
mode_variant AS (
  SELECT item_id, item_variant
  FROM (SELECT item_id, item_variant, COUNT(*) n,
               ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY COUNT(*) DESC, item_variant) rn
        FROM lines WHERE item_variant IS NOT NULL AND item_variant NOT IN ('', '(not set)')
        GROUP BY 1, 2)
  WHERE rn = 1
),
mode_price AS (
  SELECT item_id, price
  FROM (SELECT item_id, price, COUNT(*) n,
               ROW_NUMBER() OVER (PARTITION BY item_id
                                  ORDER BY COUNTIF(event_name = 'purchase') DESC, COUNT(*) DESC, price) rn
        FROM lines WHERE price IS NOT NULL AND price > 0
        GROUP BY 1, 2)
  WHERE rn = 1
),
first_seen AS (
  SELECT item_id, MIN(event_ts) AS first_seen,
         MIN(IF(event_name = 'purchase', event_ts, NULL)) AS first_purchased,
         COUNTIF(event_name = 'purchase') AS purchase_lines
  FROM lines GROUP BY 1
)
SELECT f.item_id, n.item_name, c.item_category, v.item_variant, p.price,
       f.first_seen, f.first_purchased, f.purchase_lines
FROM first_seen f
LEFT JOIN mode_name n USING (item_id)
LEFT JOIN mode_category c USING (item_id)
LEFT JOIN mode_variant v USING (item_id)
LEFT JOIN mode_price p USING (item_id)
ORDER BY f.item_id
"""

SQL_SESSIONS_BY_SOURCE = f"""
-- sessions_by_source: daily session counts per traffic source, medium and campaign
-- Note: traffic_source is the user's first-touch source in the GA4 export, and
-- '(data deleted)' appears on some rows (obfuscation). Both documented in ga4_notes.md.
SELECT PARSE_DATE('%Y%m%d', event_date) AS spend_date,
       traffic_source.source AS source,
       traffic_source.medium AS medium,
       traffic_source.name   AS campaign,
       COUNT(DISTINCT CONCAT(user_pseudo_id, '-', CAST(
         (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING
       ))) AS sessions
FROM `{GA4}`
WHERE event_name = 'session_start'
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4
"""

SQL_PROMO_EXPOSURE = f"""
-- promo_exposure: first view_promotion per user; the A/B test population and assignment time
SELECT user_pseudo_id,
       MIN(TIMESTAMP_MICROS(event_timestamp)) AS first_exposure_at,
       COUNT(*) AS promo_views
FROM `{GA4}`
WHERE event_name = 'view_promotion'
GROUP BY 1
ORDER BY 1
"""


def cached_query(client: bigquery.Client, name: str, sql: str, cache_dir: Path) -> pd.DataFrame:
    """Run `sql` once and cache the result as parquet; later calls read the cache."""
    path = cache_dir / f"{name}.parquet"
    if path.exists():
        return pd.read_parquet(path)
    print(f"[extract] running {name} against BigQuery ...")
    df = client.query(sql, location="US").to_dataframe()
    cache_dir.mkdir(parents=True, exist_ok=True)
    df.to_parquet(path, index=False)
    return df


def extract_ga4(client: bigquery.Client) -> dict[str, pd.DataFrame]:
    ga4 = {
        "purchase_lines": cached_query(client, "purchase_lines", SQL_PURCHASE_LINES, CACHE),
        "items": cached_query(client, "items", SQL_ITEMS, CACHE),
        "sessions_by_source": cached_query(client, "sessions_by_source", SQL_SESSIONS_BY_SOURCE, CACHE),
        "promo_exposure": cached_query(client, "promo_exposure", SQL_PROMO_EXPOSURE, CACHE),
    }
    # the first lines of the problem ledger
    print(f"[extract] purchase_lines: {len(ga4['purchase_lines']):,} rows, "
          f"{ga4['purchase_lines']['order_id'].nunique():,} orders")
    print(f"[extract] items: {len(ga4['items']):,} | "
          f"sessions_by_source: {len(ga4['sessions_by_source']):,} rows, "
          f"{int(ga4['sessions_by_source']['sessions'].sum()):,} sessions | "
          f"promo_exposure: {len(ga4['promo_exposure']):,} users")
    return ga4


# --------------------------------------------------------------------------- #
# Config and randomness: one seed, one rng, one Faker
# --------------------------------------------------------------------------- #

def load_config(path: Path) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def make_random(seed: int) -> tuple[np.random.Generator, Faker]:
    rng = np.random.default_rng(seed)
    Faker.seed(seed)
    fake = Faker()
    return rng, fake


# --------------------------------------------------------------------------- #
# Builders
# --------------------------------------------------------------------------- #

def build_products(ga4, cfg, rng, fake) -> pd.DataFrame:
    items = ga4["items"].sort_values("item_id").reset_index(drop=True)

    # cost band by keyword match on category, default otherwise
    bands = cfg["cost_price_share"]
    def band(cat):
        for key, rng_ in bands.items():
            if key != "default" and isinstance(cat, str) and key.lower() in cat.lower():
                return rng_
        return bands["default"]
    low_high = np.array([band(c) for c in items["item_category"]])
    share = rng.uniform(low_high[:, 0], low_high[:, 1])

    # one supplier per category, assigned in sorted-category order so it is stable
    cats = sorted(items["item_category"].dropna().unique())
    supplier_of = {c: fake.company() for c in cats}

    first_seen = pd.to_datetime(items["first_seen"], utc=True)
    launch = first_seen - pd.to_timedelta(rng.integers(30, 366, len(items)), unit="D")
    loaded_at = pd.Timestamp(cfg["window"]["end"], tz="UTC") + pd.Timedelta(days=1, hours=2)

    products = pd.DataFrame({
        "product_id":   items["item_id"],
        "product_name": items["item_name"],
        "variant":      items["item_variant"],
        "category":     items["item_category"],
        "list_price":   items["price"].astype(float),
        "cost_price":   (items["price"].astype(float) * share).round(2),
        "supplier":     items["item_category"].map(supplier_of),
        "launch_date":  launch.dt.date,
        "loaded_at":    loaded_at,
    })

    assert products["product_id"].is_unique and products["product_id"].notna().all()
    assert (products["list_price"] > 0).all(), "list_price must be > 0"
    assert (products["cost_price"] < products["list_price"]).all()
    print(f"[products] {len(products):,} rows")
    return products


def build_customers(ga4, cfg, rng, fake) -> pd.DataFrame:
    pl = ga4["purchase_lines"].copy()
    pl["placed_at"] = pd.to_datetime(pl["placed_at"], utc=True)
    first = (pl.sort_values("placed_at")
               .groupby("user_pseudo_id", sort=False)
               .agg(first_placed_at=("placed_at", "min"), country=("country", "first"))
               .reset_index()
               .sort_values(["first_placed_at", "user_pseudo_id"])
               .reset_index(drop=True))
    n = len(first)
    consent = rng.choice(np.array(["true", "false", None], dtype=object),
                         size=n, p=[0.55, 0.30, cfg["shares"]["consent_null"]])
    created_at = first["first_placed_at"] - pd.to_timedelta(rng.integers(1, 181, n), unit="min")
    customers = pd.DataFrame({
        "customer_id":      [f"C-{i:06d}" for i in range(1, n + 1)],
        "user_pseudo_id":   first["user_pseudo_id"],
        "full_name":        [fake.name() for _ in range(n)],
        "email":            [fake.email() for _ in range(n)],
        "country":          first["country"],
        "email_consent":    consent,
        "acquisition_date": first["first_placed_at"].dt.date,
        "created_at":       created_at,
        "loaded_at":        created_at + pd.to_timedelta(rng.integers(1, 31, n), unit="min"),
    })
    assert customers["customer_id"].is_unique and customers["user_pseudo_id"].is_unique
    print(f"[customers] {n:,} seeded rows, "
          f"{customers['email_consent'].isna().mean():.1%} consent NULL")
    return customers


# --------------------------------------------------------------------------- #

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(HERE / "config.yml"))
    args = ap.parse_args()

    cfg = load_config(Path(args.config))
    rng, fake = make_random(cfg["seed"])
    client = bigquery.Client(project=cfg["bigquery"]["project"], location="US")

    ga4 = extract_ga4(client)
    products = build_products(ga4, cfg, rng, fake)
    customers = build_customers(ga4, cfg, rng, fake)
    # ... B1 onwards


if __name__ == "__main__":
    main()