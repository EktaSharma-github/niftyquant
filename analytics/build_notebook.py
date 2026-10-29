"""Builds niftyquant_kmeans.ipynb from the cells below.

Run:  .venv\\Scripts\\python analytics\\build_notebook.py
then: .venv\\Scripts\\jupyter nbconvert --to notebook --execute --inplace analytics\\niftyquant_kmeans.ipynb
"""
from pathlib import Path

import nbformat as nbf

HERE = Path(__file__).parent
READINGS = HERE / "readings.md"      # interpretation text, written after reading the results
cells = []


def md(text):
    cells.append(nbf.v4.new_markdown_cell(text.strip()))


def code(text):
    cells.append(nbf.v4.new_code_cell(text.strip()))


def reading(key):
    """Insert the "@@ key" section of readings.md, if it exists."""
    if not READINGS.exists():
        return
    txt = READINGS.read_text(encoding="utf-8")
    parts = {p.split("\n", 1)[0].strip(): p.split("\n", 1)[1] for p in txt.split("\n@@ ")[1:]}
    if key in parts:
        md(parts[key])


md("""
# NiftyQuant Analytics: Momentum, Risk and the Shapes of Indian Stocks

**FDS course project (NiftyQuant).** The database holds every NSE cash-market trade summary
from January 2010 to October 2026: 7.3 million daily prices for 3,865 securities, adjusted for
1,500 splits, bonuses and rights issues parsed from NSE's own corporate-action feed, in a
BCNF schema whose triggers stop look-ahead bias getting into the backtest. This notebook asks:

> 1. **How do Indian stock returns behave?** Fat tails, liquidity, risk by sector.
> 2. **Does momentum work in India, and when does it fail?**
> 3. **What kinds of stocks are there?** k-means on risk/return behaviour, and which kind
>    protects you when the market falls.

**Workflow**

1. **SQL first.** Statistics run *inside PostgreSQL* (`07_analytics.sql`, A1–A5, and the
   backtest views of `03_logic.sql`). Only aggregates leave the database.
2. **Statistical tests** on those aggregates (t-tests, bootstrap, χ²).
3. **Feature engineering in SQL.** `v_stock_features` turns 60 months of prices into one row
   per stock in today's universe.
4. **k-means** on standardized features; *k* chosen by elbow, silhouette and interpretability.
5. **Write back** the labels to the BCNF tables `segment` / `security_segment`, then answer
   S1–S2 in SQL.

*Data: NSE India bhavcopy and corporate-action archives; index levels from Yahoo Finance.
Research use only; not investment advice.*
""")

md("""
## 0. Setup

Reads use the role **`niftyquant_readonly`** (SELECT only). Only the write-back in §5 connects as
the owner: least privilege. `run_sql()` runs one labelled query from `07_analytics.sql`, so the
SQL on the slides and the SQL executed here are the same text.
""")

code(r'''
import os
import re
import warnings

os.environ.setdefault("LOKY_MAX_CPU_COUNT", "4")   # stops joblib probing the CPU count on Windows
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy import stats
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from sqlalchemy import create_engine, text

warnings.filterwarnings("ignore", category=UserWarning)
pd.set_option("display.width", 160)

OPTS = {"options": "-c search_path=niftyquant,public"}
reader = create_engine("postgresql+psycopg://niftyquant_readonly:readonly@localhost/niftyquant", connect_args=OPTS)
writer = create_engine("postgresql+psycopg://postgres:postgres@localhost/niftyquant", connect_args=OPTS)

ROOT = Path.cwd() if (Path.cwd() / "07_analytics.sql").exists() else Path.cwd().parent
SQL_FILE = ROOT / "07_analytics.sql"
FIG = ROOT / "analytics" / "figures"
FIG.mkdir(parents=True, exist_ok=True)

# A labelled query in 07_analytics.sql is a "-- A1. TITLE" header block,
# closed by a "-- ====" line, followed by one statement ending in ";".
_QUERY = re.compile(r"^-- ([AS]\d)\. ([^\n]*)\n.*?^-- =+\n\n(.*?;)\s*$", re.M | re.S)
QUERIES = {m[1]: (m[2].strip(), m[3]) for m in _QUERY.finditer(SQL_FILE.read_text(encoding="utf-8"))}

def run_sql(label):
    title, sql = QUERIES[label]
    print(f"{label}. {title}")
    return num(query(sql))

def query(sql, **params):
    with reader.connect() as c:
        return pd.read_sql(text(sql), c, params=params)

def num(df):
    """NUMERIC columns arrive as Decimal objects: make them floats."""
    for c in df.columns:
        if df[c].dtype == object:
            try:
                df[c] = pd.to_numeric(df[c])
            except (ValueError, TypeError):
                pass
    return df

def month_label(n):
    """month_no (year*12 + month) -> Timestamp of that month's first day."""
    n = int(n)
    return pd.Timestamp(year=(n - 1) // 12, month=(n - 1) % 12 + 1, day=1)

print("Queries found:", ", ".join(QUERIES))
''')

code(r'''
# Chart style: one recessive grid, thin marks, text in ink colours (never series colours).
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
BLUE, ORANGE, AQUA, YELLOW, RED, MID = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e34948", "#f0efec"
PALETTE = [BLUE, ORANGE, AQUA, YELLOW, RED]
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "axes.titleweight": "bold", "axes.titlesize": 12, "axes.titlelocation": "left",
    "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
    "axes.grid": True, "axes.axisbelow": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 10, "figure.dpi": 110,
})

def save(fig, name):
    fig.savefig(FIG / f"{name}.png", dpi=200, bbox_inches="tight")
''')

code(r'''
# What is in the database
query("""
SELECT (SELECT count(*) FROM trading_day)                       AS trading_days,
       (SELECT min(trade_date) FROM trading_day)                AS first_day,
       (SELECT max(trade_date) FROM trading_day)                AS last_day,
       (SELECT count(*) FROM security)                          AS securities,
       (SELECT count(*) FROM daily_price)                       AS daily_prices,
       (SELECT count(*) FROM price_adjustment)                  AS adjustments,
       (SELECT count(DISTINCT month_end) FROM universe_member)  AS universe_months
""")
''')

md("""
## 1. How do Indian stock returns behave? (SQL statistics)

### A1. Are monthly returns normal?
""")

code('a1 = run_sql("A1"); a1')

code(r'''
r = num(query("""
    SELECT m.ret FROM universe_member u
    JOIN mv_monthly_return m ON m.security_id = u.security_id AND m.month_no = month_no(u.month_end) + 1"""))["ret"]
clip = r.clip(-0.6, 0.6)
fig, ax = plt.subplots(figsize=(7.2, 3.4))
ax.hist(clip, bins=120, density=True, color=BLUE, alpha=0.85, label="Universe stocks, next-month return")
x = np.linspace(-0.6, 0.6, 400)
ax.plot(x, stats.norm.pdf(x, r.mean(), r.std()), color=ORANGE, lw=2, label="Normal with the same mean and SD")
ax.set_xlabel("Monthly return (clipped at ±60%)"); ax.set_ylabel("Density"); ax.grid(axis="x", visible=False)
ax.legend(frameon=False, fontsize=8)
ax.set_title("Monthly stock returns: a taller peak and fatter tails than a normal")
save(fig, "01_return_distribution"); plt.show()
jb = stats.jarque_bera(r)
print(f"n = {len(r):,}; Jarque-Bera = {jb.statistic:,.0f}, p = {jb.pvalue:.1e}")
''')
reading("A1")

md("""
### A5. Do less liquid stocks earn more?
""")

code('a5 = run_sql("A5"); a5')
reading("A5")

md("""
### A4. Market beta by sector (last 60 months)
""")

code('a4 = run_sql("A4"); a4')

code(r'''
d = a4[a4.sector != "ALL NIFTY 500 STOCKS"].sort_values("median_beta")
overall = float(a4.loc[a4.sector == "ALL NIFTY 500 STOCKS", "median_beta"].iloc[0])
fig, ax = plt.subplots(figsize=(7.2, 5.2))
ax.barh(d.sector, d.median_beta, color=[ORANGE if b > 1 else BLUE for b in d.median_beta])
ax.axvline(1, color=INK2, ls="--", lw=1); ax.axvline(overall, color=INK2, ls=":", lw=1)
ax.annotate("β = 1 (moves with the market)", (1.01, -0.6), color=INK2, fontsize=8)
ax.set_xlabel("Median beta vs NIFTY 500 (monthly, last 60 months)"); ax.grid(axis="y", visible=False)
ax.set_title("Which sectors amplify the market, which damp it")
save(fig, "02_sector_beta"); plt.show()
''')
reading("A4")

md("""
## 2. Does momentum work in India?

The backtest is built in SQL (`03_logic.sql`): at every month-end, the 500 most liquid shares
*as known that day* are ranked on their return over the past 12 months excluding the latest
one (12-1 momentum), split into deciles, and held for the next month, equally weighted.
Triggers and a composite FK make it impossible for a holding to be a stock that was not in
that day's universe (no look-ahead).

### 2.1 The decile scorecard
""")

code(r'''
dec = num(query("""
    SELECT r.bucket, r.holding_month_no, r.ret
    FROM v_portfolio_return r JOIN strategy s USING (strategy_id)
    WHERE s.strategy_code = 'MOM_12_1'"""))
idx = num(query("SELECT month_no AS holding_month_no, ret AS nifty FROM v_index_monthly_return WHERE index_code = 'NIFTY500'"))
wide = dec.pivot(index="holding_month_no", columns="bucket", values="ret").merge(idx, on="holding_month_no").set_index("holding_month_no")
wide["WML"] = wide[10] - wide[1]

def scorecard(s):
    s = s.dropna()
    w = (1 + s).cumprod()
    return pd.Series({"months": len(s), "CAGR %": 100 * (w.iloc[-1] ** (12 / len(s)) - 1),
                      "vol %": 100 * s.std() * np.sqrt(12), "Sharpe (rf=0)": s.mean() / s.std() * np.sqrt(12),
                      "max DD %": 100 * (w / w.cummax() - 1).min()})
cols = list(range(1, 11)) + ["WML", "nifty"]
sc = pd.DataFrame({c: scorecard(wide[c]) for c in cols}).T.round(2)
sc.index = [f"D{c:02d}" if isinstance(c, int) else ("NIFTY 500" if c == "nifty" else "WML (D10-D01)") for c in cols]
sc
''')

code(r'''
fig, axes = plt.subplots(1, 2, figsize=(11, 3.8), gridspec_kw={"width_ratios": [1, 1.4]})
ax = axes[0]
c = sc.iloc[:10]
ax.bar(range(1, 11), c["CAGR %"], color=[RED if v < 0 else BLUE for v in c["CAGR %"]])
ax.axhline(sc.loc["NIFTY 500", "CAGR %"], color=INK2, ls="--", lw=1)
ax.annotate("NIFTY 500", (0.6, sc.loc["NIFTY 500", "CAGR %"] + 1), color=INK2, fontsize=8)
ax.set_xticks(range(1, 11)); ax.set_xlabel("Momentum decile (1 = last year's losers, 10 = winners)")
ax.set_ylabel("CAGR %"); ax.grid(axis="x", visible=False)
ax.set_title("Return rises with past return")

ax = axes[1]
dates = [month_label(n) for n in wide.index]
for col, lab, colr in [(10, "Winners (D10)", BLUE), ("nifty", "NIFTY 500", INK2), (1, "Losers (D01)", RED)]:
    ax.plot(dates, (1 + wide[col].fillna(0)).cumprod(), color=colr, lw=1.8, label=lab)
ax.set_yscale("log"); ax.set_ylabel("Growth of ₹1 (log scale)")
ax.legend(frameon=False, fontsize=8, loc="upper left")
ax.set_title("₹1 in each portfolio, before costs")
fig.tight_layout(); save(fig, "03_momentum_deciles"); plt.show()
''')

md("""
Is the winners-minus-losers premium distinguishable from zero? A t-test assumes monthly
returns are independent and roughly normal (A1 says they're not normal), so we also
bootstrap the mean: resample the months 10,000 times.
""")

code(r'''
w = wide["WML"].dropna()
t, p = stats.ttest_1samp(w, 0)
rng = np.random.default_rng(42)
boot = rng.choice(w.values, size=(10_000, len(w)), replace=True).mean(axis=1)
lo, hi = np.percentile(boot, [2.5, 97.5])
print(f"WML: mean {100 * w.mean():.2f}% a month over {len(w)} months; t = {t:.2f}, p = {p:.1e}")
print(f"Bootstrap 95% CI for the monthly mean: [{100 * lo:.2f}%, {100 * hi:.2f}%]")
''')
reading("2.1")

md("""
### A2. Does the signal rank next month's returns? (information coefficient)
""")

code('a2 = run_sql("A2"); a2')
reading("A2")

md("""
### A3. When does momentum crash?
""")

code('a3 = run_sql("A3"); a3')

code(r'''
fig, ax = plt.subplots(figsize=(7.2, 3.4))
roll = wide["WML"].rolling(12).apply(lambda s: (1 + s).prod() - 1)
ax.fill_between(dates, 100 * roll, 0, where=roll >= 0, color=BLUE, alpha=0.6, lw=0)
ax.fill_between(dates, 100 * roll, 0, where=roll < 0, color=RED, alpha=0.7, lw=0)
ax.axhline(0, color=INK2, lw=0.8); ax.set_ylabel("Trailing 12-month WML return %")
ax.set_title("Momentum pays most of the time, and gives back in sharp rebounds")
save(fig, "04_wml_rolling"); plt.show()
''')
reading("A3")

md("""
### 2.2 Survivorship bias, measured (query Q2 of `05_queries.sql`)

The same universe, restricted to the stocks still listed today, is what a backtest built
from today's index list would see.
""")

code(r'''
q2 = num(query("""
WITH survivor AS (
    SELECT DISTINCT p.security_id FROM daily_price p
    WHERE p.trade_date >= (SELECT min(trade_date) FROM (SELECT trade_date FROM trading_day
                                                         ORDER BY trade_date DESC LIMIT 10) t)
), monthly AS (
    SELECT u.month_end, avg(m.ret) AS all_members,
           avg(m.ret) FILTER (WHERE s.security_id IS NOT NULL) AS survivors_only
    FROM universe_member u
    JOIN mv_monthly_return m ON m.security_id = u.security_id AND m.month_no = month_no(u.month_end) + 1
    LEFT JOIN survivor s ON s.security_id = u.security_id
    GROUP BY u.month_end)
SELECT * FROM monthly ORDER BY month_end"""))
g = (1 + q2[["all_members", "survivors_only"]]).cumprod()
yrs = len(q2) / 12
cagr = 100 * (g.iloc[-1] ** (1 / yrs) - 1)
print(f"Equal-weighted universe CAGR {cagr.all_members:.1f}%   survivors only {cagr.survivors_only:.1f}%"
      f"   -> bias {cagr.survivors_only - cagr.all_members:.1f} points a year")
fig, ax = plt.subplots(figsize=(7.2, 3.2))
ax.plot(q2.month_end, g.survivors_only, color=ORANGE, lw=1.8, label="Survivors only (what today's list shows)")
ax.plot(q2.month_end, g.all_members, color=BLUE, lw=1.8, label="Point-in-time universe (what was investable)")
ax.set_yscale("log"); ax.set_ylabel("Growth of ₹1 (log)"); ax.legend(frameon=False, fontsize=8)
ax.set_title("Survivorship bias: the gap is the stocks that later disappeared")
save(fig, "05_survivorship"); plt.show()
''')
reading("2.2")

md("""
## 3. What kinds of stocks are there? (k-means)

`v_stock_features` gives one row per stock in today's 500-stock universe with at least 48 of
the last 60 full months: **annualized return** and **volatility**, **beta**, **maximum drawdown**,
**dividend yield** (total minus price return), **liquidity** (log of average daily ₹ traded)
and **winner share** (share of months in the top 3 momentum deciles).

### 3.1 Features
""")

code(r'''
FEATURES = ["ann_return", "ann_vol", "beta", "max_drawdown", "dividend_yield", "ln_liquidity", "winner_share"]
stk = num(query("""SELECT f.*, v.symbol, v.security_name, coalesce(v.sector_name, '(unclassified)') AS sector
                   FROM v_stock_features f JOIN v_security v USING (security_id)"""))
print(len(stk), "stocks")
stk[FEATURES].describe().round(3)
''')

code(r'''
corr = stk[FEATURES].corr()
fig, ax = plt.subplots(figsize=(5.6, 4.6))
im = ax.imshow(corr, cmap="RdBu_r", vmin=-1, vmax=1)
n = len(FEATURES)
ax.set_xticks(range(n), FEATURES, rotation=40, ha="right"); ax.set_yticks(range(n), FEATURES)
for i in range(n):
    for j in range(n):
        ax.text(j, i, f"{corr.iloc[i, j]:.2f}", ha="center", va="center", fontsize=8,
                color="white" if abs(corr.iloc[i, j]) > 0.6 else INK)
ax.grid(False); ax.set_title("Feature correlations")
fig.colorbar(im, ax=ax, shrink=0.8); save(fig, "06_feature_correlation"); plt.show()
''')
reading("3.1")

md("""
### 3.2 Choosing k
""")

code(r'''
X = StandardScaler().fit_transform(stk[FEATURES])
rows = []
for k in range(2, 9):
    km = KMeans(n_clusters=k, n_init=50, random_state=42).fit(X)
    rows.append((k, km.inertia_, silhouette_score(X, km.labels_)))
kres = pd.DataFrame(rows, columns=["k", "inertia", "silhouette"])
kres.round(3)
''')
reading("3.2")

code(r'''
K = 4
km = KMeans(n_clusters=K, n_init=50, random_state=42).fit(X)
stk["cluster"] = km.labels_
stk["distance"] = np.linalg.norm(X - km.cluster_centers_[km.labels_], axis=1)
centroids = stk.groupby("cluster")[FEATURES].mean()
centroids.assign(stocks=stk.groupby("cluster").size()).round(3)
''')

code(r'''
# Name clusters by rules on the centroids, not by k-means' arbitrary label numbers
names, left = {}, set(centroids.index)
def take(col, how, name):
    sub = centroids.loc[sorted(left), col]
    c = sub.idxmax() if how == "max" else sub.idxmin()
    names[c] = name; left.discard(c)
take("winner_share", "max", "Momentum Leaders")
take("dividend_yield", "max", "Dividend Yielders")
take("ann_vol", "min", "Defensive Compounders")
take("ann_return", "min", "Volatile Laggards")
stk["segment"] = stk["cluster"].map(names)

DESC = {
    "Momentum Leaders": "Two-thirds of the last five years in the top momentum deciles: the highest returns, high beta, rallies hardest in up months.",
    "Dividend Yielders": "The highest dividend yields and the most liquid: mostly public-sector energy, metals and banks.",
    "Defensive Compounders": "The lowest volatility, beta about 1 and the shallowest drawdowns, with steady mid-teens returns.",
    "Volatile Laggards": "High volatility and beta, the deepest drawdowns and the weakest returns: they fall hardest when the market falls.",
}
profile = stk.groupby("segment")[FEATURES].mean().round(3).assign(stocks=stk.groupby("segment").size()).loc[list(DESC)]
profile
''')

code(r'''
for seg, g in stk.sort_values("distance").groupby("segment"):
    print(f"{seg:22s} {', '.join(g.symbol.head(10))}")
''')

code(r'''
fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
ax = axes[0]
ax.plot(kres.k, kres.inertia, color=BLUE, marker="o", lw=2); ax.set_xlabel("k"); ax.set_ylabel("Inertia (within-cluster SS)")
ax2 = ax.twinx(); ax2.plot(kres.k, kres.silhouette, color=ORANGE, marker="s", lw=2)
ax2.set_ylabel("Silhouette"); ax2.grid(False); ax2.spines["right"].set_visible(True)
ax.axvline(K, color=INK2, ls="--", lw=1); ax.set_title(f"Choosing k (k = {K})")
pca = PCA(2).fit(X); P = pca.transform(X)
ax = axes[1]
for i, seg in enumerate(DESC):
    m = (stk.segment == seg).values
    ax.scatter(P[m, 0], P[m, 1], s=18, color=PALETTE[i], label=seg, edgecolor=SURFACE, lw=0.4)
for _, r in stk.loc[stk.groupby("segment")["distance"].idxmin()].iterrows():
    ax.annotate(r.symbol, P[r.name], xytext=(4, 4), textcoords="offset points", fontsize=8, color=INK)
ax.set_xlabel(f"PC1 ({pca.explained_variance_ratio_[0]:.0%} of variance)")
ax.set_ylabel(f"PC2 ({pca.explained_variance_ratio_[1]:.0%})")
ax.legend(frameon=False, fontsize=8); ax.set_title("Four kinds of stock (PCA view; most typical named)")
fig.tight_layout(); save(fig, "07_segments"); plt.show()
''')

code(r'''
z = pd.DataFrame(X, columns=FEATURES).assign(segment=stk.segment.values).groupby("segment").mean().loc[list(DESC)]
fig, ax = plt.subplots(figsize=(7.6, 2.8))
im = ax.imshow(z, cmap="RdBu_r", vmin=-2, vmax=2, aspect="auto")
ax.set_xticks(range(len(FEATURES)), FEATURES, rotation=25, ha="right"); ax.set_yticks(range(K), z.index)
for i in range(K):
    for j in range(len(FEATURES)):
        ax.text(j, i, f"{z.iloc[i, j]:+.1f}", ha="center", va="center", fontsize=8, color="white" if abs(z.iloc[i, j]) > 1.2 else INK)
ax.grid(False); ax.set_title("Segment fingerprints (centroids in SD units)")
fig.colorbar(im, ax=ax, shrink=0.8); save(fig, "08_fingerprints"); plt.show()
''')
reading("3.3")

md("""
### 3.3 Validation with a variable the model never saw: sector

The model saw only price behaviour, never the sector. If the segments are real economic
groupings, sector membership should not be independent of segment. χ² test of independence
on the sector × segment table (sectors with fewer than 10 stocks pooled).
""")

code(r'''
sec = stk.sector.where(stk.sector.map(stk.sector.value_counts()) >= 10, "Other (small sectors)")
ct = pd.crosstab(sec, stk.segment)[list(DESC)]
chi2, p, dof, _ = stats.chi2_contingency(ct)
cramers_v = np.sqrt(chi2 / (ct.values.sum() * (min(ct.shape) - 1)))
print(f"chi2 = {chi2:.1f}, dof = {dof}, p = {p:.1e}, Cramér's V = {cramers_v:.2f}")
ct
''')
reading("3.4")

md("""
## 4. Write the segments back to the database

The labels go into `segment` and `security_segment`, so SQL can use them. This is the only
step that connects as the owner, and it runs in one transaction: a failure leaves the old
segments in place.
""")

code(r'''
with writer.begin() as c:
    c.execute(text("DELETE FROM segment"))                # cascades to security_segment
    ids = {seg: c.execute(text("INSERT INTO segment (segment_name, description) VALUES (:n, :d) RETURNING segment_id"),
                          {"n": seg, "d": d}).scalar_one()
           for seg, d in DESC.items()}
    c.execute(text("INSERT INTO security_segment VALUES (:s, :g, :dist)"),
              [{"s": int(r.security_id), "g": ids[r.segment], "dist": round(float(r.distance), 3)}
               for r in stk.itertuples()])
query("SELECT segment_name, stocks, left(most_typical, 80) AS most_typical FROM v_segment_profile ORDER BY stocks DESC")
''')

md("""
## 5. Using the segments in SQL

### S1. Which sectors fall into which segment?
""")

code(r'''
s1 = run_sql("S1")
mix = s1.pivot(index="sector", columns="segment_name", values="share_of_sector_pct").fillna(0)[list(DESC)]
mix = mix.loc[s1.groupby("sector")["stocks"].sum().loc[mix.index].sort_values().index]
fig, ax = plt.subplots(figsize=(7.6, 5.4))
left_ = np.zeros(len(mix))
for i, seg in enumerate(mix.columns):
    ax.barh(mix.index, mix[seg], left=left_, color=PALETTE[i], label=seg, edgecolor=SURFACE)
    left_ += mix[seg].values
ax.set_xlabel("% of the sector's stocks"); ax.set_xlim(0, 100); ax.grid(axis="y", visible=False)
ax.legend(frameon=False, fontsize=8, ncol=2, loc="upper center", bbox_to_anchor=(0.5, -0.1))
ax.set_title("Segment mix by sector (sectors ordered by size)")
save(fig, "09_sector_mix"); plt.show()
''')
reading("S1")

md("""
### S2. Which segment protects you when the market falls?
""")

code('s2 = run_sql("S2"); s2')

code(r'''
d = s2.set_index("segment_name").loc[list(DESC)]
fig, ax = plt.subplots(figsize=(7.2, 3.2))
y = np.arange(len(d))
ax.barh(y - 0.2, d.avg_in_down_months_pct, 0.4, color=RED, label="Market down > 3%")
ax.barh(y + 0.2, d.avg_in_up_months_pct, 0.4, color=BLUE, label="Market up > 3%")
ax.axvline(d.nifty500_down_pct.iloc[0], color=RED, ls=":", lw=1)
ax.axvline(d.nifty500_up_pct.iloc[0], color=BLUE, ls=":", lw=1)
ax.set_yticks(y, d.index); ax.invert_yaxis(); ax.set_xlabel("Average monthly return % (dotted: NIFTY 500)")
ax.axvline(0, color=INK2, lw=0.8); ax.grid(axis="y", visible=False); ax.legend(frameon=False, fontsize=8)
ax.set_title("Downside and upside: each segment in big market months")
save(fig, "10_downside_upside"); plt.show()
''')
reading("S2")

reading("Conclusions")

nb = nbf.v4.new_notebook()
nb["cells"] = cells
# Kernel = NiftyQuant/.venv (registered once with: .venv\Scripts\python -m ipykernel install --user --name niftyquant)
nb["metadata"]["kernelspec"] = {"name": "niftyquant", "display_name": "NiftyQuant (.venv)", "language": "python"}
out = HERE / "niftyquant_kmeans.ipynb"
nbf.write(nb, out)
print("wrote", out)
