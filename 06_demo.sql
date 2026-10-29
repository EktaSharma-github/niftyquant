-- =====================================================================
--  NiftyQuant  |  Live demo (about 4 minutes)
--
--  Every change runs inside BEGIN ... ROLLBACK, so the demo can be
--  repeated any number of times and never alters the loaded data.
--  Run:  psql -U postgres -h localhost -d niftyquant -f 06_demo.sql
--  Errors are EXPECTED in steps 3-5: they are the rules firing.
-- =====================================================================

SET search_path TO niftyquant, public;
\set ON_ERROR_STOP 0
\pset footer off

\echo
\echo '=== 1. Entity resolution: one company, several identifiers over time ==='
\echo '    ACKRUTI was renamed HUBTOWN (same ISIN); BHEL got a new ISIN at its 2011 split.'
SELECT v.security_name, a.symbol, a.isin, a.valid_from, a.valid_to
FROM security_alias a JOIN security v USING (security_id)
WHERE a.security_id IN (SELECT security_id FROM security_alias WHERE symbol IN ('HUBTOWN', 'BHEL'))
ORDER BY v.security_name, a.valid_from;

\echo
\echo '=== 2. Why adjustment matters: the Reliance 1:1 bonus (ex-date 2024-10-28) ==='
\echo '    The raw close halves overnight; the adjusted return is an ordinary day.'
SELECT r.trade_date, p.prev_close_px AS nse_prev_close, r.close_px, r.factor,
       round(100 * (r.close_px / lag(r.close_px) OVER (ORDER BY r.trade_date) - 1), 2) AS raw_change_pct,
       round(100 * r.ret, 2) AS adjusted_return_pct
FROM mv_daily_return r
JOIN daily_price p USING (security_id, trade_date)
WHERE r.security_id = (SELECT security_id FROM security_alias WHERE symbol = 'RELIANCE' LIMIT 1)
  AND r.trade_date BETWEEN DATE '2024-10-23' AND DATE '2024-10-30'
ORDER BY r.trade_date;

\echo '    ... and where the factor came from (provenance kept verbatim):'
SELECT a.ex_date, a.factor, a.source, a.note
FROM price_adjustment a
WHERE a.security_id = (SELECT security_id FROM security_alias WHERE symbol = 'RELIANCE' LIMIT 1)
ORDER BY a.ex_date;

\echo
\echo '=== 3. BR-2: a symbol can mean only one security on any date (GiST exclusion) ==='
\echo '    Try to give the symbol RELIANCE to TCS for 2024:'
BEGIN;
INSERT INTO security_alias (security_id, valid_from, valid_to, symbol, isin)
SELECT security_id, DATE '2024-01-01', DATE '2024-12-31', 'RELIANCE', NULL
FROM security_alias WHERE symbol = 'TCS' LIMIT 1;
ROLLBACK;

\echo
\echo '=== 4. BR-4 and BR-5: what a price row may say, and when ==='
\echo '    (a) a high below the close: CHECK constraint'
BEGIN;
UPDATE daily_price SET high_px = close_px - 1
WHERE security_id = (SELECT security_id FROM security_alias WHERE symbol = 'TCS' LIMIT 1)
  AND trade_date = DATE '2024-10-28';
ROLLBACK;
\echo '    (b) a price for a stock on a day before it was listed: statement-level trigger'
\echo '        (LIC listed on 2022-05-17; 2022-05-16 was a trading day)'
BEGIN;
INSERT INTO daily_price (security_id, trade_date, series_code, open_px, high_px, low_px, close_px,
                         prev_close_px, volume, traded_value)
SELECT security_id, DATE '2022-05-16', 'EQ', 949, 949, 949, 949, 949, 1, 949
FROM security_alias WHERE symbol = 'LICI' LIMIT 1;
ROLLBACK;

\echo
\echo '=== 5. BR-11 and BR-12: no look-ahead in the backtest ==='
\echo '    (a) LIC in a 2021 portfolio, before it existed: composite FK to universe_member'
BEGIN;
INSERT INTO portfolio_holding (strategy_id, formation_date, security_id, bucket, signal)
SELECT s.strategy_id, DATE '2021-12-31', a.security_id, 10, 0.5
FROM strategy s, security_alias a
WHERE s.strategy_code = 'MOM_12_1' AND a.symbol = 'LICI' LIMIT 1;
ROLLBACK;
\echo '    (b) an 11th decile: statement-level trigger against the strategy definition'
\echo '        (take one real holding out, put it back in decile 11)'
BEGIN;
CREATE TEMP TABLE one_holding ON COMMIT DROP AS
SELECT h.* FROM portfolio_holding h JOIN strategy s USING (strategy_id)
WHERE s.strategy_code = 'MOM_12_1' AND h.formation_date = DATE '2024-12-31' AND h.bucket = 10 LIMIT 1;
DELETE FROM portfolio_holding h USING one_holding o
WHERE (h.strategy_id, h.formation_date, h.security_id) = (o.strategy_id, o.formation_date, o.security_id);
INSERT INTO portfolio_holding (strategy_id, formation_date, security_id, bucket, signal)
SELECT strategy_id, formation_date, security_id, 11, signal FROM one_holding;
ROLLBACK;
\echo '    (c) an ETF in the universe: BR-10 trigger (the EQ series also carries ETFs)'
BEGIN;
INSERT INTO universe_member (month_end, security_id, liquidity_rank, avg_traded_value)
SELECT DATE '2024-12-31', security_id, 501, 1
FROM security_alias WHERE symbol = 'NIFTYBEES' LIMIT 1;
ROLLBACK;

\echo
\echo '=== 6. A materialized view is a cache: stale until refreshed ==='
\echo '    (mv_daily_return has 7.3M rows; for the demo, the same definition for TCS only)'
BEGIN;
CREATE MATERIALIZED VIEW demo_tcs_return AS
SELECT p.trade_date,
       p.close_px / (lag(p.close_px) OVER (ORDER BY p.trade_date) * coalesce(a.factor, 1)) - 1 AS ret
FROM daily_price p
LEFT JOIN price_adjustment a ON a.security_id = p.security_id AND a.ex_date = p.trade_date
WHERE p.security_id = (SELECT security_id FROM security_alias WHERE symbol = 'TCS' LIMIT 1);
\echo '    Add a fake 1:2 split for TCS on 2024-10-28 ...'
INSERT INTO price_adjustment (security_id, ex_date, factor, source, note)
SELECT security_id, DATE '2024-10-28', 0.5, 'MANUAL', 'demo'
FROM security_alias WHERE symbol = 'TCS' LIMIT 1;
SELECT 'before REFRESH' AS state, round(100 * ret, 2) AS tcs_return_pct
FROM demo_tcs_return WHERE trade_date = DATE '2024-10-28';
REFRESH MATERIALIZED VIEW demo_tcs_return;
SELECT 'after REFRESH' AS state, round(100 * ret, 2) AS tcs_return_pct
FROM demo_tcs_return WHERE trade_date = DATE '2024-10-28';
ROLLBACK;
\echo '    Rolled back: the fake split and the refresh are both undone.'

\echo
\echo '=== 7. Indexing: one day across all stocks vs one stock across all days (7.3M rows) ==='
\echo '    TIMING OFF: per-row timing overhead on Windows would otherwise distort the comparison.'
\echo '    The PK (security_id, trade_date) serves "one stock"; ix_price_date serves "one day".'
BEGIN;
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT count(*), sum(traded_value) FROM daily_price WHERE trade_date = DATE '2024-10-28';
DROP INDEX ix_price_date;
\echo '    ix_price_date dropped (inside the transaction). Same query:'
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT count(*), sum(traded_value) FROM daily_price WHERE trade_date = DATE '2024-10-28';
ROLLBACK;
\echo '    Rolled back: the index is restored.'

\echo
\echo '=== 8. Least privilege: the analytics role can read, not write ==='
SET ROLE niftyquant_readonly;
SELECT count(*) AS prices_visible FROM daily_price;
DELETE FROM daily_price WHERE trade_date = DATE '2024-10-28';
RESET ROLE;
