# NiftyQuant — NSE Equity Market & Momentum Research Database

A PostgreSQL database of every NSE cash-market stock from January 2010 to October 2026 (4,176 trading days, 3,865 securities, 7.3 million daily prices), normalized to BCNF. Identities are resolved over time, prices are adjusted from NSE's own corporate-action notices, and triggers make look-ahead bias impossible. On top: a point-in-time momentum backtest written in SQL, SQL statistics, and k-means clustering of stocks by risk/return behaviour.

FDS (DBMS) course project, PGDBA, IIM Calcutta.

## Headline results

| | CAGR, Jan 2011 – Oct 2026 |
|---|---|
| Last year's winners (12-1 momentum, top decile of the 500 most liquid) | **+26.3%** |
| Last year's losers (bottom decile) | **−7.0%** |
| NIFTY 500 | +9.9% |

Winners-minus-losers: 2.34% a month, t = 4.5, but only after rising markets: 3.13% a month after a year in which the NIFTY 500 rose, nothing after a falling year. It is not market risk (beta −0.51), it fades slowly without reversing, and it has shrunk since 2011. A backtest on today's survivors would have added 2.4 points a year that never existed. Gross, price-only, equal-weighted; research use only, not investment advice.

## What's inside

| File | Contents |
|---|---|
| [01_design.md](01_design.md) | Business rules, what the real data taught us, EER model, ER → relational mapping, normalization to BCNF, findings |
| [data/fetch.py](data/fetch.py) | Downloads the raw NSE files (bhavcopies, weekend sessions, corporate actions), index levels and lists; resumable |
| [02_ddl.sql](02_ddl.sql) | 16 tables: keys, CHECKs, GiST exclusion constraints over date ranges, composite FKs, reference data |
| [03_logic.sql](03_logic.sql) | Statement-level triggers with transition tables, views, materialized views, `refresh_research()` (adjustments, anomalies, universe, portfolios), read-only role |
| [04_load.py](04_load.py) | Entity resolution, corporate-action parsing, bulk COPY; the whole load is one transaction |
| [05_queries.sql](05_queries.sql) | Five advanced queries: window frames, correlated subqueries, recursive CTE, relational division, EXCEPT/INTERSECT |
| [06_demo.sql](06_demo.sql) | Rollback-only live demo: constraints and triggers firing, a materialized view going stale, indexing with EXPLAIN, roles |
| [07_analytics.sql](07_analytics.sql) | SQL statistics (A1–A7, including momentum decay and market states), the k-means feature view, segment tables, segment queries (S1–S2) |
| [analytics/](analytics/) | k-means notebook ([HTML export](analytics/niftyquant_kmeans.html)), its builder, the written readings, and figures |

## Run it

Needs PostgreSQL 15+ (built on 18) and Python 3.12. From this folder, in PowerShell:

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m ipykernel install --user --name niftyquant --display-name "NiftyQuant (.venv)"
.\run_all.ps1                     # downloads the data (~1 hour, first run only), builds and loads (~35 min)
.venv\Scripts\python analytics\build_notebook.py
.venv\Scripts\jupyter nbconvert --to notebook --execute --inplace analytics\niftyquant_kmeans.ipynb
```

`.\run_all.ps1 -SkipFetch` rebuilds from the files already in `data\raw`. Segments are empty after a rebuild until the notebook runs again.

## Data

- NSE India daily bhavcopy archives (`nsearchives.nseindia.com`), both the pre-July-2024 format and UDiFF.
- NSE corporate-action notices (`nseindia.com/api/corporates-corporateActions`).
- NIFTY 50 / NIFTY 500 levels from Yahoo Finance (`^NSEI`, `^CRSLDX`); today's NIFTY 500 list (sectors) and NSE's symbol-change list.

Raw files are not in the repository (`data/raw/` is git-ignored); `data/fetch.py` downloads them.
