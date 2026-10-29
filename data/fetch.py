"""Download raw NiftyQuant source data (stdlib only, resumable).

    python data/fetch.py bhav     # NSE daily bhavcopy, 2010-01-01 .. today (weekdays)
    python data/fetch.py weekend  # probe weekends for special sessions (Muhurat, budget days)
    python data/fetch.py ca       # NSE corporate actions, month by month
    python data/fetch.py index    # NIFTY 50 / NIFTY 500 daily levels (Yahoo)
    python data/fetch.py list     # current NIFTY 500 list (sector/industry map)
    python data/fetch.py all

Files land in data/raw/. Already-downloaded files and known holidays
(data/raw/bhavcopy/missing.txt) are skipped on re-runs.
"""
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

RAW = Path(__file__).resolve().parent / "raw"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
START = dt.date(2010, 1, 1)
UDIFF_FROM = dt.date(2024, 7, 8)   # NSE switched the CM bhavcopy to UDiFF format
PAUSE = 0.25                       # seconds between requests


def get(url, referer=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    if referer:
        req.add_header("Referer", referer)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def get_retry(url, referer=None, tries=4):
    """Returns bytes, or None on 404. Retries other errors with backoff."""
    for i in range(tries):
        try:
            return get(url, referer)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            err = e
        except Exception as e:  # timeouts, resets
            err = e
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"{url}: {err}")


def old_url(d):
    mon = d.strftime("%b").upper()
    return (f"https://nsearchives.nseindia.com/content/historical/EQUITIES/"
            f"{d.year}/{mon}/cm{d.strftime('%d')}{mon}{d.year}bhav.csv.zip")


def new_url(d):
    return (f"https://nsearchives.nseindia.com/content/cm/"
            f"BhavCopy_NSE_CM_0_0_0_{d.strftime('%Y%m%d')}_F_0000.csv.zip")


def fetch_bhav(weekends=False):
    """Weekdays by default; weekends=True probes Saturdays/Sundays for special sessions
    (Diwali Muhurat trading, budget days), recording misses in a separate file."""
    out = RAW / "bhavcopy"
    out.mkdir(parents=True, exist_ok=True)
    missing_f = out / ("missing_weekend.txt" if weekends else "missing.txt")
    missing = set(missing_f.read_text().split()) if missing_f.exists() else set()
    today = dt.date.today()
    d, got, skipped = START, 0, 0
    while d <= today:
        if (d.weekday() >= 5) == weekends:
            key = d.isoformat()
            ydir = out / str(d.year)
            done = list(ydir.glob(f"{key}_*.csv.zip")) if ydir.exists() else []
            if done or key in missing:
                skipped += 1
            else:
                order = [("new", new_url), ("old", old_url)] if d >= UDIFF_FROM \
                    else [("old", old_url), ("new", new_url)]
                data = None
                for tag, fn in order:
                    data = get_retry(fn(d))
                    time.sleep(PAUSE)
                    if data and data[:2] == b"PK":
                        ydir.mkdir(exist_ok=True)
                        (ydir / f"{key}_{tag}.csv.zip").write_bytes(data)
                        got += 1
                        break
                    data = None
                if data is None and d < today:   # holiday (today may not be published yet)
                    missing.add(key)
                    with missing_f.open("a") as f:
                        f.write(key + "\n")
                if got and got % 100 == 0:
                    print(f"bhav: {got} downloaded, at {key}", flush=True)
        d += dt.timedelta(days=1)
    print(f"bhav: done. new={got} skipped={skipped} holidays={len(missing)}")


def fetch_ca():
    out = RAW / "corp_actions"
    out.mkdir(parents=True, exist_ok=True)
    ref = "https://www.nseindia.com/companies-listing/corporate-filings-actions"
    m = START.replace(day=1)
    today = dt.date.today()
    while m <= today:
        nxt = (m.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
        f = out / f"{m:%Y-%m}.json"
        current = nxt > today          # always refresh the running month
        if not f.exists() or current:
            end = nxt - dt.timedelta(days=1)
            url = ("https://www.nseindia.com/api/corporates-corporateActions?index=equities"
                   f"&from_date={m:%d-%m-%Y}&to_date={end:%d-%m-%Y}")
            data = get_retry(url, referer=ref)
            rows = json.loads(data or b"[]")
            f.write_text(json.dumps(rows, indent=0))
            print(f"ca: {m:%Y-%m} {len(rows)} rows", flush=True)
            time.sleep(1.0)
        m = nxt
    print("ca: done")


def fetch_index():
    out = RAW / "index"
    out.mkdir(parents=True, exist_ok=True)
    p1 = int(dt.datetime(2009, 1, 1).timestamp())
    p2 = int(time.time())
    for code, name in [("^NSEI", "NIFTY50"), ("^CRSLDX", "NIFTY500")]:
        url = (f"https://query1.finance.yahoo.com/v8/finance/chart/{code}"
               f"?period1={p1}&period2={p2}&interval=1d")
        data = get_retry(url)
        (out / f"{name}.json").write_bytes(data or b"{}")
        n = len(json.loads(data)["chart"]["result"][0]["timestamp"]) if data else 0
        print(f"index: {name} {n} days")


def fetch_list():
    out = RAW / "lists"
    out.mkdir(parents=True, exist_ok=True)
    for name in ["ind_nifty500list", "ind_nifty50list"]:
        data = get_retry(f"https://nsearchives.nseindia.com/content/indices/{name}.csv")
        (out / f"{name}.csv").write_bytes(data)
        print(f"list: {name} {data.count(b'\n') - 1} rows")


if __name__ == "__main__":
    jobs = {"bhav": fetch_bhav, "weekend": lambda: fetch_bhav(weekends=True), "ca": fetch_ca, "index": fetch_index, "list": fetch_list}
    args = sys.argv[1:] or ["all"]
    for a in (list(jobs) if args == ["all"] else args):
        jobs[a]()
