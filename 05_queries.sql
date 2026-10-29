-- =====================================================================
--  NiftyQuant  |  Five advanced queries
--
--  Each query is labelled with:
--    QUESTION            what a portfolio manager or a researcher wants to know
--    FDS CONCEPTS        what the query demonstrates
--    RELATIONAL ALGEBRA  where it adds insight
--
--  Q1  Window frames: running wealth, running peak, drawdown   (momentum scorecard)
--  Q2  Correlated subqueries + conditional aggregation           (survivorship bias, measured)
--  Q3  Recursive CTE as an iterative computation                 (₹1 lakh after trading costs)
--  Q4  Relational DIVISION with double NOT EXISTS                (the always-liquid core)
--  Q5  Set operations: EXCEPT and INTERSECT                      (turnover and reversals)
-- =====================================================================

SET search_path TO niftyquant, public;


-- =====================================================================
-- Q1. DOES MOMENTUM WORK IN INDIA?
-- QUESTION
--   For the 12-1 strategy: CAGR, volatility, Sharpe ratio and worst drawdown
--   of each decile, of winners-minus-losers (long decile 10, short decile 1),
--   and of the NIFTY 500 over the same months.
-- FDS CONCEPTS
--   Window functions with ROWS UNBOUNDED PRECEDING frames (running sum of
--   log returns = log wealth; running MAX = previous peak); UNION ALL of
--   three differently shaped series into one result; FILTER aggregates.
-- =====================================================================

WITH params AS (SELECT strategy_id, n_buckets FROM strategy WHERE strategy_code = 'MOM_12_1'),
series AS (                          -- one row per (portfolio, holding month)
    SELECT 'D' || lpad(r.bucket::text, 2, '0') AS portfolio, r.holding_month_no, r.ret
    FROM v_portfolio_return r JOIN params p USING (strategy_id)
    UNION ALL
    SELECT 'WML (D10 - D01)', w.holding_month_no, w.ret - l.ret
    FROM params p
    JOIN v_portfolio_return w ON w.strategy_id = p.strategy_id AND w.bucket = p.n_buckets
    JOIN v_portfolio_return l ON l.strategy_id = p.strategy_id AND l.bucket = 1
                             AND l.holding_month_no = w.holding_month_no
    UNION ALL
    SELECT 'NIFTY 500', i.month_no, i.ret
    FROM v_index_monthly_return i
    WHERE i.index_code = 'NIFTY500'
      AND i.month_no IN (SELECT holding_month_no FROM v_portfolio_return JOIN params USING (strategy_id))
), path AS (
    SELECT portfolio, holding_month_no, ret,
           sum(ln(1 + ret)) OVER w AS log_wealth                      -- WML can't go below -100%
    FROM series
    WHERE ret > -1
    WINDOW w AS (PARTITION BY portfolio ORDER BY holding_month_no ROWS UNBOUNDED PRECEDING)
), dd AS (
    SELECT *, exp(log_wealth - max(log_wealth) OVER w) - 1 AS drawdown
    FROM path
    WINDOW w AS (PARTITION BY portfolio ORDER BY holding_month_no ROWS UNBOUNDED PRECEDING)
)
SELECT portfolio,
       count(*)                                                                   AS months,
       round(((exp(avg(ln(1 + ret))) ^ 12 - 1) * 100)::numeric, 1)                AS cagr_pct,
       round((stddev(ret) * sqrt(12) * 100)::numeric, 1)                          AS vol_pct,
       round((avg(ret) * 12 / nullif(stddev(ret) * sqrt(12), 0))::numeric, 2)     AS sharpe_rf0,
       round((min(least(drawdown, 0)) * 100)::numeric, 1)                         AS max_drawdown_pct,
       round((100.0 * count(*) FILTER (WHERE ret > 0) / count(*))::numeric, 0)    AS pct_up_months
FROM dd
GROUP BY portfolio
ORDER BY portfolio;

-- RELATIONAL ALGEBRA (the WML series):
--   W ← ρ_W(σ_bucket=10(PortRet)),  L ← ρ_L(σ_bucket=1(PortRet))
--   π_month, W.ret−L.ret (W ⨝_{W.month = L.month} L)


-- =====================================================================
-- Q2. HOW MUCH WOULD SURVIVORSHIP BIAS HAVE FLATTERED US?
-- QUESTION
--   Most free backtests use only stocks that are still listed today. Compare
--   the equal-weighted return of our point-in-time universe with the same
--   universe restricted to today's survivors, year by year.
-- FDS CONCEPTS
--   A derived "survivor" predicate from a correlated subquery against the
--   last trading day; conditional aggregation (FILTER); the difference
--   between the two averages is the bias, measured on real delistings.
-- =====================================================================

WITH last_day AS (SELECT max(trade_date) AS d FROM trading_day),
survivor AS (          -- traded in the last 10 trading days of the data
    SELECT DISTINCT p.security_id
    FROM daily_price p
    WHERE p.trade_date >= (SELECT min(trade_date) FROM (SELECT trade_date FROM trading_day
                                                         ORDER BY trade_date DESC LIMIT 10) t)
), monthly AS (
    SELECT u.month_end,
           avg(m.ret)                                                   AS all_members,
           avg(m.ret) FILTER (WHERE s.security_id IS NOT NULL)          AS survivors_only,
           count(*) FILTER (WHERE s.security_id IS NULL)                AS later_delisted
    FROM universe_member u
    JOIN mv_monthly_return m ON m.security_id = u.security_id AND m.month_no = month_no(u.month_end) + 1
    LEFT JOIN survivor s     ON s.security_id = u.security_id
    GROUP BY u.month_end
)
SELECT extract(year FROM month_end)::int                                          AS formation_year,
       round(((exp(sum(ln(1 + all_members)))    - 1) * 100)::numeric, 1)          AS pit_universe_pct,
       round(((exp(sum(ln(1 + survivors_only))) - 1) * 100)::numeric, 1)          AS survivors_only_pct,
       round(((exp(sum(ln(1 + survivors_only))) - exp(sum(ln(1 + all_members)))) * 100)::numeric, 1)
                                                                                  AS bias_pct_points,
       round(avg(later_delisted))                                                 AS avg_members_later_delisted
FROM monthly
GROUP BY 1
ORDER BY 1;


-- =====================================================================
-- Q3. WHAT WOULD ₹1 LAKH IN THE WINNERS DECILE BE WORTH AFTER COSTS?
-- QUESTION
--   Rebalance into decile 10 every month. Each rebalance costs 0.5% of the
--   portfolio value traded (brokerage + STT + impact, a round-trip estimate).
--   Walk the wealth month by month, net of costs, against the NIFTY 500.
-- FDS CONCEPTS
--   Recursive CTE used as a loop: each step reads the previous step's
--   wealth (the anchor is the first month, the recursive member advances
--   one month). Turnover = share of names that are new this month: a set
--   difference computed with NOT EXISTS.
-- =====================================================================

WITH RECURSIVE p AS (SELECT strategy_id, n_buckets FROM strategy WHERE strategy_code = 'MOM_12_1'),
win AS (
    SELECT h.formation_date, h.security_id
    FROM portfolio_holding h JOIN p ON p.strategy_id = h.strategy_id AND h.bucket = p.n_buckets
), turnover AS (            -- fraction of this month's names that were not held last month
    SELECT f.formation_date,
           avg(CASE WHEN NOT EXISTS (
                   SELECT 1 FROM win prev
                    WHERE prev.security_id = f.security_id
                      AND month_no(prev.formation_date) = month_no(f.formation_date) - 1)
               THEN 1.0 ELSE 0.0 END) AS turnover
    FROM win f GROUP BY f.formation_date
), steps AS (
    SELECT row_number() OVER (ORDER BY r.formation_date) AS k, r.formation_date, r.ret,
           t.turnover, coalesce(i.ret, 0) AS nifty_ret
    FROM v_portfolio_return r
    JOIN p ON p.strategy_id = r.strategy_id AND r.bucket = p.n_buckets
    JOIN turnover t USING (formation_date)
    LEFT JOIN v_index_monthly_return i ON i.index_code = 'NIFTY500' AND i.month_no = r.holding_month_no
), walk (k, formation_date, gross, net, nifty) AS (
    SELECT k, formation_date,
           100000 * (1 + ret)::numeric,
           100000 * (1 - 0.005 * 1.0) * (1 + ret)::numeric,     -- first month: buy everything
           100000 * (1 + nifty_ret)::numeric
    FROM steps WHERE k = 1
    UNION ALL
    SELECT s.k, s.formation_date,
           w.gross * (1 + s.ret)::numeric,
           w.net * (1 - 0.005 * s.turnover)::numeric * (1 + s.ret)::numeric,
           w.nifty * (1 + s.nifty_ret)::numeric
    FROM walk w JOIN steps s ON s.k = w.k + 1
)
SELECT formation_date AS formed_on,
       round(gross) AS winners_gross_rs, round(net) AS winners_after_costs_rs, round(nifty) AS nifty500_rs
FROM walk
WHERE extract(month FROM formation_date) = 12 OR k = (SELECT max(k) FROM walk)
ORDER BY formation_date;


-- =====================================================================
-- Q4. WHICH STOCKS WERE IN THE TOP 200 AT EVERY SINGLE MONTH-END?
-- QUESTION
--   The "always-liquid core": stocks ranked in the top 200 by liquidity at
--   every month-end from January 2016 to the latest month. What sectors are they?
-- FDS CONCEPTS
--   Relational DIVISION: securities S such that there is no month M in the
--   period for which S is missing from the top-200 universe (double NOT EXISTS).
-- RELATIONAL ALGEBRA
--   Top200(security, month) ÷ Months(month)
--   = π_s(Top200) − π_s((π_s(Top200) × Months) − Top200)
-- =====================================================================

WITH months AS (
    SELECT month_end FROM v_month_end
    WHERE month_end >= DATE '2016-01-01'
      AND month_end <= (SELECT max(month_end) FROM universe_member)
), top200 AS (
    SELECT month_end, security_id FROM universe_member WHERE liquidity_rank <= 200
)
SELECT v.symbol, v.security_name, coalesce(v.sector_name, '(not in NIFTY 500 today)') AS sector
FROM v_security v
WHERE NOT EXISTS (
        SELECT 1 FROM months m
        WHERE NOT EXISTS (SELECT 1 FROM top200 t
                          WHERE t.security_id = v.security_id AND t.month_end = m.month_end))
ORDER BY sector, v.symbol;


-- =====================================================================
-- Q5. HOW MUCH DOES THE WINNERS DECILE CHURN, AND WHO FLIPS?
-- QUESTION
--   (a) Each year: on average, how many names enter the winners decile each
--       month (this month's set EXCEPT last month's)?
--   (b) Which stocks in today's winners decile were in the LOSERS decile a
--       year ago (INTERSECT): the big turnarounds?
-- FDS CONCEPTS
--   Set difference and set intersection on derived relations; the operands
--   must be union-compatible (both are sets of security_id).
-- =====================================================================

-- (a) entrants per month, averaged by year
WITH p AS (SELECT strategy_id, n_buckets FROM strategy WHERE strategy_code = 'MOM_12_1'),
fm AS (SELECT DISTINCT formation_date FROM portfolio_holding JOIN p USING (strategy_id)),
entrants AS (
    SELECT fm.formation_date,
           (SELECT count(*) FROM (
                SELECT security_id FROM portfolio_holding h JOIN p USING (strategy_id)
                 WHERE h.formation_date = fm.formation_date AND h.bucket = p.n_buckets
                EXCEPT
                SELECT security_id FROM portfolio_holding h JOIN p USING (strategy_id)
                 WHERE month_no(h.formation_date) = month_no(fm.formation_date) - 1 AND h.bucket = p.n_buckets
            ) x) AS n_new,
           (SELECT count(*) FROM portfolio_holding h JOIN p USING (strategy_id)
             WHERE h.formation_date = fm.formation_date AND h.bucket = p.n_buckets) AS n_held
    FROM fm
    WHERE EXISTS (SELECT 1 FROM portfolio_holding h JOIN p USING (strategy_id)
                   WHERE month_no(h.formation_date) = month_no(fm.formation_date) - 1)
)
SELECT extract(year FROM formation_date)::int AS year,
       round(avg(n_new), 1) AS avg_new_names_per_month,
       round(avg(n_held))   AS decile_size,
       round(100 * avg(n_new::numeric / n_held), 0) AS monthly_turnover_pct
FROM entrants GROUP BY 1 ORDER BY 1;

-- (b) today's winners that were losers a year ago
WITH p AS (SELECT strategy_id, n_buckets FROM strategy WHERE strategy_code = 'MOM_12_1'),
latest AS (SELECT max(formation_date) AS d FROM portfolio_holding JOIN p USING (strategy_id)),
turnarounds AS (
    SELECT security_id FROM portfolio_holding h JOIN p USING (strategy_id), latest
     WHERE h.formation_date = latest.d AND h.bucket = p.n_buckets
    INTERSECT
    SELECT security_id FROM portfolio_holding h JOIN p USING (strategy_id), latest
     WHERE month_no(h.formation_date) = month_no(latest.d) - 12 AND h.bucket = 1
)
SELECT v.symbol, v.security_name, coalesce(v.sector_name, '-') AS sector,
       round(h.signal * 100, 1) AS momentum_now_pct
FROM turnarounds t
JOIN v_security v USING (security_id)
JOIN portfolio_holding h ON h.security_id = t.security_id
JOIN p ON p.strategy_id = h.strategy_id
JOIN latest ON h.formation_date = latest.d
ORDER BY momentum_now_pct DESC;
