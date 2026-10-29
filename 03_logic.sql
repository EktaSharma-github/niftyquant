-- =====================================================================
-- NiftyQuant — 03_logic.sql : triggers for the market's integrity rules,
-- derived views (returns are never stored as base data: BR-13), and the
-- research procedure that builds the point-in-time universe and portfolios.
-- Run after 02_ddl.sql and BEFORE loading, so every real row is checked.
-- =====================================================================
SET search_path = niftyquant;

-- Month number (year*12 + month): lets "12 months before" be plain arithmetic
CREATE FUNCTION month_no(d date) RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT (extract(year FROM d) * 12 + extract(month FROM d))::int $$;

-- ---------------------------------------------------------------------
-- BR-5: a price row is only valid on a date when one of the security's
-- identifiers (alias spells) was in force.
-- Statement-level trigger with a transition table: the 8-million-row COPY
-- is checked with ONE set-based query instead of 8 million lookups.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_price_has_alias() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE bad record;
BEGIN
    SELECT n.security_id, n.trade_date INTO bad
      FROM new_rows n
     WHERE NOT EXISTS (SELECT 1 FROM security_alias a
                        WHERE a.security_id = n.security_id
                          AND n.trade_date BETWEEN a.valid_from AND a.valid_to)
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'BR-5: security % has a price on % but no symbol in force that day',
            bad.security_id, bad.trade_date;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER price_has_alias
    AFTER INSERT ON daily_price
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_price_has_alias();

-- ---------------------------------------------------------------------
-- BR-9: the attributes a corporate-action component carries depend on its
-- type (action_type.changes_shares): a split/bonus needs a share ratio, a
-- dividend needs cash, a demerger carries neither.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_component_shape() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE needs_ratio boolean;
BEGIN
    SELECT changes_shares INTO needs_ratio FROM action_type WHERE action_code = NEW.action_code;
    IF NEW.action_code IN ('SPLIT', 'CONSOLIDATION', 'BONUS', 'RIGHTS') AND NEW.shares_before IS NULL THEN
        RAISE EXCEPTION 'BR-9: % component needs a share ratio (announcement %)', NEW.action_code, NEW.ann_id;
    END IF;
    IF NOT needs_ratio AND NEW.shares_before IS NOT NULL THEN
        RAISE EXCEPTION 'BR-9: % does not change the share count (announcement %)', NEW.action_code, NEW.ann_id;
    END IF;
    IF NEW.issue_price IS NOT NULL AND NEW.action_code <> 'RIGHTS' THEN
        RAISE EXCEPTION 'BR-9: only a rights issue has an issue price (announcement %)', NEW.ann_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER component_shape
    BEFORE INSERT OR UPDATE ON ca_component
    FOR EACH ROW EXECUTE FUNCTION trg_component_shape();

-- ---------------------------------------------------------------------
-- BR-10: a universe member is a company share (not an ETF or partly paid
-- share) and is alive at the month-end: it traded in the last 10 trading
-- days up to that date (no members from the future or the dead)
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_universe_alive() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE bad record;
BEGIN
    SELECT n.month_end, n.security_id, s.instrument_type INTO bad
      FROM new_rows n JOIN security s USING (security_id)
     WHERE s.instrument_type NOT IN ('EQUITY', 'UNKNOWN')
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'BR-10: security % is an % and cannot be in the % universe',
            bad.security_id, bad.instrument_type, bad.month_end;
    END IF;

    SELECT n.month_end, n.security_id INTO bad
      FROM new_rows n
     WHERE NOT EXISTS (
            SELECT 1 FROM daily_price p
             WHERE p.security_id = n.security_id
               AND p.trade_date <= n.month_end
               AND p.trade_date >= (SELECT min(t.trade_date) FROM (
                                       SELECT trade_date FROM trading_day
                                        WHERE trade_date <= n.month_end
                                        ORDER BY trade_date DESC LIMIT 10) t))
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'BR-10: security % is in the % universe but did not trade in the 10 days before',
            bad.security_id, bad.month_end;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER universe_alive
    AFTER INSERT ON universe_member
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_universe_alive();

-- ---------------------------------------------------------------------
-- BR-12: a holding's bucket is within the strategy's bucket count, and the
-- stock is inside the strategy's universe size on the formation date.
-- (BR-11, "only stocks in the universe that day", is the composite FK.)
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_holding_in_strategy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE bad record;
BEGIN
    SELECT n.strategy_id, n.formation_date, n.security_id, n.bucket INTO bad
      FROM new_rows n
      JOIN strategy s        ON s.strategy_id = n.strategy_id
      JOIN universe_member u ON u.month_end = n.formation_date AND u.security_id = n.security_id
     WHERE n.bucket > s.n_buckets OR u.liquidity_rank > s.universe_size
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'BR-12: holding (strategy %, %, security %, bucket %) is outside the strategy''s buckets or universe',
            bad.strategy_id, bad.formation_date, bad.security_id, bad.bucket;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER holding_in_strategy
    AFTER INSERT ON portfolio_holding
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_holding_in_strategy();

-- ---------------------------------------------------------------------
-- Views: derived data (BR-13)
-- ---------------------------------------------------------------------
-- The last trading day of each month (derived from the set of trading days)
CREATE VIEW v_month_end AS
SELECT max(trade_date) AS month_end, month_no(max(trade_date)) AS month_no
FROM trading_day
GROUP BY month_no(trade_date);

-- The symbol in force for each security on its last day (for display)
CREATE VIEW v_security AS
SELECT s.security_id, a.symbol, a.isin, s.security_name, sec.sector_name,
       f.first_date, a.valid_to AS last_date
FROM security s
JOIN LATERAL (SELECT symbol, isin, valid_to FROM security_alias x
               WHERE x.security_id = s.security_id ORDER BY valid_from DESC LIMIT 1) a ON true
JOIN LATERAL (SELECT min(valid_from) AS first_date FROM security_alias x
               WHERE x.security_id = s.security_id) f ON true
LEFT JOIN sector sec ON sec.sector_id = s.sector_id;

-- Daily returns on adjusted prices. Materialized: a window over 8M rows is too slow
-- to recompute on every query; refresh_research() rebuilds it (a cache, not base data).
--   ret     price return: close / (previous close × adjustment factor) − 1
--   tr_ret  total return: also adds cash dividends going ex that day
CREATE MATERIALIZED VIEW mv_daily_return AS
WITH div_day AS (          -- each dividend lands on the first day the stock trades ex
    SELECT d.security_id, d.trade_date, sum(c.cash_per_share) AS cash
    FROM ca_component c
    JOIN ca_announcement a ON a.ann_id = c.ann_id
    JOIN LATERAL (SELECT p.security_id, p.trade_date FROM daily_price p
                   WHERE p.security_id = a.security_id AND p.trade_date >= a.ex_date
                   ORDER BY p.trade_date LIMIT 1) d ON true
    WHERE c.action_code = 'DIVIDEND'
    GROUP BY d.security_id, d.trade_date
)
SELECT p.security_id, p.trade_date, p.close_px, p.traded_value,
       coalesce(a.factor, 1)                                         AS factor,
       coalesce(v.cash, 0)                                           AS dividend,
       p.close_px / (lag(p.close_px) OVER w * coalesce(a.factor, 1)) - 1 AS ret,
       (p.close_px + coalesce(v.cash, 0))
           / (lag(p.close_px) OVER w * coalesce(a.factor, 1)) - 1    AS tr_ret
FROM daily_price p
LEFT JOIN price_adjustment a ON a.security_id = p.security_id AND a.ex_date = p.trade_date
LEFT JOIN div_day v          ON v.security_id = p.security_id AND v.trade_date = p.trade_date
WINDOW w AS (PARTITION BY p.security_id ORDER BY p.trade_date)
WITH NO DATA;
CREATE UNIQUE INDEX ux_mv_daily_return ON mv_daily_return (security_id, trade_date);

-- Monthly returns by compounding daily ones: exp(Σ ln(1+r)) − 1.
-- Anomaly days not resolved as 'genuine' count as 0: they are capital events
-- (demergers, schemes) whose price effect the source does not quantify (BR-8).
CREATE MATERIALIZED VIEW mv_monthly_return AS
SELECT r.security_id,
       month_no(r.trade_date)                                AS month_no,
       max(r.trade_date)                                     AS last_trade_date,
       exp(sum(ln(1 + CASE WHEN an.security_id IS NULL THEN coalesce(r.ret, 0) ELSE 0 END))) - 1    AS ret,
       exp(sum(ln(1 + CASE WHEN an.security_id IS NULL THEN coalesce(r.tr_ret, 0) ELSE 0 END))) - 1 AS tr_ret,
       count(*)                                              AS days_traded,
       sum(r.traded_value)                                   AS traded_value
FROM mv_daily_return r
LEFT JOIN price_anomaly an ON an.security_id = r.security_id AND an.trade_date = r.trade_date
                          AND an.resolution <> 'genuine'
GROUP BY r.security_id, month_no(r.trade_date)
WITH NO DATA;
CREATE UNIQUE INDEX ux_mv_monthly_return ON mv_monthly_return (security_id, month_no);

-- Benchmark monthly returns
CREATE VIEW v_index_monthly_return AS
WITH last_lvl AS (
    SELECT DISTINCT ON (index_code, month_no(trade_date))
           index_code, month_no(trade_date) AS month_no, trade_date, close_lvl
    FROM index_level
    ORDER BY index_code, month_no(trade_date), trade_date DESC
)
SELECT index_code, month_no, trade_date AS month_end,
       close_lvl / lag(close_lvl) OVER (PARTITION BY index_code ORDER BY month_no) - 1 AS ret
FROM last_lvl;

-- Equal-weighted return of each bucket in the month AFTER formation.
-- n_missing = holdings with no trade next month (delisted/suspended): excluded, and counted.
CREATE VIEW v_portfolio_return AS
SELECT h.strategy_id, h.formation_date, month_no(h.formation_date) + 1 AS holding_month_no,
       h.bucket,
       avg(m.ret)                     AS ret,
       avg(m.tr_ret)                  AS tr_ret,
       count(m.ret)                   AS n_held,
       count(*) - count(m.ret)        AS n_missing
FROM portfolio_holding h
LEFT JOIN mv_monthly_return m ON m.security_id = h.security_id
                             AND m.month_no = month_no(h.formation_date) + 1
WHERE month_no(h.formation_date) < (SELECT max(month_no) FROM v_month_end)
GROUP BY h.strategy_id, h.formation_date, h.bucket;

-- ---------------------------------------------------------------------
-- refresh_research(): rebuilds everything derived, in dependency order.
-- Manual adjustments and anomaly resolutions made by people are kept.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE refresh_research(p_universe_size int DEFAULT 500, p_anomaly_logret numeric DEFAULT 0.40)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    -- 1. Adjustment factors (BR-7). Precedence: MANUAL > CORP_ACTION > NSE_PREVCLOSE.
    DELETE FROM price_adjustment WHERE source <> 'MANUAL';

    -- 1a. Parsed corporate actions, all years (NSE's bhavcopy prev close is NOT adjusted
    --     for splits or bonuses in either file format: the data showed it, §2).
    --     split/bonus/consolidation: before/after; rights: theoretical ex-rights price, never > 1
    INSERT INTO price_adjustment (security_id, ex_date, factor, source, note)
    SELECT a.security_id, d.trade_date,
           round(exp(sum(ln(
               CASE WHEN c.action_code = 'RIGHTS'
                    THEN least(1, (c.shares_before * pc.close_px + (c.shares_after - c.shares_before) * c.issue_price)
                                  / (c.shares_after * pc.close_px))
                    ELSE c.shares_before / c.shares_after END))), 8),
           'CORP_ACTION', left(string_agg(DISTINCT a.raw_subject, ' | '), 200)
    FROM ca_announcement a
    JOIN ca_component c ON c.ann_id = a.ann_id
    JOIN LATERAL (SELECT p.trade_date FROM daily_price p
                   WHERE p.security_id = a.security_id AND p.trade_date >= a.ex_date
                   ORDER BY p.trade_date LIMIT 1) d ON true
    JOIN LATERAL (SELECT p.close_px FROM daily_price p
                   WHERE p.security_id = a.security_id AND p.trade_date < d.trade_date
                   ORDER BY p.trade_date DESC LIMIT 1) pc ON true
    WHERE c.action_code IN ('SPLIT', 'CONSOLIDATION', 'BONUS', 'RIGHTS')
      AND (c.action_code <> 'RIGHTS' OR c.issue_price IS NOT NULL)
    GROUP BY a.security_id, d.trade_date
    HAVING round(exp(sum(ln(
               CASE WHEN c.action_code = 'RIGHTS'
                    THEN least(1, (c.shares_before * pc.close_px + (c.shares_after - c.shares_before) * c.issue_price)
                                  / (c.shares_after * pc.close_px))
                    ELSE c.shares_before / c.shares_after END))), 8) <> 1
    ON CONFLICT (security_id, ex_date) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'adjustments from corporate actions: %', n;

    -- 1b. Fallback: where NSE's reported prev close differs from the actual previous close
    --     and no corporate action explains it, NSE's figure implies the factor. Only clear capital
    --     events (|ln factor| > 0.2, e.g. an unannounced consolidation or a 1:100 ETF split): small
    --     mismatches are penny-stock noise from days traded in other series
    --     (e.g. ALPSINDUS 2.85 vs 2.75)
    INSERT INTO price_adjustment (security_id, ex_date, factor, source, note)
    SELECT security_id, trade_date, round(prev_close_px / prev_close, 8), 'NSE_PREVCLOSE',
           'NSE prev close ' || prev_close_px || ' vs actual ' || prev_close
    FROM (SELECT p.security_id, p.trade_date, p.prev_close_px,
                 lag(p.close_px) OVER (PARTITION BY p.security_id ORDER BY p.trade_date) AS prev_close
            FROM daily_price p) x
    WHERE prev_close IS NOT NULL
      AND abs(ln(prev_close_px / prev_close)) > 0.2
    ON CONFLICT (security_id, ex_date) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'adjustments from NSE prev close (no corporate action): %', n;

    -- 2. Daily returns
    REFRESH MATERIALIZED VIEW mv_daily_return;

    -- 3. Anomalies: |ln(1+r)| beyond the threshold that no adjustment explains (BR-8).
    --    Auto-resolved from the corporate-action record, decisions by people are kept:
    --      excluded  a capital event was announced within 10 days whose effect we could not
    --                quantify (demerger, scheme of arrangement, an unparsed bonus): the jump is
    --                an artefact, so it counts as 0 in monthly returns
    --      genuine   no such announcement: a real move (Yes Bank, March 2020), kept
    DELETE FROM price_anomaly WHERE resolution = 'open' OR note LIKE 'auto:%';
    INSERT INTO price_anomaly (security_id, trade_date, raw_return, resolution, note)
    SELECT r.security_id, r.trade_date, round(r.ret, 4),
           CASE WHEN ce.ex_date IS NOT NULL THEN 'excluded' ELSE 'genuine' END,
           CASE WHEN ce.ex_date IS NOT NULL
                THEN left('auto: capital event ' || ce.ex_date || ': ' || ce.raw_subject, 200)
                ELSE 'auto: no capital event announced within 10 days' END
    FROM mv_daily_return r
    LEFT JOIN LATERAL (
        SELECT a.ex_date, a.raw_subject FROM ca_announcement a
        WHERE a.security_id = r.security_id
          AND a.ex_date BETWEEN r.trade_date - 10 AND r.trade_date
          AND a.raw_subject ~* 'scheme|arrang|amalgam|merger|bonus|split|spl|consolid|reduction|rights'
        ORDER BY a.ex_date DESC LIMIT 1) ce ON true
    WHERE r.ret IS NOT NULL AND abs(ln(1 + r.ret)) > p_anomaly_logret
    ON CONFLICT (security_id, trade_date) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'price anomalies flagged: % (excluded: %, genuine: %)', n,
        (SELECT count(*) FROM price_anomaly WHERE resolution = 'excluded'),
        (SELECT count(*) FROM price_anomaly WHERE resolution = 'genuine');

    -- 4. Monthly returns
    REFRESH MATERIALIZED VIEW mv_monthly_return;

    -- 5. Point-in-time universe (BR-10): rank by average daily traded value over the
    --    trailing 6 months, counting non-trading days as zero; must have traded on at
    --    least 80% of market days in that window. Uses only data up to month_end.
    DELETE FROM portfolio_holding;
    DELETE FROM universe_member;
    INSERT INTO universe_member (month_end, security_id, liquidity_rank, avg_traded_value)
    WITH mkt AS (            -- market days per month
        SELECT month_no(trade_date) AS month_no, count(*) AS days FROM trading_day GROUP BY 1
    ), win AS (
        SELECT me.month_end, me.month_no, sum(k.days) AS mkt_days
        FROM v_month_end me JOIN mkt k ON k.month_no BETWEEN me.month_no - 5 AND me.month_no
        GROUP BY me.month_end, me.month_no
        HAVING count(*) = 6
    ), roll AS (
        SELECT w.month_end, m.security_id,
               sum(m.traded_value) / w.mkt_days AS avg_tv,
               sum(m.days_traded)               AS days,
               w.mkt_days,
               max(m.last_trade_date)           AS last_trade
        FROM win w
        JOIN mv_monthly_return m ON m.month_no BETWEEN w.month_no - 5 AND w.month_no
        JOIN security s          ON s.security_id = m.security_id
                                AND s.instrument_type IN ('EQUITY', 'UNKNOWN')   -- shares only
        GROUP BY w.month_end, m.security_id, w.mkt_days
    ), eligible AS (
        SELECT r.*, row_number() OVER (PARTITION BY month_end ORDER BY avg_tv DESC, security_id) AS rnk
        FROM roll r
        WHERE days >= 0.8 * mkt_days
          AND last_trade >= (SELECT min(t.trade_date) FROM (
                                 SELECT trade_date FROM trading_day WHERE trade_date <= r.month_end
                                 ORDER BY trade_date DESC LIMIT 10) t)
    )
    SELECT month_end, security_id, rnk, round(avg_tv, 2)
    FROM eligible WHERE rnk <= p_universe_size;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'universe rows: %', n;

    -- 6. Momentum portfolios: signal = compounded return over months
    --    (t − lookback + 1) … (t − skip); every one of those months must exist
    INSERT INTO portfolio_holding (strategy_id, formation_date, security_id, bucket, signal)
    WITH sig AS (
        SELECT s.strategy_id, s.n_buckets, u.month_end, u.security_id,
               exp(sum(ln(1 + m.ret))) - 1 AS signal
        FROM strategy s
        JOIN universe_member u   ON u.liquidity_rank <= s.universe_size
        JOIN mv_monthly_return m ON m.security_id = u.security_id
                                AND m.month_no BETWEEN month_no(u.month_end) - s.lookback_months + 1
                                                   AND month_no(u.month_end) - s.skip_months
        GROUP BY s.strategy_id, s.n_buckets, s.lookback_months, s.skip_months, u.month_end, u.security_id
        HAVING count(*) = s.lookback_months - s.skip_months
    )
    SELECT strategy_id, month_end, security_id,
           ntile(n_buckets) OVER (PARTITION BY strategy_id, month_end ORDER BY signal, security_id),
           round(signal, 6)
    FROM sig;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'portfolio holdings: %', n;

    ANALYZE;
END $$;

-- ---------------------------------------------------------------------
-- Read-only role (used by the analytics notebook and the injection demo)
-- ---------------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'niftyquant_readonly') THEN
        CREATE ROLE niftyquant_readonly LOGIN PASSWORD 'readonly';
    END IF;
END $$;
GRANT USAGE ON SCHEMA niftyquant TO niftyquant_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA niftyquant TO niftyquant_readonly;
