-- =====================================================================
--  NiftyQuant  |  Analytics: SQL statistics, feature view, k-means segments
--
--  A1-A5   statistics computed INSIDE PostgreSQL
--  v_stock_features   one row per stock: the last 60 full months
--  segment / security_segment   k-means labels, written back by
--                               analytics/niftyquant_kmeans.ipynb
--  S1-S2   questions that need the segments
--
--  The notebook runs each labelled query from this file, so the SQL on
--  the slides and the SQL executed are the same text.
--  Re-runnable: views are dropped and recreated; segment tables are kept.
-- =====================================================================

SET search_path TO niftyquant, public;
SET client_min_messages = warning;

-- One definition of the analysis window, used everywhere: the 60 full
-- months ending with the last COMPLETE month in the data
CREATE OR REPLACE FUNCTION window_end() RETURNS integer LANGUAGE sql STABLE AS
$$ SELECT month_no(max(trade_date)) - 1 FROM trading_day $$;
CREATE OR REPLACE FUNCTION window_start() RETURNS integer LANGUAGE sql STABLE AS
$$ SELECT window_end() - 59 $$;


-- =====================================================================
-- A1. ARE STOCK RETURNS NORMAL?
-- Mean, SD, skewness and excess kurtosis of monthly returns, for universe
-- stocks and for the NIFTY 500. A normal distribution has skew 0 and excess
-- kurtosis 0; anything far from that means fat tails (crashes and jumps).
-- FDS: moments built from aggregates (avg of powers of the deviation),
-- a CTE that joins each row to its group's mean and SD.
-- =====================================================================

WITH r AS (
    SELECT 'Universe stocks' AS series, m.ret
    FROM universe_member u
    JOIN mv_monthly_return m ON m.security_id = u.security_id AND m.month_no = month_no(u.month_end) + 1
    UNION ALL
    SELECT 'NIFTY 500', ret FROM v_index_monthly_return
    WHERE index_code = 'NIFTY500' AND ret IS NOT NULL
      AND month_no >= (SELECT min(month_no(month_end)) + 1 FROM universe_member)
), s AS (
    SELECT series, avg(ret) AS mu, stddev_pop(ret) AS sd FROM r GROUP BY series
)
SELECT r.series, count(*) AS stock_months,
       round(100 * avg(r.ret)::numeric, 2)                                AS mean_pct,
       round(100 * avg(s.sd)::numeric, 2)                                 AS sd_pct,
       round(avg(((r.ret - s.mu) / s.sd) ^ 3)::numeric, 2)                AS skewness,
       round((avg(((r.ret - s.mu) / s.sd) ^ 4) - 3)::numeric, 2)          AS excess_kurtosis,
       round(100 * percentile_cont(0.01) WITHIN GROUP (ORDER BY r.ret)::numeric, 1) AS p1_pct,
       round(100 * percentile_cont(0.99) WITHIN GROUP (ORDER BY r.ret)::numeric, 1) AS p99_pct
FROM r JOIN s USING (series)
GROUP BY r.series
ORDER BY r.series DESC;


-- =====================================================================
-- A2. DOES THE MOMENTUM SIGNAL PREDICT NEXT MONTH'S RETURN?
-- The information coefficient (IC): each month, the rank correlation
-- (Spearman = Pearson on ranks) between the 12-1 signal and the return in
-- the following month. Averaged over all months, with a t-statistic.
-- FDS: RANK() window functions inside a partition, CORR() aggregate over
-- the ranks, then aggregates of aggregates.
-- =====================================================================

WITH p AS (SELECT strategy_id FROM strategy WHERE strategy_code = 'MOM_12_1'),
ranked AS (
    SELECT h.formation_date,
           rank() OVER (PARTITION BY h.formation_date ORDER BY h.signal) AS r_signal,
           rank() OVER (PARTITION BY h.formation_date ORDER BY m.ret)    AS r_next
    FROM portfolio_holding h
    JOIN p USING (strategy_id)
    JOIN mv_monthly_return m ON m.security_id = h.security_id AND m.month_no = month_no(h.formation_date) + 1
), ic AS (
    SELECT formation_date, corr(r_signal, r_next) AS ic FROM ranked GROUP BY formation_date
)
SELECT count(*)                                                    AS months,
       round(avg(ic)::numeric, 3)                                  AS mean_ic,
       round(stddev(ic)::numeric, 3)                               AS sd_ic,
       round((avg(ic) / stddev(ic) * sqrt(count(*)))::numeric, 2)  AS t_stat,
       round((100.0 * count(*) FILTER (WHERE ic > 0) / count(*))::numeric, 0) AS pct_months_positive
FROM ic;


-- =====================================================================
-- A3. WHEN DOES MOMENTUM CRASH?
-- The ten worst months for winners-minus-losers, with what the market did
-- in that month and in the 12 months before. Momentum is known to crash in
-- sharp rebounds after a fall, when last year's losers bounce hardest.
-- FDS: self-join of a view (winners vs losers), a correlated scalar
-- subquery for the trailing market return, ORDER BY ... LIMIT.
-- =====================================================================

WITH p AS (SELECT strategy_id, n_buckets FROM strategy WHERE strategy_code = 'MOM_12_1'),
wml AS (
    SELECT w.holding_month_no, w.ret - l.ret AS wml, w.ret AS winners, l.ret AS losers
    FROM p
    JOIN v_portfolio_return w ON w.strategy_id = p.strategy_id AND w.bucket = p.n_buckets
    JOIN v_portfolio_return l ON l.strategy_id = p.strategy_id AND l.bucket = 1
                             AND l.holding_month_no = w.holding_month_no
)
SELECT to_char(make_date((x.holding_month_no - 1) / 12, (x.holding_month_no - 1) % 12 + 1, 1), 'Mon YYYY') AS month,
       round(100 * x.wml::numeric, 1)     AS wml_pct,
       round(100 * x.winners::numeric, 1) AS winners_pct,
       round(100 * x.losers::numeric, 1)  AS losers_pct,
       round(100 * i.ret::numeric, 1)     AS nifty500_pct,
       round(100 * (SELECT exp(sum(ln(1 + j.ret))) - 1 FROM v_index_monthly_return j
                     WHERE j.index_code = 'NIFTY500'
                       AND j.month_no BETWEEN x.holding_month_no - 12 AND x.holding_month_no - 1)::numeric, 1)
                                          AS nifty500_prior_12m_pct
FROM wml x
LEFT JOIN v_index_monthly_return i ON i.index_code = 'NIFTY500' AND i.month_no = x.holding_month_no
ORDER BY x.wml
LIMIT 10;


-- =====================================================================
-- A4. HOW RISKY IS EACH SECTOR? (market beta, last 60 months)
-- Beta = slope of a stock's monthly return on the NIFTY 500's, from the
-- REGR_SLOPE aggregate. Median beta per sector, plus an overall row.
-- FDS: regression aggregates (REGR_SLOPE, REGR_R2), GROUPING SETS for the
-- per-sector rows and the grand total in one pass.
-- =====================================================================

WITH beta AS (
    SELECT m.security_id, regr_slope(m.ret, i.ret) AS beta, regr_r2(m.ret, i.ret) AS r2
    FROM mv_monthly_return m
    JOIN v_index_monthly_return i ON i.index_code = 'NIFTY500' AND i.month_no = m.month_no
    WHERE m.month_no BETWEEN window_start() AND window_end()
    GROUP BY m.security_id
    HAVING count(*) >= 48
)
SELECT coalesce(sec.sector_name, CASE WHEN GROUPING(sec.sector_name) = 1 THEN 'ALL NIFTY 500 STOCKS' END) AS sector,
       count(*)                                                                   AS stocks,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY b.beta)::numeric, 2)     AS median_beta,
       round(min(b.beta)::numeric, 2)                                             AS min_beta,
       round(max(b.beta)::numeric, 2)                                             AS max_beta,
       round(avg(b.r2)::numeric, 2)                                               AS avg_r2
FROM beta b
JOIN security s    ON s.security_id = b.security_id
JOIN sector sec    ON sec.sector_id = s.sector_id
GROUP BY GROUPING SETS ((sec.sector_name), ())
ORDER BY GROUPING(sec.sector_name), median_beta DESC;


-- =====================================================================
-- A5. DO LESS LIQUID STOCKS EARN MORE?
-- Universe members in liquidity bands of 100 ranks (1-100 = most traded),
-- with their average next-month return and volatility.
-- FDS: WIDTH_BUCKET to band a rank, aggregates per band.
-- =====================================================================

SELECT width_bucket(u.liquidity_rank, 1, 501, 5)                             AS band,
       min(u.liquidity_rank) || '-' || max(u.liquidity_rank)                 AS ranks,
       count(*)                                                              AS stock_months,
       round(100 * avg(m.ret)::numeric, 2)                                   AS avg_next_month_pct,
       round(100 * stddev(m.ret)::numeric, 2)                                AS sd_pct,
       round((avg(u.avg_traded_value) / 1e7)::numeric, 1)                    AS avg_daily_value_cr
FROM universe_member u
JOIN mv_monthly_return m ON m.security_id = u.security_id AND m.month_no = month_no(u.month_end) + 1
GROUP BY 1 ORDER BY 1;


-- =====================================================================
-- Feature view for k-means: one row per stock in today's universe with at
-- least 48 of the last 60 months. Every feature is computed in SQL.
--   ann_return     geometric, annualized          ann_vol      annualized SD
--   beta           vs NIFTY 500                   max_drawdown worst peak-to-trough (monthly)
--   dividend_yield total minus price return, p.a. ln_liquidity ln(avg daily ₹ traded, 6 m)
--   winner_share   share of months the stock sat in the top 3 deciles of 12-1 momentum
-- =====================================================================
DROP VIEW IF EXISTS v_segment_profile;
DROP VIEW IF EXISTS v_stock_features;
CREATE VIEW v_stock_features AS
WITH latest AS (
    SELECT max(month_end) AS d FROM universe_member WHERE month_no(month_end) <= window_end()
), members AS (
    SELECT u.security_id, u.avg_traded_value FROM universe_member u, latest WHERE u.month_end = latest.d
), rets AS (
    SELECT m.security_id, m.month_no, m.ret, m.tr_ret, i.ret AS mkt,
           sum(ln(1 + m.ret)) OVER (PARTITION BY m.security_id ORDER BY m.month_no
                                    ROWS UNBOUNDED PRECEDING) AS logw
    FROM mv_monthly_return m
    JOIN members USING (security_id)
    JOIN v_index_monthly_return i ON i.index_code = 'NIFTY500' AND i.month_no = m.month_no
    WHERE m.month_no BETWEEN window_start() AND window_end()
), dd AS (
    SELECT *, exp(logw - greatest(0, max(logw) OVER (PARTITION BY security_id ORDER BY month_no
                                                       ROWS UNBOUNDED PRECEDING))) - 1 AS drawdown
    FROM rets
), mom AS (
    SELECT h.security_id,
           avg(CASE WHEN h.bucket >= 8 THEN 1.0 ELSE 0.0 END) AS winner_share
    FROM portfolio_holding h
    JOIN strategy s ON s.strategy_id = h.strategy_id AND s.strategy_code = 'MOM_12_1'
    WHERE month_no(h.formation_date) BETWEEN window_start() AND window_end()
    GROUP BY h.security_id
)
SELECT d.security_id,
       exp(avg(ln(1 + d.ret)) * 12) - 1                 AS ann_return,
       stddev(d.ret) * sqrt(12)                         AS ann_vol,
       regr_slope(d.ret, d.mkt)                         AS beta,
       min(least(d.drawdown, 0))                        AS max_drawdown,
       (avg(d.tr_ret) - avg(d.ret)) * 12                AS dividend_yield,
       ln(max(mb.avg_traded_value))                     AS ln_liquidity,
       coalesce(max(mo.winner_share), 0)                AS winner_share
FROM dd d
JOIN members mb USING (security_id)
LEFT JOIN mom mo USING (security_id)
GROUP BY d.security_id
HAVING count(*) >= 48;


-- =====================================================================
-- Segment tables (BCNF): the notebook writes k-means results here
-- =====================================================================
CREATE TABLE IF NOT EXISTS segment (
    segment_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_name  varchar(40) NOT NULL UNIQUE,
    description   text        NOT NULL
);

CREATE TABLE IF NOT EXISTS security_segment (
    security_id  integer  PRIMARY KEY REFERENCES security ON DELETE CASCADE,
    segment_id   smallint NOT NULL REFERENCES segment ON DELETE CASCADE,
    distance     numeric(6, 3) NOT NULL CHECK (distance >= 0)   -- to the centroid, in SD units
);

CREATE VIEW v_segment_profile AS
SELECT s.segment_name, count(*) AS stocks,
       string_agg(v.symbol, ', ' ORDER BY ss.distance) AS most_typical
FROM segment s
JOIN security_segment ss USING (segment_id)
JOIN v_security v ON v.security_id = ss.security_id
GROUP BY s.segment_id, s.segment_name;

GRANT SELECT ON ALL TABLES IN SCHEMA niftyquant TO niftyquant_readonly;


-- =====================================================================
-- S1. WHICH SECTORS FALL INTO WHICH SEGMENT?
-- Count of stocks per sector × segment, with each sector's dominant
-- segment flagged.
-- =====================================================================

WITH c AS (
    SELECT coalesce(sec.sector_name, '(unclassified)') AS sector, sg.segment_name, count(*) AS stocks
    FROM security_segment ss
    JOIN segment sg   USING (segment_id)
    JOIN security s   ON s.security_id = ss.security_id
    LEFT JOIN sector sec ON sec.sector_id = s.sector_id
    GROUP BY 1, 2
)
SELECT sector, segment_name, stocks,
       round(100.0 * stocks / sum(stocks) OVER (PARTITION BY sector), 0) AS share_of_sector_pct,
       rank() OVER (PARTITION BY sector ORDER BY stocks DESC) = 1         AS dominant
FROM c
ORDER BY sector, stocks DESC;


-- =====================================================================
-- S2. WHICH SEGMENT PROTECTS YOU WHEN THE MARKET FALLS?
-- Average monthly return of each segment's stocks in the market's down
-- months (NIFTY 500 < -3%), flat months, and up months (> +3%), over the
-- analysis window: downside and upside capture in one table.
-- =====================================================================

SELECT sg.segment_name,
       round(100 * avg(m.ret) FILTER (WHERE i.ret < -0.03)::numeric, 2)               AS avg_in_down_months_pct,
       round(100 * avg(m.ret) FILTER (WHERE i.ret BETWEEN -0.03 AND 0.03)::numeric, 2) AS avg_in_flat_months_pct,
       round(100 * avg(m.ret) FILTER (WHERE i.ret > 0.03)::numeric, 2)                AS avg_in_up_months_pct,
       round(100 * avg(i.ret) FILTER (WHERE i.ret < -0.03)::numeric, 2)               AS nifty500_down_pct,
       round(100 * avg(i.ret) FILTER (WHERE i.ret > 0.03)::numeric, 2)                AS nifty500_up_pct
FROM security_segment ss
JOIN segment sg USING (segment_id)
JOIN mv_monthly_return m ON m.security_id = ss.security_id
JOIN v_index_monthly_return i ON i.index_code = 'NIFTY500' AND i.month_no = m.month_no
WHERE m.month_no BETWEEN window_start() AND window_end()
GROUP BY sg.segment_id, sg.segment_name
ORDER BY avg_in_down_months_pct DESC;
