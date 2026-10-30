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

def build_orders_seeded(ga4, customers, cfg, rng, fake):
    """GA4-seeded orders. Returns (orders, ga4_only_ids)."""
    pl = ga4["purchase_lines"].copy()
    pl["placed_at"] = pd.to_datetime(pl["placed_at"], utc=True)
    o = (pl.groupby("order_id", sort=False)
           .agg(placed_at=("placed_at", "min"),
                user_pseudo_id=("user_pseudo_id", "first"),
                purchase_revenue=("purchase_revenue", "first"))
           .reset_index()
           .sort_values(["placed_at", "order_id"])
           .reset_index(drop=True))
    n = len(o)
    sh = cfg["shares"]

    cust = customers.set_index("user_pseudo_id")
    o["customer_id"] = o["user_pseudo_id"].map(cust["customer_id"])
    assert o["customer_id"].notna().all(), "every seeded order needs a seeded customer"

    o["channel"] = "web"
    o["payment_method"] = rng.choice(["card", "paypal", "invoice", "giftcard"], size=n,
                                     p=[0.60, 0.25, 0.10, 0.05])
    o["currency"] = "USD"
    o["gross_revenue"] = o["purchase_revenue"].astype(float).round(2)

    # discount applied after the GA4 event: the main GA4-vs-backend revenue delta
    disc = rng.random(n) < sh["discounted_orders"]
    o["discount_amount"] = np.where(disc, (rng.uniform(0.05, 0.15, n) * o["gross_revenue"]).round(2), 0.0)

    # shipping country: customer's country, except ~5% gifts
    gift = rng.random(n) < 0.05
    o["country"] = np.where(gift, [fake.country_code() for _ in range(n)],
                            o["user_pseudo_id"].map(cust["country"]))

    # ~5% of GA4 purchases never became orders (payment declined)
    dropped = rng.random(n) < sh["ga4_purchase_dropped"]
    ga4_only_ids = o.loc[dropped, ["order_id", "placed_at"]].reset_index(drop=True)
    o = o.loc[~dropped].reset_index(drop=True)

    o["loaded_at"] = o["placed_at"] + pd.to_timedelta(rng.integers(1, 21, len(o)), unit="min")
    o = o.drop(columns=["purchase_revenue"])

    print(f"[orders] {len(o):,} seeded orders kept, {len(ga4_only_ids):,} GA4 purchases dropped, "
          f"{disc[~dropped].mean():.1%} discounted")
    return o, ga4_only_ids

def build_orders_backend(ga4, orders, customers, products, cfg, rng, fake):
    """B- orders GA4 never saw. Returns (orders, customers, backend_lines)."""
    sh = cfg["shares"]
    n = round(sh["backend_only_orders"] * len(orders))

    # timing: inherit the real daily/weekly shape from seeded orders
    base = orders["placed_at"].to_numpy()
    placed_at = pd.to_datetime(rng.choice(base, size=n)) \
        + pd.to_timedelta(rng.integers(-720, 721, n), unit="min")

    channel = rng.choice(["phone", "app"], size=n, p=[0.4, 0.6])
    pm_phone = ["card", "paypal", "invoice", "giftcard"]
    payment_method = np.where(
        channel == "phone",
        rng.choice(pm_phone, size=n, p=[0.45, 0.10, 0.40, 0.05]),
        rng.choice(pm_phone, size=n, p=[0.60, 0.30, 0.05, 0.05]))

    # customers: ~70% existing, ~30% new backend-only (no user_pseudo_id)
    new_mask = rng.random(n) < sh["backend_only_new_customer"]
    n_new = int(new_mask.sum())
    next_id = len(customers) + 1
    created = placed_at[new_mask] - pd.to_timedelta(rng.integers(1, 181, n_new), unit="min")
    new_customers = pd.DataFrame({
        "customer_id":      [f"C-{i:06d}" for i in range(next_id, next_id + n_new)],
        "user_pseudo_id":   None,
        "full_name":        [fake.name() for _ in range(n_new)],
        "email":            [fake.email() for _ in range(n_new)],
        "country":          [fake.country_code() for _ in range(n_new)],
        "email_consent":    rng.choice(np.array(["true", "false", None], dtype=object),
                                       size=n_new, p=[0.55, 0.30, sh["consent_null"]]),
        "acquisition_date": pd.Series(placed_at[new_mask]).dt.date.to_numpy(),
        "created_at":       created,
        "loaded_at":        created + pd.to_timedelta(rng.integers(1, 31, n_new), unit="min"),
    })
    customer_id = np.empty(n, dtype=object)
    customer_id[new_mask] = new_customers["customer_id"].to_numpy()
    customer_id[~new_mask] = rng.choice(customers["customer_id"].to_numpy(), size=n - n_new)
    customers = pd.concat([customers, new_customers], ignore_index=True)
    cust_country = customers.set_index("customer_id")["country"]

    # lines: 1-3 products weighted by GA4 popularity, at list price, no discount
    items = products[["product_id", "list_price"]].merge(
        ga4["items"][["item_id", "purchase_lines"]].rename(columns={"item_id": "product_id"}),
        on="product_id")
    items["w"] = (items["purchase_lines"] + 0.1)          # +0.1 so never-sold SKUs are rare, not impossible
    items["w"] = items["w"] / items["w"].sum()

    order_ids = [f"B-{i:06d}" for i in range(1, n + 1)]
    n_lines = rng.integers(1, 4, n)
    line_rows = []
    for oid, k in zip(order_ids, n_lines):
        picks = rng.choice(items["product_id"].to_numpy(), size=k, replace=False, p=items["w"].to_numpy())
        qty = rng.integers(1, 3, k)
        for j, (pid, q) in enumerate(zip(picks, qty), start=1):
            price = float(items.loc[items["product_id"] == pid, "list_price"].iloc[0])
            line_rows.append((f"{oid}-{j}", oid, pid, q, price, round(price * q, 2)))
    backend_lines = pd.DataFrame(line_rows, columns=[
        "order_item_id", "order_id", "product_id", "quantity", "unit_price", "line_revenue"])
    gross = backend_lines.groupby("order_id")["line_revenue"].sum()

    b = pd.DataFrame({
        "order_id": order_ids, "placed_at": placed_at, "user_pseudo_id": None,
        "customer_id": customer_id, "channel": channel, "payment_method": payment_method,
        "currency": "USD", "gross_revenue": pd.Series(order_ids).map(gross).round(2).to_numpy(),
        "discount_amount": 0.0, "country": pd.Series(customer_id).map(cust_country).to_numpy(),
    })
    b["loaded_at"] = b["placed_at"] + pd.to_timedelta(rng.integers(1, 21, n), unit="min")

    orders = pd.concat([orders, b[orders.columns]], ignore_index=True)
    print(f"[orders] {n:,} backend-only orders added ({n_new:,} new customers); "
          f"{len(orders):,} orders, {len(customers):,} customers")
    return orders, customers, backend_lines

def build_order_items(ga4, orders, backend_lines, products):
    pl = ga4["purchase_lines"].copy()
    keep = pl["order_id"].isin(orders["order_id"])          # drop lines of the ~5% removed in B1
    pl = pl.loc[keep].sort_values(["order_id", "item_id"]).reset_index(drop=True)
    pl["line_no"] = pl.groupby("order_id").cumcount() + 1
    seeded = pd.DataFrame({
        "order_item_id": pl["order_id"] + "-" + pl["line_no"].astype(str),
        "order_id":      pl["order_id"],
        "product_id":    pl["item_id"],
        "quantity":      pl["quantity"].astype(int),
        "unit_price":    pl["price"].astype(float),          # price on this purchase, not list_price
        "line_revenue":  pl["item_revenue"].astype(float),   # GA4 net line revenue, != price * qty
    })
    oi = pd.concat([seeded, backend_lines], ignore_index=True)

    assert oi["order_item_id"].is_unique
    assert oi["product_id"].isin(products["product_id"]).all(), "line with unknown product"
    assert orders["order_id"].isin(oi["order_id"]).all(), "order without lines"

    line_sum = oi.groupby("order_id")["line_revenue"].sum().round(2)
    gross = orders.set_index("order_id")["gross_revenue"].round(2)
    seeded_ids = orders.loc[orders["channel"] == "web", "order_id"]
    mismatch = (line_sum[seeded_ids] != gross[seeded_ids]).mean()
    print(f"[order_items] {len(oi):,} lines; {mismatch:.1%} of seeded orders have "
          f"sum(line_revenue) != gross_revenue")
    return oi

def inject_order_problems(orders, customers, cfg, rng):
    """EUR rows, duplicate customers, and the split into the two orders files.
    Returns (orders, customers, orders_2020, orders_2021, ledger)."""
    sh = cfg["shares"]
    ledger = {}

    # 1. currency mismatch: exactly N orders flagged EUR, amounts untouched
    eur_ids = rng.choice(orders["order_id"].to_numpy(), size=sh["eur_orders"], replace=False)
    orders.loc[orders["order_id"].isin(eur_ids), "currency"] = "EUR"
    ledger["eur_order_ids"] = sorted(eur_ids)

    # 2. duplicate customers: second row, same person, later orders re-pointed
    seeded = customers.loc[customers["user_pseudo_id"].notna()].sort_values("customer_id")
    dup_src = seeded.loc[rng.random(len(seeded)) < sh["duplicate_customers"]].copy()
    next_id = len(customers) + 1
    dup_src["new_customer_id"] = [f"C-{i:06d}" for i in range(next_id, next_id + len(dup_src))]
    dup_src["new_created_at"] = dup_src["created_at"] + pd.to_timedelta(rng.integers(1, 31, len(dup_src)), unit="D")
    dups = pd.DataFrame({
        "customer_id":      dup_src["new_customer_id"].to_numpy(),
        "user_pseudo_id":   dup_src["user_pseudo_id"].to_numpy(),
        "full_name":        dup_src["full_name"].to_numpy(),
        "email":            dup_src["email"].to_numpy(),
        "country":          dup_src["country"].to_numpy(),
        "email_consent":    dup_src["email_consent"].to_numpy(),
        "acquisition_date": dup_src["acquisition_date"].to_numpy(),
        "created_at":       dup_src["new_created_at"].to_numpy(),
        "loaded_at":        (dup_src["new_created_at"] + pd.to_timedelta(rng.integers(1, 31, len(dup_src)), unit="min")).to_numpy(),
    })
    customers = pd.concat([customers, dups], ignore_index=True)
    moved = 0
    for _, r in dup_src.iterrows():
        m = (orders["customer_id"] == r["customer_id"]) & (orders["placed_at"] >= r["new_created_at"])
        orders.loc[m, "customer_id"] = r["new_customer_id"]
        moved += int(m.sum())
    ledger["duplicate_customers"] = len(dups)
    ledger["orders_repointed_to_duplicates"] = moved

    # asserts before the split
    assert orders["order_id"].is_unique
    assert (orders["gross_revenue"] >= orders["discount_amount"]).all() and (orders["discount_amount"] >= 0).all()
    assert orders["customer_id"].isin(customers["customer_id"]).all()
    assert customers["customer_id"].is_unique
    assert orders["order_id"].str.startswith("B-").eq(orders["channel"] != "web").all()

    # 3. mid-history schema change: two files, one table
    cut = pd.Timestamp("2021-01-01", tz="UTC")
    early = orders["placed_at"] < cut
    orders_2020 = orders.loc[early].rename(columns={"country": "ship_country"}).reset_index(drop=True)
    orders_2021 = orders.loc[~early].rename(columns={"country": "shipping_country"}).reset_index(drop=True)

    print(f"[orders] {len(eur_ids)} EUR rows; {len(dups)} duplicate customers ({moved} orders re-pointed); "
          f"split {len(orders_2020):,} / {len(orders_2021):,} (ship_country / shipping_country)")
    return orders, customers, orders_2020, orders_2021, ledger

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
    
    orders, ga4_only_ids = build_orders_seeded(ga4, customers, cfg, rng, fake)
    orders, customers, backend_lines = build_orders_backend(ga4, orders, customers, products, cfg, rng, fake)
    order_items = build_order_items(ga4, orders, backend_lines, products)
    orders, customers, orders_2020, orders_2021, ledger = inject_order_problems(orders, customers, cfg, rng)


if __name__ == "__main__":
    main()