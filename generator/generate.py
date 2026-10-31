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

def build_orders_backend(ga4, orders, customers, products, cfg, rng, fake, forced):
    """B- orders GA4 never saw. Returns (orders, customers, backend_lines)."""
    sh = cfg["shares"]
    n_reg = round(sh["backend_only_orders"] * len(orders))
    n = n_reg + len(forced)

    base = orders["placed_at"].to_numpy()
    placed_reg = pd.to_datetime(rng.choice(base, size=n_reg)) + pd.to_timedelta(rng.integers(-720, 721, n_reg), unit="min")
    placed_at = pd.DatetimeIndex(np.concatenate([
        pd.to_datetime(forced["placed_at"], utc=True).to_numpy(),
        placed_reg.to_numpy()]))

    channel = rng.choice(["phone", "app"], size=n, p=[0.4, 0.6])
    pm_phone = ["card", "paypal", "invoice", "giftcard"]
    payment_method = np.where(
        channel == "phone",
        rng.choice(pm_phone, size=n, p=[0.45, 0.10, 0.40, 0.05]),
        rng.choice(pm_phone, size=n, p=[0.60, 0.30, 0.05, 0.05]))

    # customers: ~70% existing, ~30% new backend-only (no user_pseudo_id)

    new_mask = np.concatenate([np.zeros(len(forced), bool), rng.random(n_reg) < sh["backend_only_new_customer"]])
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
    customer_id[:len(forced)] = forced["customer_id"].to_numpy()
    customer_id[new_mask] = new_customers["customer_id"].to_numpy()
    reg_existing = ~new_mask.copy(); reg_existing[:len(forced)] = False
    customer_id[reg_existing] = rng.choice(customers["customer_id"].to_numpy(), size=int(reg_existing.sum()))
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

def apply_experiment(ga4, orders, customers, cfg, rng, fake):
    """Assign exposed users by seeded hash and decide which treatment users get an
    injected backend conversion. Returns (customers, experiment_assignments, forced)."""
    import hashlib
    ex = cfg["experiment"]; seed = cfg["seed"]
    pe = ga4["promo_exposure"].sort_values("user_pseudo_id").reset_index(drop=True)
    pe["first_exposure_at"] = pd.to_datetime(pe["first_exposure_at"], utc=True)
    pe["variant"] = ["treatment" if int(hashlib.sha256(f"{seed}:{u}".encode()).hexdigest(), 16) % 2 else "control"
                     for u in pe["user_pseudo_id"]]

    before, converted = experiment_conversion(pe, orders, customers, ex)
    n_t = int((pe["variant"] == "treatment").sum())
    k = int(round((before["control"] + ex["effect_pp"] - before["treatment"]) * n_t))

    targets = pe.loc[(pe["variant"] == "treatment") & ~pe["user_pseudo_id"].isin(converted)]
    pick = pe.set_index("user_pseudo_id").loc[np.sort(rng.choice(targets["user_pseudo_id"].to_numpy(), size=k, replace=False))]
    placed_at = pick["first_exposure_at"] + pd.to_timedelta(rng.uniform(0, ex["window_days"], k), unit="D")

    # customer rows for treatment users GA4 saw browsing but never buying
    existing = customers.set_index("user_pseudo_id")["customer_id"]
    need = [u for u in pick.index if u not in existing.index]
    n_new = len(need); next_id = len(customers) + 1
    created = placed_at.loc[need] - pd.to_timedelta(rng.integers(1, 181, n_new), unit="min")
    new_rows = pd.DataFrame({
        "customer_id":      [f"C-{i:06d}" for i in range(next_id, next_id + n_new)],
        "user_pseudo_id":   need,
        "full_name":        [fake.name() for _ in range(n_new)],
        "email":            [fake.email() for _ in range(n_new)],
        "country":          [fake.country_code() for _ in range(n_new)],
        "email_consent":    rng.choice(np.array(["true", "false", None], dtype=object), size=n_new,
                                       p=[0.55, 0.30, cfg["shares"]["consent_null"]]),
        "acquisition_date": created.dt.date.to_numpy(),
        "created_at":       created.to_numpy(),
        "loaded_at":        (created + pd.to_timedelta(rng.integers(1, 31, n_new), unit="min")).to_numpy(),
    })
    customers = pd.concat([customers, new_rows], ignore_index=True)
    cid = customers.set_index("user_pseudo_id")["customer_id"]
    forced = pd.DataFrame({"customer_id": pick.index.map(cid).to_numpy(), "placed_at": placed_at.to_numpy()})

    ea = pd.DataFrame({"experiment_id": ex["id"], "user_pseudo_id": pe["user_pseudo_id"], "variant": pe["variant"],
                       "assigned_at": pe["first_exposure_at"], "loaded_at": pe["first_exposure_at"] + pd.Timedelta(minutes=5)})
    print(f"[experiment] {len(pe):,} users; seeded conversion C {before['control']:.2%} / T {before['treatment']:.2%}; "
          f"forcing {k} treatment conversions ({n_new} new customers)")
    return customers, ea, forced, pe


def experiment_conversion(pe, orders, customers, ex):
    win = pd.Timedelta(days=ex["window_days"])
    oc = orders[["order_id", "customer_id", "placed_at"]].merge(
        customers[["customer_id", "user_pseudo_id"]], on="customer_id")
    oc = oc.merge(pe[["user_pseudo_id", "first_exposure_at", "variant"]], on="user_pseudo_id")
    hit = oc[(oc["placed_at"] >= oc["first_exposure_at"]) & (oc["placed_at"] < oc["first_exposure_at"] + win)]
    conv = pe["user_pseudo_id"].isin(hit["user_pseudo_id"])
    return pe.assign(c=conv).groupby("variant")["c"].mean(), set(hit["user_pseudo_id"])

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

PEAK_START, PEAK_END = pd.Timestamp("2020-12-07", tz="UTC"), pd.Timestamp("2020-12-24", tz="UTC")
ALLOWED = {("placed", "paid"), ("placed", "cancelled"), ("paid", "cancelled"), ("paid", "shipped"),
           ("shipped", "delivered"), ("delivered", "returned"), ("cancelled", "refunded"),
           ("returned", "refunded")}


def simulate_lifecycle(orders, cfg, rng):
    """Walk every order through domain_spec section 4.
    Returns a DataFrame of (order_id, status, event_ts, reason) with true UTC timestamps."""
    sh, lag = cfg["shares"], cfg["lags_days"]
    h = lambda x: pd.Timedelta(hours=int(x)); m = lambda x: pd.Timedelta(minutes=int(x)); d = lambda x: pd.Timedelta(days=int(x))
    rows = []
    for oid, placed in zip(orders["order_id"], orders["placed_at"]):
        rows.append((oid, "placed", placed, None))
        if rng.random() < sh["unpaid"]:
            rows.append((oid, "cancelled", placed + h(48), "payment_failed")); continue
        paid = placed + m(rng.integers(0, 31))
        rows.append((oid, "paid", paid, None))
        if rng.random() < sh["cancelled_after_paid"]:
            c_at = paid + h(rng.integers(1, 25))
            rows.append((oid, "cancelled", c_at, rng.choice(["customer_request", "out_of_stock", "fraud_check"])))
            rows.append((oid, "refunded", c_at + d(rng.integers(*lag["refund_after_trigger"])), None)); continue
        ship_lag = rng.integers(lag["paid_to_shipped"][0], lag["paid_to_shipped"][1] + 1)
        if PEAK_START <= paid < PEAK_END:
            ship_lag += rng.integers(lag["peak_extra_shipping"][0], lag["peak_extra_shipping"][1] + 1)
        shipped = paid + d(ship_lag)
        delivered = shipped + d(rng.integers(lag["shipped_to_delivered"][0], lag["shipped_to_delivered"][1] + 1))
        rows.append((oid, "shipped", shipped, None))
        if rng.random() < 0.02:
            continue
        rows.append((oid, "delivered", delivered, None))
    ev = pd.DataFrame(rows, columns=["order_id", "status", "event_ts", "reason"])
    ev["event_ts"] = pd.to_datetime(ev["event_ts"], utc=True)
    counts = ev["status"].value_counts()
    print(f"[lifecycle] {len(ev):,} events; cancelled {counts.get('cancelled', 0):,}, "
          f"delivered {counts.get('delivered', 0):,}")
    return ev

def build_returns_and_refunds(events, orders, order_items, products, cfg, rng):
    """Returns (events_with_return_rows, returns, refunds_df)."""
    sh, lag = cfg["shares"], cfg["lags_days"]
    d = lambda x: pd.to_timedelta(x, unit="D")
    o = orders.set_index("order_id")
    net = (o["gross_revenue"] - o["discount_amount"]).round(2)

    delivered = events.loc[events["status"] == "delivered", ["order_id", "event_ts"]].rename(columns={"event_ts": "delivered_at"})
    delivered = delivered.sort_values("order_id").reset_index(drop=True)
    pick = rng.random(len(delivered)) < sh["returned"]
    ret = delivered.loc[pick].reset_index(drop=True)
    n = len(ret)

    # line-level (~60%) or whole order (~40%)
    whole = rng.random(n) < 0.40
    lines_by_order = order_items.groupby("order_id")
    cat = products.set_index("product_id")["category"].fillna("")
    item_ids, amounts, reasons = [], [], []
    for oid, w in zip(ret["order_id"], whole):
        ls = lines_by_order.get_group(oid).sort_values("order_item_id")
        if w:
            item_ids.append(None); amounts.append(float(net[oid])); line_cat = cat[ls["product_id"].iloc[0]]
        else:
            r = ls.iloc[rng.integers(0, len(ls))]
            item_ids.append(r["order_item_id"]); amounts.append(float(r["line_revenue"])); line_cat = cat[r["product_id"]]
        lc = line_cat.lower()
        if "apparel" in lc:      p = [0.60, 0.10, 0.20, 0.10]
        elif "drinkware" in lc:  p = [0.05, 0.55, 0.30, 0.10]
        else:                    p = [0.10, 0.20, 0.55, 0.15]
        reasons.append(rng.choice(["wrong_size", "damaged", "changed_mind", "not_as_described"], p=p))

    ret["return_id"] = [f"R-{i:06d}" for i in range(1, n + 1)]
    ret["order_item_id"] = item_ids
    ret["requested_at"] = ret["delivered_at"] + d(rng.integers(1, lag["return_window"] + 1, n))
    ret["reason"] = reasons
    ret["accepted"] = rng.random(n) < sh["return_accepted"]
    ret["amount"] = amounts
    ret["loaded_at"] = ret["requested_at"] + pd.to_timedelta(rng.integers(1, 31, n), unit="min")

    # accepted returns add 'returned' and 'refunded' events
    acc = ret.loc[ret["accepted"]].copy()
    acc["returned_at"] = acc["requested_at"] + d(rng.integers(0, 3, len(acc)))
    acc["refunded_at"] = acc["returned_at"] + d(rng.integers(lag["refund_after_trigger"][0], lag["refund_after_trigger"][1] + 1, len(acc)))
    new_ev = pd.concat([
        pd.DataFrame({"order_id": acc["order_id"], "status": "returned", "event_ts": acc["returned_at"], "reason": acc["reason"]}),
        pd.DataFrame({"order_id": acc["order_id"], "status": "refunded", "event_ts": acc["refunded_at"], "reason": None}),
    ], ignore_index=True)
    events = pd.concat([events, new_ev], ignore_index=True)

    # refunds: one per 'refunded' event (cancellations + accepted returns), plus the bad ones
    canc = events.loc[(events["status"] == "refunded") & ~events["order_id"].isin(acc["order_id"]), ["order_id", "event_ts"]]
    refunds = pd.concat([
        pd.DataFrame({"order_id": canc["order_id"], "return_id": None, "amount": canc["order_id"].map(net).to_numpy(),
                      "refunded_at": canc["event_ts"].to_numpy()}),
        pd.DataFrame({"order_id": acc["order_id"], "return_id": acc["return_id"], "amount": acc["amount"],
                      "refunded_at": acc["refunded_at"]}),
    ], ignore_index=True)

    # bad refunds: order still 'shipped', no status event, no return
    last = events.sort_values("event_ts").groupby("order_id")["status"].last()
    shipped_only = sorted(last.index[last == "shipped"])
    n_bad = max(1, round(sh["bad_refunds"] * len(refunds)))
    bad_ids = rng.choice(shipped_only, size=n_bad, replace=False)
    shipped_at = events.loc[events["status"] == "shipped"].set_index("order_id")["event_ts"]
    bad = pd.DataFrame({"order_id": bad_ids, "return_id": None, "amount": pd.Series(bad_ids).map(net).to_numpy(),
                        "refunded_at": pd.to_datetime(pd.Series(bad_ids).map(shipped_at), utc=True) + d(rng.integers(2, 6, n_bad))})
    refunds = pd.concat([refunds, bad], ignore_index=True)

    refunds = refunds.sort_values(["refunded_at", "order_id"]).reset_index(drop=True)
    refunds["refund_id"] = [f"RF-{i:06d}" for i in range(1, len(refunds) + 1)]
    refunds["currency"] = refunds["order_id"].map(o["currency"])
    refunds["amount"] = refunds["amount"].round(2)
    refunds["loaded_at"] = pd.to_datetime(refunds["refunded_at"], utc=True) + pd.to_timedelta(rng.integers(1, 31, len(refunds)), unit="min")
    refunds = refunds[["refund_id", "order_id", "return_id", "amount", "currency", "refunded_at", "loaded_at"]]

    assert (refunds["amount"] <= refunds["order_id"].map(o["gross_revenue"]) + 0.01).all()
    assert ret["order_id"].isin(delivered["order_id"]).all()
    per_ret = refunds.groupby("return_id").size()
    assert (per_ret == 1).all() and set(per_ret.index) == set(acc["return_id"])
    print(f"[returns] {n:,} returns ({ret['accepted'].mean():.0%} accepted); "
          f"[refunds] {len(refunds):,} rows incl. {n_bad} bad (order still shipped)")
    returns = ret[["return_id", "order_id", "order_item_id", "requested_at", "reason", "accepted", "loaded_at"]]
    return events, returns, refunds

def build_nps(events_true, returns, orders, cfg, rng, fake):
    sh = cfg["shares"]
    d = lambda x: pd.to_timedelta(x, unit="D")
    ts = events_true.pivot_table(index="order_id", columns="status", values="event_ts", aggfunc="min")
    dl = ts.loc[ts["delivered"].notna(), ["shipped", "delivered"]].sort_index()
    n = len(dl)

    s = pd.DataFrame({
        "survey_id":   [f"S-{i:06d}" for i in range(1, n + 1)],
        "order_id":    dl.index,
        "customer_id": pd.Series(dl.index).map(orders.set_index("order_id")["customer_id"]).to_numpy(),
        "sent_at":     (dl["delivered"] + d(rng.integers(2, 5, n))).to_numpy(),
    })
    responded = rng.random(n) < sh["nps_response"]
    s["responded_at"] = pd.Series(s["sent_at"] + d(rng.integers(1, 8, n))).where(responded)

    # score bands: promoter 9-10 / passive 7-8 / detractor 0-6, shifted by slow shipping and returns
    ship_days = ((dl["delivered"] - dl["shipped"]).dt.total_seconds() / 86400).to_numpy()
    first_return = returns.groupby("order_id")["requested_at"].min()
    ret_before = (pd.Series(s["order_id"]).map(first_return).to_numpy() < s["responded_at"].to_numpy())
    p = np.tile([0.45, 0.30, 0.25], (n, 1))
    p[ship_days > 5] = [0.25, 0.30, 0.45]
    p[ret_before] = p[ret_before] + [-0.05, -0.05, 0.10]
    band = np.array([rng.choice(3, p=row) for row in p])
    lo, hi = np.array([9, 7, 0])[band], np.array([10, 8, 6])[band]
    score = rng.integers(lo, hi + 1).astype(float)
    s["score"] = np.where(responded, score, np.nan)
    verbatim = rng.random(n) < sh["nps_verbatim"]
    s["verbatim"] = [fake.sentence() if (r and v) else None for r, v in zip(responded, verbatim)]
    s["loaded_at"] = s["sent_at"] + pd.to_timedelta(rng.integers(1, 31, n), unit="min")

    assert s["score"].isna().eq(s["responded_at"].isna()).all()
    resp = s.loc[responded, "score"]
    nps = ((resp >= 9).mean() - (resp <= 6).mean()) * 100
    print(f"[nps] {n:,} surveys, {responded.mean():.0%} responded, NPS {nps:+.0f}")
    return s[["survey_id", "order_id", "customer_id", "sent_at", "responded_at", "score", "verbatim", "loaded_at"]]

def build_marketing_spend(ga4, cfg, rng):
    s = ga4["sessions_by_source"].copy().sort_values(["spend_date", "source", "medium", "campaign"]).reset_index(drop=True)
    n = len(s)
    rates = cfg["spend_per_session_usd"]
    paid = {"cpc", "cpm", "paid", "display", "affiliate"}
    unknown = {"(data deleted)", "(not set)"}

    def rate(src, med):
        if med not in paid or src in unknown or med in unknown:
            return 0.0
        return float(rates.get(f"{src}/{med}", rates["default_paid"]))

    per_session = np.array([rate(a, b) for a, b in zip(s["source"], s["medium"])])
    noise = rng.normal(1.0, 0.10, n)
    s["spend_usd"] = np.clip(s["sessions"] * per_session * noise, 0, None).round(2)
    s["loaded_at"] = pd.to_datetime(s["spend_date"]).dt.tz_localize("UTC") + pd.Timedelta(days=1, hours=6)
    out = s[["spend_date", "source", "medium", "campaign", "spend_usd", "loaded_at"]]
    print(f"[spend] {n:,} rows, {(out['spend_usd'] > 0).mean():.0%} with spend, "
          f"total ${out['spend_usd'].sum():,.0f}")
    return out

def finalize_status_events(ev, cfg, rng):
    """Ids, mixed raw formats, late loaded_at, transition check. Call after C2 appended return events."""
    sh = cfg["shares"]
    ev = ev.sort_values(["order_id", "event_ts"], kind="stable").reset_index(drop=True)
    n = len(ev)

    # transition check against domain_spec section 4
    prev = ev.groupby("order_id")["status"].shift()
    pairs = set(zip(prev.dropna(), ev.loc[prev.notna(), "status"]))
    bad = pairs - ALLOWED
    assert not bad, f"illegal transitions: {bad}"
    first = ev.groupby("order_id")["status"].first()
    assert (first == "placed").all() and (ev["status"].eq("placed").groupby(ev["order_id"]).sum() == 1).all()

    ev["event_id"] = [f"E-{i:07d}" for i in range(1, n + 1)]

    # mixed timestamp formats: ~10% as Europe/Berlin ISO with offset, rest as UTC 'YYYY-MM-DD HH:MM:SS'
    iso = rng.random(n) < sh["offset_timestamp_format"]
    utc_str = ev["event_ts"].dt.strftime("%Y-%m-%d %H:%M:%S")
    berlin_str = ev["event_ts"].dt.tz_convert("Europe/Berlin").dt.strftime("%Y-%m-%dT%H:%M:%S%z")
    berlin_str = berlin_str.str[:-2] + ":" + berlin_str.str[-2:]       # +0100 -> +01:00
    ev["event_ts_raw"] = np.where(iso, berlin_str, utc_str)

    # late-arriving: ~10% loaded 1-3 days late, the rest within 15 minutes
    late = rng.random(n) < sh["late_status_events"]
    lag_min = np.where(late, rng.integers(1, 4, n) * 1440, rng.integers(1, 16, n))
    ev["loaded_at"] = ev["event_ts"] + pd.to_timedelta(lag_min, unit="min")

    out = ev[["event_id", "order_id", "status", "event_ts_raw", "reason", "loaded_at"]]
    print(f"[status_events] {n:,} rows; {iso.mean():.1%} ISO+offset, {late.mean():.1%} late-loaded; transitions OK")
    return out, ev[["event_id", "order_id", "status", "event_ts"]]   # second frame: true timestamps for C2/C3 asserts


# --------------------------------------------------------------------------- #
# Schemas and the writer/loader
# --------------------------------------------------------------------------- #

from google.cloud.bigquery import SchemaField as F

SCHEMAS = {
    "customers": [F("customer_id", "STRING", "REQUIRED"), F("user_pseudo_id", "STRING"), F("full_name", "STRING"),
                  F("email", "STRING"), F("country", "STRING"), F("email_consent", "STRING"),
                  F("acquisition_date", "DATE"), F("created_at", "TIMESTAMP"), F("loaded_at", "TIMESTAMP")],
    "products": [F("product_id", "STRING", "REQUIRED"), F("product_name", "STRING"), F("variant", "STRING"),
                 F("category", "STRING"), F("list_price", "FLOAT64"), F("cost_price", "FLOAT64"),
                 F("supplier", "STRING"), F("launch_date", "DATE"), F("loaded_at", "TIMESTAMP")],
    "orders_2020": [F("order_id", "STRING", "REQUIRED"), F("customer_id", "STRING"), F("placed_at", "TIMESTAMP"),
                    F("channel", "STRING"), F("payment_method", "STRING"), F("currency", "STRING"),
                    F("gross_revenue", "FLOAT64"), F("discount_amount", "FLOAT64"), F("ship_country", "STRING"),
                    F("loaded_at", "TIMESTAMP")],
    "orders_2021": [F("order_id", "STRING", "REQUIRED"), F("customer_id", "STRING"), F("placed_at", "TIMESTAMP"),
                    F("channel", "STRING"), F("payment_method", "STRING"), F("currency", "STRING"),
                    F("gross_revenue", "FLOAT64"), F("discount_amount", "FLOAT64"), F("shipping_country", "STRING"),
                    F("loaded_at", "TIMESTAMP")],
    "order_items": [F("order_item_id", "STRING", "REQUIRED"), F("order_id", "STRING"), F("product_id", "STRING"),
                    F("quantity", "INTEGER"), F("unit_price", "FLOAT64"), F("line_revenue", "FLOAT64")],
    "order_status_events": [F("event_id", "STRING", "REQUIRED"), F("order_id", "STRING"), F("status", "STRING"),
                            F("event_ts_raw", "STRING"), F("reason", "STRING"), F("loaded_at", "TIMESTAMP")],
    "returns": [F("return_id", "STRING", "REQUIRED"), F("order_id", "STRING"), F("order_item_id", "STRING"),
                F("requested_at", "TIMESTAMP"), F("reason", "STRING"), F("accepted", "BOOLEAN"), F("loaded_at", "TIMESTAMP")],
    "refunds": [F("refund_id", "STRING", "REQUIRED"), F("order_id", "STRING"), F("return_id", "STRING"),
                F("amount", "FLOAT64"), F("currency", "STRING"), F("refunded_at", "TIMESTAMP"), F("loaded_at", "TIMESTAMP")],
    "nps_surveys": [F("survey_id", "STRING", "REQUIRED"), F("order_id", "STRING"), F("customer_id", "STRING"),
                    F("sent_at", "TIMESTAMP"), F("responded_at", "TIMESTAMP"), F("score", "INTEGER"),
                    F("verbatim", "STRING"), F("loaded_at", "TIMESTAMP")],
    "marketing_spend": [F("spend_date", "DATE"), F("source", "STRING"), F("medium", "STRING"), F("campaign", "STRING"),
                        F("spend_usd", "FLOAT64"), F("loaded_at", "TIMESTAMP")],
    "experiment_assignments": [F("experiment_id", "STRING"), F("user_pseudo_id", "STRING"), F("variant", "STRING"),
                               F("assigned_at", "TIMESTAMP"), F("loaded_at", "TIMESTAMP")],
}


def write_csvs(frames: dict[str, pd.DataFrame], ga4_only_ids: pd.DataFrame) -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, df in frames.items():
        df.to_csv(OUTPUT / f"{name}.csv", index=False, date_format="%Y-%m-%dT%H:%M:%SZ")
    ga4_only_ids.to_csv(OUTPUT / "_ga4_only_ids.csv", index=False)
    print(f"[write] {len(frames)} files to {OUTPUT.relative_to(HERE.parent)}/")


def load_raw(client: bigquery.Client, dataset: str, frames: dict[str, pd.DataFrame]) -> None:
    def load(df, table, schema, write="WRITE_TRUNCATE", allow_add=False):
        cfg_ = bigquery.LoadJobConfig(schema=schema, write_disposition=write)
        if allow_add:
            cfg_.schema_update_options = [bigquery.SchemaUpdateOption.ALLOW_FIELD_ADDITION]
        df = df.copy()
        for f in schema:
            if f.field_type == "INTEGER": df[f.name] = df[f.name].astype("Int64")
            if f.field_type == "BOOLEAN": df[f.name] = df[f.name].astype("boolean")
            if f.field_type == "TIMESTAMP": df[f.name] = pd.to_datetime(df[f.name], utc=True).dt.floor("us")
        client.load_table_from_dataframe(df, f"{dataset}.{table}", job_config=cfg_).result()
        print(f"[load] {dataset}.{table} <- {len(df):,} rows ({write})")

    load(frames["orders_2020"], "orders", SCHEMAS["orders_2020"])
    load(frames["orders_2021"], "orders", SCHEMAS["orders_2021"], write="WRITE_APPEND", allow_add=True)
    for name in ["customers", "products", "order_items", "order_status_events", "returns",
                 "refunds", "nps_surveys", "marketing_spend", "experiment_assignments"]:
        load(frames[name], name, SCHEMAS[name])

# --------------------------------------------------------------------------- #

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(HERE / "config.yml"))
    ap.add_argument("--no-load", action="store_true", help="write CSVs only, skip the BigQuery load")
    args = ap.parse_args()

    cfg = load_config(Path(args.config))
    rng, fake = make_random(cfg["seed"])
    client = bigquery.Client(project=cfg["bigquery"]["project"], location="US")

    ga4 = extract_ga4(client)
    products = build_products(ga4, cfg, rng, fake)
    customers = build_customers(ga4, cfg, rng, fake)
    
    orders, ga4_only_ids = build_orders_seeded(ga4, customers, cfg, rng, fake)
    customers, experiment_assignments, forced, pe = apply_experiment(ga4, orders, customers, cfg, rng, fake)
    orders, customers, backend_lines = build_orders_backend(ga4, orders, customers, products, cfg, rng, fake, forced)
    after, _ = experiment_conversion(pe, orders, customers, cfg["experiment"])
    print(f"[experiment] after: C {after['control']:.2%} / T {after['treatment']:.2%} "
          f"(+{(after['treatment'] - after['control']) * 100:.2f} pp)")

    order_items = build_order_items(ga4, orders, backend_lines, products)
    orders, customers, orders_2020, orders_2021, ledger = inject_order_problems(orders, customers, cfg, rng)
    events = simulate_lifecycle(orders, cfg, rng)
    events, returns, refunds = build_returns_and_refunds(events, orders, order_items, products, cfg, rng)
    status_events, events_true = finalize_status_events(events, cfg, rng)
    nps_surveys = build_nps(events_true, returns, orders, cfg, rng, fake)
    marketing_spend = build_marketing_spend(ga4, cfg, rng)

    frames = {
        "customers": customers, "products": products,
        "orders_2020": orders_2020, "orders_2021": orders_2021,
        "order_items": order_items, "order_status_events": status_events,
        "returns": returns, "refunds": refunds, "nps_surveys": nps_surveys,
        "marketing_spend": marketing_spend, "experiment_assignments": experiment_assignments,
    }
    write_csvs(frames, ga4_only_ids)
    if not args.no_load:
        load_raw(client, cfg["bigquery"]["dataset"], frames)
    


if __name__ == "__main__":
    main()