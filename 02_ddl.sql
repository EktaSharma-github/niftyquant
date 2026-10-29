-- =====================================================================
-- NiftyQuant — NSE Equity Market & Momentum Research Database
-- 02_ddl.sql : schema, keys, CHECKs, and reference data
-- Target: PostgreSQL 18 (15+). Re-runnable: drops and recreates the schema.
-- Design rationale: 01_design.md (BR-n = business rule n)
-- =====================================================================

SET client_min_messages = warning;   -- hide the DROP ... CASCADE notices
DROP SCHEMA IF EXISTS niftyquant CASCADE;
CREATE SCHEMA niftyquant;
SET search_path = niftyquant;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- '=' inside GiST exclusion constraints (BR-2)

-- ---------------------------------------------------------------------
-- 1. Lookup tables: facts about a category, not about a row that uses it
-- ---------------------------------------------------------------------
CREATE TABLE series_type (
    series_code      varchar(2) PRIMARY KEY,
    description      varchar(60) NOT NULL,
    rolling_settled  boolean NOT NULL      -- FD: series → settlement regime (BE/BZ = trade-for-trade)
);

CREATE TABLE action_type (
    action_code   varchar(18) PRIMARY KEY,
    description   varchar(60) NOT NULL,
    changes_shares boolean NOT NULL        -- FD: action → whether the share count changes (BR-9)
);

CREATE TABLE market_index (
    index_code  varchar(10) PRIMARY KEY,
    index_name  varchar(40) NOT NULL UNIQUE,
    source      varchar(40) NOT NULL       -- provenance of the levels
);

-- ---------------------------------------------------------------------
-- 2. Calendar: a day exists only if NSE published a bhavcopy for it
-- ---------------------------------------------------------------------
CREATE TABLE trading_day (
    trade_date   date PRIMARY KEY,   -- BR-1; not "weekdays only": NSE holds Muhurat and budget-day weekend sessions
    file_format  varchar(5) NOT NULL CHECK (file_format IN ('old', 'udiff'))
    -- month-end flag is derived from the set of days: view v_month_end in 03
);

-- ---------------------------------------------------------------------
-- 3. Securities and their identifiers over time (entity resolution, §5.6)
-- ---------------------------------------------------------------------
CREATE TABLE sector (
    sector_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sector_name  varchar(60) NOT NULL UNIQUE
);

CREATE TABLE security (
    security_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_name  varchar(100) NOT NULL,           -- latest name seen
    -- From the ISIN's issuer code: INE = company share, INF = mutual fund / ETF unit,
    -- IN9 = partly paid share. UNKNOWN = delisted before NSE printed ISINs (late 2011).
    -- The EQ series carries all of them; only shares belong in the universe (BR-10).
    instrument_type varchar(12) NOT NULL
                   CHECK (instrument_type IN ('EQUITY', 'ETF', 'PARTLY_PAID', 'OTHER', 'UNKNOWN')),
    sector_id      smallint REFERENCES sector       -- NULL = not in today's NIFTY 500 (unclassified)
);

-- Symbols get renamed and ISINs change on splits: one row per (symbol, ISIN) spell.
-- Before ~Oct 2011 the bhavcopy carries no ISIN, so isin is NULL for those spells.
CREATE TABLE security_alias (
    security_id  integer NOT NULL REFERENCES security ON DELETE CASCADE,
    valid_from   date NOT NULL,
    valid_to     date NOT NULL,
    symbol       varchar(20) NOT NULL,
    isin         char(12) CHECK (isin ~ '^IN[A-Z0-9]{10}$'),
    PRIMARY KEY (security_id, valid_from),
    CHECK (valid_from <= valid_to),
    -- BR-2: at any date a symbol (and an ISIN) identifies at most one security
    EXCLUDE USING gist (symbol WITH =, daterange(valid_from, valid_to, '[]') WITH &&),
    EXCLUDE USING gist (isin WITH =, daterange(valid_from, valid_to, '[]') WITH &&) WHERE (isin IS NOT NULL),
    -- BR-3: a security's own spells don't overlap either
    EXCLUDE USING gist (security_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);
CREATE INDEX ix_alias_symbol ON security_alias (symbol);

-- ---------------------------------------------------------------------
-- 4. Market facts
-- ---------------------------------------------------------------------
-- Raw, unadjusted end-of-day prices exactly as NSE published them (BR-4, BR-5)
CREATE TABLE daily_price (
    -- FKs are named: 04_load.py drops and re-adds them around the bulk COPY (§8)
    security_id    integer NOT NULL CONSTRAINT fk_price_security REFERENCES security ON DELETE CASCADE,
    trade_date     date    NOT NULL CONSTRAINT fk_price_day      REFERENCES trading_day,
    series_code    varchar(2) NOT NULL CONSTRAINT fk_price_series REFERENCES series_type,
    open_px       numeric(12,2) NOT NULL,
    high_px        numeric(12,2) NOT NULL,
    low_px         numeric(12,2) NOT NULL,
    close_px       numeric(12,2) NOT NULL,
    prev_close_px  numeric(12,2) NOT NULL,     -- as reported (adjusted by NSE only in the old format)
    volume         bigint  NOT NULL CHECK (volume >= 0),
    traded_value   numeric(18,2) NOT NULL CHECK (traded_value >= 0),   -- rupees
    num_trades     integer CHECK (num_trades >= 0),                     -- absent before late 2011
    PRIMARY KEY (security_id, trade_date),
    CHECK (low_px > 0 AND prev_close_px > 0),
    CHECK (low_px <= least(open_px, close_px) AND high_px >= greatest(open_px, close_px))
);
CREATE INDEX ix_price_date ON daily_price (trade_date);

CREATE TABLE index_level (
    index_code  varchar(10) REFERENCES market_index,
    trade_date  date REFERENCES trading_day,
    close_lvl   numeric(12,2) NOT NULL CHECK (close_lvl > 0),
    PRIMARY KEY (index_code, trade_date)
);

-- ---------------------------------------------------------------------
-- 5. Corporate actions: one announcement may bundle several actions
--    ("Bonus 1:1 / Face Value Split ..."), so the free-text subject is
--    split into components (1NF, §5.2)
-- ---------------------------------------------------------------------
CREATE TABLE ca_announcement (
    ann_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id   integer NOT NULL REFERENCES security ON DELETE CASCADE,
    ex_date       date NOT NULL,              -- may be a holiday or a day the stock didn't trade
    record_date   date,
    raw_subject   varchar(300) NOT NULL,      -- kept verbatim: provenance for every parsed number
    parse_status  varchar(10) NOT NULL CHECK (parse_status IN ('parsed', 'ignored', 'unparsed')),
    UNIQUE (security_id, ex_date, raw_subject)
);

CREATE TABLE ca_component (
    ann_id          integer REFERENCES ca_announcement ON DELETE CASCADE,
    component_no    smallint CHECK (component_no >= 1),
    action_code     varchar(18) NOT NULL REFERENCES action_type,
    shares_before   numeric(12,4),      -- e.g. split Rs10→Rs2: 1 share before, 5 after
    shares_after    numeric(12,4),
    cash_per_share  numeric(12,4),      -- dividends
    issue_price     numeric(12,4),      -- rights issue price (face value + premium)
    PRIMARY KEY (ann_id, component_no),
    CHECK (shares_before > 0 AND shares_after > 0 OR shares_before IS NULL AND shares_after IS NULL),
    CHECK (cash_per_share > 0 OR cash_per_share IS NULL),
    -- BR-9: which attributes an action carries depends on its type (checked against action_type in 03)
    CHECK (action_code <> 'DIVIDEND' OR (cash_per_share IS NOT NULL AND shares_before IS NULL))
);

-- The one place the return calculation gets its adjustment factors from (BR-6, BR-7).
-- factor = the multiplier applied to the previous close on ex_date (split 1→5: 0.2).
CREATE TABLE price_adjustment (
    security_id  integer NOT NULL,
    ex_date      date    NOT NULL,             -- first day the stock traded ex
    factor       numeric(14,8) NOT NULL CHECK (factor > 0 AND factor <> 1),
    source       varchar(14) NOT NULL CHECK (source IN ('NSE_PREVCLOSE', 'CORP_ACTION', 'MANUAL')),
    note         varchar(200),
    PRIMARY KEY (security_id, ex_date),
    -- BR-6: an adjustment applies on a day the stock actually traded
    FOREIGN KEY (security_id, ex_date) REFERENCES daily_price ON DELETE CASCADE
);

-- Daily moves too large to be real that no adjustment explains (filled by 03's refresh)
CREATE TABLE price_anomaly (
    security_id   integer NOT NULL,
    trade_date    date    NOT NULL,
    raw_return    numeric(10,4) NOT NULL,
    resolution    varchar(10) NOT NULL DEFAULT 'open'
                  CHECK (resolution IN ('open', 'genuine', 'excluded')),
    note          varchar(200),
    PRIMARY KEY (security_id, trade_date),
    FOREIGN KEY (security_id, trade_date) REFERENCES daily_price ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 6. Research layer: point-in-time universe and strategy portfolios
-- ---------------------------------------------------------------------
-- Top-N most liquid stocks at each month-end, using only data known then
-- (survivorship-free: delisted stocks are members while they traded; BR-10)
CREATE TABLE universe_member (
    month_end         date    NOT NULL REFERENCES trading_day,
    security_id       integer NOT NULL REFERENCES security ON DELETE CASCADE,
    liquidity_rank    smallint NOT NULL CHECK (liquidity_rank >= 1),
    avg_traded_value  numeric(18,2) NOT NULL CHECK (avg_traded_value > 0),
    PRIMARY KEY (month_end, security_id),
    UNIQUE (month_end, liquidity_rank)
);

CREATE TABLE strategy (
    strategy_id      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    strategy_code    varchar(20) NOT NULL UNIQUE,
    description      varchar(200) NOT NULL,
    lookback_months  smallint NOT NULL CHECK (lookback_months BETWEEN 1 AND 36),
    skip_months      smallint NOT NULL CHECK (skip_months >= 0),
    n_buckets        smallint NOT NULL CHECK (n_buckets BETWEEN 2 AND 20),
    universe_size    smallint NOT NULL CHECK (universe_size >= 50),
    CHECK (skip_months < lookback_months)
);

-- A holding can only be a stock that was in the universe on the formation date
-- (composite FK = no look-ahead, BR-11); bucket ≤ n_buckets is a trigger (BR-12)
CREATE TABLE portfolio_holding (
    strategy_id     smallint NOT NULL REFERENCES strategy ON DELETE CASCADE,
    formation_date  date     NOT NULL,
    security_id     integer  NOT NULL,
    bucket          smallint NOT NULL CHECK (bucket >= 1),      -- 1 = losers … n = winners
    signal          numeric(12,6) NOT NULL,                     -- the momentum return ranked on
    PRIMARY KEY (strategy_id, formation_date, security_id),
    FOREIGN KEY (formation_date, security_id) REFERENCES universe_member
);

-- ---------------------------------------------------------------------
-- 7. Reference data
-- ---------------------------------------------------------------------
INSERT INTO series_type VALUES
    ('EQ', 'Equity, rolling settlement', true),
    ('BE', 'Trade-for-trade (compulsory delivery, no intraday netting)', false),
    ('BZ', 'Trade-for-trade, non-compliant / suspended category', false);

INSERT INTO action_type VALUES
    ('SPLIT',          'Face-value sub-division',                 true),
    ('CONSOLIDATION',  'Face-value consolidation (reverse split)', true),
    ('BONUS',          'Bonus issue',                              true),
    ('RIGHTS',         'Rights issue',                             true),
    ('DIVIDEND',       'Cash dividend (final, interim or special)',false),
    ('DEMERGER',       'Demerger / scheme of arrangement',         false),
    ('CAPITAL_REDUCTION', 'Capital reduction',                     true),
    ('OTHER',          'AGM, interest payment, buy-back, etc.',    false);

INSERT INTO market_index VALUES
    ('NIFTY50',  'NIFTY 50',  'Yahoo Finance ^NSEI'),
    ('NIFTY500', 'NIFTY 500', 'Yahoo Finance ^CRSLDX');

INSERT INTO strategy (strategy_code, description, lookback_months, skip_months, n_buckets, universe_size) VALUES
    ('MOM_12_1',      '12-1 momentum: past 12 months skipping the latest, deciles of the 500 most liquid', 12, 1, 10, 500),
    ('MOM_6_1',       '6-1 momentum: past 6 months skipping the latest, deciles of the 500 most liquid',    6, 1, 10, 500),
    ('MOM_12_1_T200', '12-1 momentum, quintiles of the 200 most liquid (large-cap proxy)',                12, 1,  5, 200);
