"""Load the raw NSE files (data/raw/, from data/fetch.py) into the NiftyQuant schema.

Steps, in one transaction (all or nothing):
  1. Read every daily bhavcopy (old format before 2024-07-08, UDiFF after), keep the
     EQ / BE / BZ series, and resolve each (symbol, ISIN) observation to a security
     (entity resolution, 01_design.md §5.6). Prices are staged in a temp file.
  2. Insert trading days, securities, alias spells, then COPY the prices.
  3. Map and parse NSE corporate actions into announcement + components.
  4. Index levels (Yahoo) and sectors (today's NIFTY 500 list).
  5. CALL refresh_research(): adjustment factors, anomalies, universe, momentum portfolios.

Rows that break a CHECK are not silently dropped: they are written to
data/work/rejected_rows.csv with the reason, and counted.

Usage:  .venv\\Scripts\\python 04_load.py
Connection: PGHOST / PGUSER / PGPASSWORD / PGDATABASE (defaults: localhost, postgres, postgres, niftyquant)
"""
import csv
import datetime as dt
import glob
import io
import json
import os
import re
import time
import zipfile
from collections import defaultdict
from decimal import Decimal, InvalidOperation

import psycopg

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "data", "raw")
WORK = os.path.join(HERE, "data", "work")
SERIES = {"EQ", "BE", "BZ"}
SERIES_PREF = {"EQ": 0, "BE": 1, "BZ": 2}     # if a stock prints in two series on one day
RELINK_DAYS = 400   # a symbol unseen for longer than this is treated as a new security if reused


def connect():
    return psycopg.connect(
        host=os.environ.get("PGHOST", "localhost"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "niftyquant"),
        options="-c search_path=niftyquant",
    )


def dec(s):
    s = (s or "").strip()
    if s in ("", "-"):
        return None
    try:
        return Decimal(s)
    except InvalidOperation:
        return None


# ---------------------------------------------------------------------
# 1. Bhavcopy reading
# ---------------------------------------------------------------------
def read_day(path):
    """Yield normalized rows for one bhavcopy file."""
    with zipfile.ZipFile(path) as z:
        with z.open(z.namelist()[0]) as fh:
            rdr = csv.reader(io.TextIOWrapper(fh, encoding="latin-1"))
            col = {name.strip(): i for i, name in enumerate(next(rdr))}
            if "TckrSymb" in col:          # UDiFF
                keys = dict(symbol="TckrSymb", series="SctySrs", isin="ISIN", name="FinInstrmNm",
                            o="OpnPric", h="HghPric", l="LwPric", c="ClsPric", p="PrvsClsgPric",
                            vol="TtlTradgVol", val="TtlTrfVal", trades="TtlNbOfTxsExctd")
                sg, tp = col["Sgmt"], col["FinInstrmTp"]
            else:
                keys = dict(symbol="SYMBOL", series="SERIES", isin="ISIN", name=None,
                            o="OPEN", h="HIGH", l="LOW", c="CLOSE", p="PREVCLOSE",
                            vol="TOTTRDQTY", val="TOTTRDVAL", trades="TOTALTRADES")
                sg = tp = None
            ix = {k: col.get(v) for k, v in keys.items()}
            i_sym, i_ser, i_isin, i_name = ix["symbol"], ix["series"], ix["isin"], ix["name"]
            nums = [(k, ix[k]) for k in ("o", "h", "l", "c", "p", "vol", "val", "trades")]
            for r in rdr:
                if len(r) <= i_ser:
                    continue
                if sg is not None and (r[sg] != "CM" or r[tp] != "STK"):
                    continue
                series = r[i_ser].strip()
                if series not in SERIES:
                    continue
                row = dict(symbol=r[i_sym].strip(), series=series,
                           isin=(r[i_isin].strip() or None) if i_isin is not None else None,
                           name=(r[i_name].strip() or None) if i_name is not None else None)
                for k, i in nums:      # kept as NSE's exact text; COPY parses it once
                    v = r[i].strip() if i is not None else ""
                    row[k] = v if v not in ("", "-") else None
                yield row


ISIN_RX = re.compile(r"IN[A-Z0-9]{10}")


def check_row(r):
    """The CHECKs of daily_price, applied before COPY so one bad row can't abort the load."""
    if None in (r["o"], r["h"], r["l"], r["c"], r["p"], r["vol"], r["val"]):
        return "missing field"
    try:
        o, h, l, c, p = (float(r[k]) for k in "ohlcp")
        vol = float(r["vol"])
        float(r["val"])
    except ValueError:
        return "non-numeric field"
    if vol == 0:
        return "no trades (zero volume)"
    if l <= 0 or p <= 0:
        return "non-positive price"
    if not (l <= min(o, c) and h >= max(o, c)):
        return "OHLC inconsistent"
    if r["isin"] and not ISIN_RX.fullmatch(r["isin"]):
        return "malformed ISIN"
    return None


class Resolver:
    """Assigns a security_id to each (symbol, isin) observation, day by day.

    Rules (01_design.md §5.6):
      R1  same ISIN as a known security → that security (catches renames)
      R2  else same symbol, seen within RELINK_DAYS → that security (catches ISIN
          changes on splits, and the pre-2011 files with no ISIN)
      R3  else a symbol that NSE's symbol-change list renamed from a recent symbol → that security
      R4  else a new security
    R2/R3 never link to a security that already traded today under another symbol (a
    security has one symbol per day, BR-3): e.g. Dhunseri Tea listed in 2015 under DTIL, a
    symbol Dhunseri Ventures had used until 2010, while Dhunseri Ventures still traded (as DPL).
    An ISIN already used today by another symbol (R1 conflict) returns None → rejected.
    """

    def __init__(self, renames):
        self.renames = renames          # new_symbol → [(effective_date, old_symbol)]
        self.by_isin, self.by_symbol = {}, {}
        self.last_seen, self.names = {}, {}
        self.spells = defaultdict(list)   # sec → [[symbol, isin, from, to]]
        self.next_id = 1
        self.rule_count = defaultdict(int)

    def _free(self, sec, d, taken):
        return (sec is not None and sec not in taken
                and (d - self.last_seen[sec]).days <= RELINK_DAYS)

    def resolve(self, d, symbol, isin, taken):
        sec, rule = None, None
        if isin and isin in self.by_isin:
            sec, rule = self.by_isin[isin], "R1"
            if sec in taken:
                return None
        elif self._free(self.by_symbol.get(symbol), d, taken):
            sec, rule = self.by_symbol[symbol], "R2"
        else:
            for eff, old in self.renames.get(symbol, []):
                cand = self.by_symbol.get(old)
                if abs((d - eff).days) <= 30 and self._free(cand, d, taken):
                    sec, rule = cand, "R3"
                    break
        if sec is None:
            sec, rule = self.next_id, "R4"
            self.next_id += 1
        self.rule_count[rule] += 1
        if isin:
            self.by_isin[isin] = sec
        self.by_symbol[symbol] = sec
        self.last_seen[sec] = d
        sp = self.spells[sec]
        if sp and sp[-1][0] == symbol and (sp[-1][1] == isin):
            sp[-1][3] = d
        else:
            sp.append([symbol, isin, d, d])
        return sec


def instrument_type(isins):
    """ISIN issuer code → instrument type (the latest ISIN wins)."""
    if not isins:
        return "UNKNOWN"
    code = isins[-1][2]
    return {"E": "EQUITY", "F": "ETF", "9": "PARTLY_PAID"}.get(code, "OTHER")


def read_renames():
    out = defaultdict(list)
    path = os.path.join(RAW, "lists", "symbolchange.csv")
    if os.path.exists(path):
        with open(path, encoding="latin-1") as fh:
            rdr = csv.reader(fh)
            next(rdr)
            for row in rdr:
                if len(row) < 4:
                    continue
                try:
                    eff = dt.datetime.strptime(row[3].strip(), "%d-%b-%Y").date()
                except ValueError:
                    continue
                out[row[2].strip()].append((eff, row[1].strip()))
    return out


def stage_prices():
    files = sorted(glob.glob(os.path.join(RAW, "bhavcopy", "*", "*.csv.zip")))
    os.makedirs(WORK, exist_ok=True)
    res = Resolver(read_renames())
    days = []
    rejects = defaultdict(int)
    staged = os.path.join(WORK, "prices.tsv")
    n = 0
    with open(staged, "w", encoding="utf-8", newline="") as out, \
         open(os.path.join(WORK, "rejected_rows.csv"), "w", encoding="utf-8", newline="") as rej:
        rw = csv.writer(rej)
        rw.writerow(["trade_date", "symbol", "series", "reason"])
        for i, f in enumerate(files):
            base = os.path.basename(f)
            d = dt.date.fromisoformat(base[:10])
            fmt = "udiff" if "_new" in base else "old"
            today = {}
            for r in read_day(f):
                if r["series"] not in SERIES:
                    continue
                why = check_row(r)
                if why:
                    rejects[why] += 1
                    rw.writerow([d, r["symbol"], r["series"], why])
                    continue
                prev = today.get(r["symbol"])
                if prev is None or SERIES_PREF[r["series"]] < SERIES_PREF[prev["series"]]:
                    today[r["symbol"]] = r
            if not today:
                continue
            days.append((d, fmt))
            seen = set()
            # strongest evidence first (known ISIN, then known symbol), so a rename (R3)
            # or a new listing can never take an id an exact match needs
            def strength(sym):
                isin = today[sym]["isin"]
                return (0 if isin and isin in res.by_isin else 1 if sym in res.by_symbol else 2, sym)
            for sym in sorted(today, key=strength):
                r = today[sym]
                sec = res.resolve(d, sym, r["isin"], seen)
                if sec is None:            # an ISIN printed under two symbols on one day
                    rejects["ISIN under two symbols on a day"] += 1
                    rw.writerow([d, sym, r["series"], "ISIN under two symbols on a day"])
                    continue
                seen.add(sec)
                if r["name"]:
                    res.names[sec] = r["name"]
                out.write(f"{sec}\t{d}\t{r['series']}\t{r['o']}\t{r['h']}\t{r['l']}\t{r['c']}\t{r['p']}\t"
                          f"{int(float(r['vol']))}\t{r['val']}\t{r['trades'] or chr(92) + 'N'}\n")
                n += 1
            if (i + 1) % 500 == 0:
                print(f"   read {i + 1}/{len(files)} days ({d}), {n:,} price rows", flush=True)
    return res, days, staged, n, rejects


# ---------------------------------------------------------------------
# 3. Corporate actions
# ---------------------------------------------------------------------
NUM = r"(\d+(?:\.\d+)?)"
RS = r"r[se]\.?\s*-?\s*"
OPT_RS = rf"(?:{RS})?"
RX = {
    # "Face Value Split ... Rs 10 ... To Rs 2", also "Fv Splt", the typo "Face Valus Split",
    # and amounts without "Rs" ("From 10/- To Face Value 2/-")
    "SPLIT": re.compile(rf"(?:face valu\w*|fv)\s*spl\w*\D*?{OPT_RS}{NUM}.*?(?<![a-z])to\s*(?:face value\s*)?{OPT_RS}{NUM}", re.I),
    "CONSOLIDATION": re.compile(rf"consolidation.*?{RS}{NUM}.*?to\s*{RS}{NUM}", re.I),
    # "Bonus 1:1", "Bonus Issue 1 : 1", "Bonus Shares In The Ratio Of 1:1" (not bonus debentures,
    # NCRPS, preference shares or DVRs: filtered in parse_subject)
    "BONUS": re.compile(rf"\bbon(?:us)?\b[^/:]{{0,40}}?{NUM}\s*:\s*{NUM}", re.I),
    "RIGHTS": re.compile(rf"rights\s*{NUM}\s*:\s*{NUM}(?:\s*@\s*premium\s*{RS}{NUM})?", re.I),
    # \b...\b so "Sub-Division" is not read as a dividend
    "DIVIDEND": re.compile(rf"\bdiv(?:idend)?\b[^/]*?{RS}{NUM}", re.I),
    "DEMERGER": re.compile(r"demerger", re.I),
    "CAPITAL_REDUCTION": re.compile(r"capital reduction", re.I),
}
IGNORABLE = re.compile(r"general mee|annual gen|closure|voting|interest|buy ?back|distribution|redemption|egm|agm|"
                       r"income|scheme of arrangement|amalgamation|merger|payment|warrant|"
                       r"premium|bond|debenture|ncrp|preference", re.I)


def parse_subject(subject, face_value):
    """Free-text NSE subject → (status, [components]). Order of components = order in text."""
    comps = []
    for code, rx in RX.items():
        for m in rx.finditer(subject):
            g = m.groups()
            c = dict(action_code=code, shares_before=None, shares_after=None,
                     cash_per_share=None, issue_price=None, pos=m.start())
            if code == "SPLIT":                       # Rs 10 → Rs 2: 1 share becomes 5
                old, new = Decimal(g[0]), Decimal(g[1])
                if not (old > new > 0):
                    continue
                c["shares_before"], c["shares_after"] = Decimal(1), old / new
            elif code == "CONSOLIDATION":             # Re 1 → Rs 10: 10 shares become 1
                old, new = Decimal(g[0]), Decimal(g[1])
                if not (new > old > 0):
                    continue
                c["shares_before"], c["shares_after"] = new / old, Decimal(1)
            elif code in ("BONUS", "RIGHTS"):         # a:b = a new shares for every b held
                if code == "BONUS" and re.search(r"deb|ncrp|pref|dvr|non.?conv", m.group(0) + subject[m.end():m.end() + 20], re.I):
                    continue
                a, b = Decimal(g[0]), Decimal(g[1])
                if a <= 0 or b <= 0:
                    continue
                c["shares_before"], c["shares_after"] = b, a + b
                if code == "RIGHTS":
                    fv = dec(face_value) or Decimal(0)
                    c["issue_price"] = fv + (Decimal(g[2]) if g[2] else Decimal(0))
                    if c["issue_price"] <= 0:
                        c["issue_price"] = None
            elif code == "DIVIDEND":
                amt = Decimal(g[0])
                if amt <= 0:
                    continue
                c["cash_per_share"] = amt
            comps.append(c)
    comps.sort(key=lambda c: c["pos"])
    if comps:
        return "parsed", comps
    return ("ignored" if IGNORABLE.search(subject) else "unparsed"), []


def load_corporate_actions(cur):
    cur.execute("SELECT security_id, symbol, isin, valid_from, valid_to FROM security_alias")
    by_isin, by_sym = {}, defaultdict(list)
    for sec, sym, isin, f, t in cur.fetchall():
        if isin:
            by_isin[isin] = sec
        by_sym[sym].append((f, t, sec))

    def find(sym, isin, d):
        if isin in by_isin:
            return by_isin[isin]
        best = None
        for f, t, sec in by_sym.get(sym, []):
            gap = 0 if f <= d <= t else min(abs((d - f).days), abs((d - t).days))
            if gap <= 60 and (best is None or gap < best[0]):
                best = (gap, sec)
        return best[1] if best else None

    rows, seen = [], set()
    stats = defaultdict(int)
    for f in sorted(glob.glob(os.path.join(RAW, "corp_actions", "*.json"))):
        for x in json.load(open(f, encoding="utf-8")):
            if x.get("series") not in SERIES:
                continue
            try:
                ex = dt.datetime.strptime(x["exDate"], "%d-%b-%Y").date()
            except (ValueError, TypeError):
                stats["bad ex-date"] += 1
                continue
            subject = " ".join(x["subject"].split())[:300]
            sec = find(x["symbol"].strip(), (x.get("isin") or "").strip(), ex)
            if sec is None:
                stats["no matching security"] += 1
                continue
            key = (sec, ex, subject)
            if key in seen:
                stats["duplicate"] += 1
                continue
            seen.add(key)
            rec = dt.datetime.strptime(x["recDate"], "%d-%b-%Y").date() if x.get("recDate") not in (None, "-") else None
            status, comps = parse_subject(subject, x.get("faceVal"))
            stats[status] += 1
            rows.append((sec, ex, rec, subject, status, comps))

    comp_rows = 0
    for sec, ex, rec, subject, status, comps in rows:
        cur.execute("INSERT INTO ca_announcement (security_id, ex_date, record_date, raw_subject, parse_status) "
                    "VALUES (%s, %s, %s, %s, %s) RETURNING ann_id", (sec, ex, rec, subject, status))
        ann = cur.fetchone()[0]
        for k, c in enumerate(comps, 1):
            cur.execute("INSERT INTO ca_component VALUES (%s, %s, %s, %s, %s, %s, %s)",
                        (ann, k, c["action_code"], c["shares_before"], c["shares_after"],
                         c["cash_per_share"], c["issue_price"]))
            comp_rows += 1
    return len(rows), comp_rows, stats


# ---------------------------------------------------------------------
# 4. Index levels and sectors
# ---------------------------------------------------------------------
def load_indices(cur, trading_days):
    ist = dt.timezone(dt.timedelta(hours=5, minutes=30))
    kept = dropped = 0
    for code in ("NIFTY50", "NIFTY500"):
        path = os.path.join(RAW, "index", f"{code}.json")
        res = json.load(open(path))["chart"]["result"][0]
        closes = res["indicators"]["quote"][0]["close"]
        rows = []
        for ts, c in zip(res["timestamp"], closes):
            d = dt.datetime.fromtimestamp(ts, ist).date()
            if c is None or d not in trading_days:
                dropped += 1
                continue
            rows.append((code, d, round(c, 2)))
        rows = list({(r[0], r[1]): r for r in rows}.values())
        with cur.copy("COPY index_level (index_code, trade_date, close_lvl) FROM STDIN") as cp:
            for r in rows:
                cp.write_row(r)
        kept += len(rows)
    return kept, dropped


def load_sectors(cur, res):
    path = os.path.join(RAW, "lists", "ind_nifty500list.csv")
    with open(path, encoding="latin-1") as fh:
        rows = list(csv.DictReader(fh))
    sectors = sorted({r["Industry"].strip() for r in rows})
    cur.executemany("INSERT INTO sector (sector_name) VALUES (%s)", [(s,) for s in sectors])
    cur.execute("SELECT sector_name, sector_id FROM sector")
    sid = dict(cur.fetchall())
    matched = 0
    for r in rows:
        sec = res.by_isin.get(r["ISIN Code"].strip())
        if sec is None:
            continue
        cur.execute("UPDATE security SET sector_id = %s, security_name = %s WHERE security_id = %s",
                    (sid[r["Industry"].strip()], r["Company Name"].strip(), sec))
        matched += 1
    return len(rows), matched


def equity_names():
    path = os.path.join(RAW, "lists", "EQUITY_L.csv")
    out = {}
    if os.path.exists(path):
        with open(path, encoding="latin-1") as fh:
            for r in csv.DictReader(fh):
                out[r["SYMBOL"].strip()] = r["NAME OF COMPANY"].strip()
    return out


# ---------------------------------------------------------------------
def main():
    t0 = time.time()
    print("== 1. reading bhavcopy files and resolving securities")
    res, days, staged, n, rejects = stage_prices()
    print(f"   {len(days):,} trading days, {res.next_id - 1:,} securities, {n:,} price rows "
          f"({time.time() - t0:.0f}s)")
    print("   resolution rules used:", dict(sorted(res.rule_count.items())))
    print("   rejected rows:", dict(rejects) or "none")

    names = equity_names()
    with connect() as conn, conn.cursor() as cur:
        print("== 2. inserting days, securities, aliases, prices")
        with cur.copy("COPY trading_day (trade_date, file_format) FROM STDIN") as cp:
            for d, fmt in days:
                cp.write_row((d, fmt))
        kinds = defaultdict(int)
        with cur.copy("COPY security (security_id, security_name, instrument_type) FROM STDIN") as cp:
            for sec in range(1, res.next_id):
                last_sym = res.spells[sec][-1][0]
                kind = instrument_type([isin for _, isin, _, _ in res.spells[sec] if isin])
                kinds[kind] += 1
                cp.write_row((sec, (res.names.get(sec) or names.get(last_sym) or last_sym)[:100], kind))
        print("   instrument types:", dict(kinds))
        cur.execute("SELECT setval(pg_get_serial_sequence('security', 'security_id'), %s)", (res.next_id,))
        n_alias = 0
        with cur.copy("COPY security_alias (security_id, valid_from, valid_to, symbol, isin) FROM STDIN") as cp:
            for sec, spells in res.spells.items():
                for sym, isin, f, t in spells:
                    cp.write_row((sec, f, t, sym, isin))
                    n_alias += 1
        # Bulk-load recipe: drop the FKs, COPY, re-add them. Re-adding validates all rows in
        # one set-based pass instead of 3 lookups per row; same transaction, so no row is
        # ever visible unchecked. CHECKs and the BR-5 statement trigger still run on COPY.
        t1 = time.time()
        cur.execute("ALTER TABLE daily_price DROP CONSTRAINT fk_price_security, "
                    "DROP CONSTRAINT fk_price_day, DROP CONSTRAINT fk_price_series")
        with open(staged, "rb") as fh, cur.copy(
                "COPY daily_price (security_id, trade_date, series_code, open_px, high_px, low_px, "
                "close_px, prev_close_px, volume, traded_value, num_trades) FROM STDIN") as cp:
            while block := fh.read(1 << 20):
                cp.write(block)
        t2 = time.time()
        cur.execute("ALTER TABLE daily_price "
                    "ADD CONSTRAINT fk_price_security FOREIGN KEY (security_id) REFERENCES security ON DELETE CASCADE, "
                    "ADD CONSTRAINT fk_price_day FOREIGN KEY (trade_date) REFERENCES trading_day, "
                    "ADD CONSTRAINT fk_price_series FOREIGN KEY (series_code) REFERENCES series_type")
        print(f"   {n_alias:,} alias spells; prices copied in {t2 - t1:.0f}s, FKs validated in {time.time() - t2:.0f}s")

        print("== 3. corporate actions")
        n_ann, n_comp, st = load_corporate_actions(cur)
        print(f"   {n_ann:,} announcements, {n_comp:,} components;", dict(st))

        print("== 4. index levels and sectors")
        kept, dropped = load_indices(cur, {d for d, _ in days})
        print(f"   {kept:,} index levels ({dropped} Yahoo days not NSE trading days, dropped)")
        n500, matched = load_sectors(cur, res)
        print(f"   sectors set for {matched}/{n500} NIFTY 500 stocks")

        print("== 5. research layer (adjustments, anomalies, universe, portfolios)")
        t2 = time.time()
        conn.add_notice_handler(lambda d: print("  ", d.message_primary, flush=True))
        cur.execute("CALL refresh_research()")
        print(f"   done in {time.time() - t2:.0f}s")
    os.remove(staged)
    print(f"Loaded in {time.time() - t0:.0f}s.")


if __name__ == "__main__":
    main()
