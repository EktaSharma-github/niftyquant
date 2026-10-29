# Readings inserted into the notebook by build_notebook.py (one "@@ key" line per section).
# Every number here was read off the executed notebook or 05_queries.sql output (2026-10-29 load).

@@ A1
**Reading A1.** Monthly returns are far from normal. Across 97,963 stock-months the excess
kurtosis is **7.0** (a normal has 0) and the skew is **+0.86**: most months are quiet, a few are
enormous, and the big ones are more often up than down for single stocks (the 99th percentile
is +41%, the 1st is −31%). The index is different: its skew is **−0.58**, because diversification
cancels the single-stock jumps, but crashes hit everything at once. Jarque–Bera rejects normality
outright. This is why §2 backs the t-test with a bootstrap.

@@ A5
**Reading A5.** There is only a weak liquidity premium. The least traded fifth of the
universe (ranks 401–500, about ₹12 crore a day) earned **1.20%** a month on average, against
**0.84%** for the 100 most traded (about ₹268 crore a day), with more volatility (14.0% against
11.6% a month). The ordering is not monotonic (ranks 301–400 earned less than 201–300), so liquidity
alone is not a strategy, but it is a reason the momentum test equal-weights *within* one universe
instead of comparing stocks of very different sizes.

@@ A4
**Reading A4.** The median NIFTY 500 stock has a beta of **1.14**: an equal-weighted universe is
riskier than the cap-weighted index. Construction (1.63), Realty (1.58) and Power (1.55) amplify
the market most; Healthcare (0.87), FMCG (0.92) and IT (0.98) damp it, as finance textbooks
predict for non-cyclical demand. The average R² is only about 0.25: three-quarters of a typical
stock's monthly movement is its own, not the market's.

@@ 2.1
**Reading 2.1.** Momentum works in India, strongly. Over 190 holding months (Jan 2011 – Oct 2026; October is partial),
return rises almost steadily with last year's return: the losers decile compounded at
**−7.0%** a year, the winners at **+26.3%**, against **9.9%** for the NIFTY 500. Winners-minus-losers
earned **2.34% a month** (t = 4.52; bootstrap 95% CI 1.30%–3.34%), positive in 72% of months.
The winners also had a *better* Sharpe ratio than the index (1.02 against 0.64) and a smaller
worst drawdown than the losers (−41% against −88%).

The effect is robust to the look-back but **weaker among large caps**: winners-minus-losers
compounded at 27.9% a year (Sharpe 1.13) for 12-1 deciles of the top 500, 23.6% (1.09) for 6-1,
and 13.0% (0.67) for 12-1 quintiles of the 200 most liquid stocks. Momentum is strongest where
information spreads slowest.

Three honest caveats. These are gross, price-only, equal-weighted returns; Q3 in
`05_queries.sql` shows that a 0.5% cost per rebalance on ~27% monthly turnover cuts ₹1 lakh's
final value from ₹40.5 lakh to ₹31.2 lakh (still against ₹4.4 lakh in the index). Holdings that
stopped trading in the holding month are dropped, but that is 0.05% of holdings. And a 16-year
sample contains only a handful of momentum crashes (A3).

@@ A2
**Reading A2.** The 12-1 signal ranks next month's returns better than chance in two months out
of three. The average rank correlation (IC) is **0.06**, which sounds small, but it is persistent:
t = 4.9 over 190 months. Quant managers treat an IC of 0.05 as useful because it applies to 500
stocks at once, every month.

@@ A3
**Reading A3.** Momentum crashes have one shape: a sharp market rebound after a fall. The worst
month, **June 2020** (−33.6%), came when the NIFTY 500 was up 8% after a 12-month fall of 20%: last
year's losers jumped 41%. April 2020 and January 2012 look the same. May 2014 (election result) is
the exception that proves the rule: a sudden re-rating where beaten-down cyclicals rallied 27%.
Momentum is a bet that trends continue, and it loses when the trend snaps upward.

@@ 2.2
**Reading 2.2.** Survivorship bias is real and large. Restricting the same universe to stocks
still listed today raises its equal-weighted return from **10.1% to 12.4% a year**: 2.4 points a
year of returns that never existed. The gap is widest in 2011–2014 (5–7 points a year, Q2), when the
universe held 90–140 stocks that have since delisted, and it shrinks towards zero for recent
years only because recent members haven't yet had time to fail. This is why the universe is
rebuilt at every month-end from the prices known *that day*, with delisted stocks included.

@@ 3.1
**Reading 3.1.** Two pairs are strongly related: **winner share and annual return (0.76)**, as
expected, since five years of winning *is* a high return; and **volatility and beta (0.61)**. Volatility
and drawdown move together too (−0.54: more volatile, deeper falls). We keep all seven: each pair
still carries a distinct shade (a stock can be volatile for its own reasons, with a low beta). Every
feature is **standardized** first, so no feature dominates the distances because of its units.

@@ 3.2
Silhouette is highest at k = 2 (0.25), then roughly flat for k = 3–5 (0.21). The two-cluster
split is just "the past five years' winners vs everything else". The elbow flattens after k = 4, and
four clusters each have a clear financial meaning, so **we choose k = 4** and test it in §3.3 with a
variable the model never saw. The low silhouettes are themselves a finding: stock behaviour is a
continuum, not a few tight types.

@@ 3.3
**Reading the segments.** The four groups are recognisable to any investor:

| Segment | Stocks | Return p.a. | Volatility | Beta | Worst drawdown | Dividend yield |
|---|---|---|---|---|---|---|
| Momentum Leaders | 88 | 55.6% | 57% | 1.60 | −48% | 0.6% |
| Defensive Compounders | 152 | 15.6% | 30% | 0.99 | −33% | 0.8% |
| Dividend Yielders | 36 | 15.0% | 33% | 1.10 | −40% | 4.6% |
| Volatile Laggards | 133 | 7.4% | 44% | 1.37 | −59% | 0.7% |

The most typical members make the labels concrete: Momentum Leaders are the 2021–26 capital-goods
and defence re-rating (BDL, Zen Technologies, Kirloskar, HBL); Dividend Yielders are public-sector
energy, metals and banks (NMDC, BPCL, GAIL, NHPC, Bank of Baroda); Defensive Compounders are
pharma, private finance and steady industrials (Lupin, Muthoot, Bosch).

@@ 3.4
**Reading the validation.** Sector, which the model never saw, is strongly associated with
segment: χ² = 228 on 42 degrees of freedom, p ≈ 10⁻²⁷, Cramér's V = 0.43. Healthcare (21 of 30),
FMCG (13 of 19) and Financial Services (40 of 68) are mostly Defensive Compounders; Capital Goods
is split, but its largest group (26 of 48) is Momentum Leaders; Oil & Gas (8 of 14) and Metals (6 of 13)
are mostly Dividend Yielders. Price behaviour alone recovers the economy's structure.

@@ S1
**Reading S1.** The chart shows the same thing per sector. The stocks *not* in today's NIFTY 500
list ("unclassified": liquid enough to rank in our top 500 but not index members) are almost all
Momentum Leaders or Volatile Laggards (71 of 74): the edges of the market are where the extreme
outcomes are.

@@ S2
**Reading S2.** In the market's down months (NIFTY 500 below −3%, average −5.2%), Defensive
Compounders and Dividend Yielders fell least (−4.5%). Volatile Laggards fell hardest (−7.3%: 1.4×
the market) and did not make it up in rallies (+7.5% against the market's +5.2%). Momentum Leaders
fell slightly less than the market but rose more than twice as much (+12.3%) in up months.

The caveat matters: segments and S2 are measured on **the same five years**, so "Momentum Leaders
rallied hardest" is partly true by construction. They are the stocks that went up. S2 describes how
each kind of stock behaved; it is not evidence that the pattern will repeat.

@@ Conclusions
## 6. Conclusions

**How returns behave (§1).** Single-stock returns have fat tails (excess kurtosis 7) and a
positive skew; the index has a negative skew. Beta follows economics: construction, realty and power
amplify the market, healthcare and FMCG damp it. Less traded stocks earned a little more, but not
in a straight line.

**Momentum (§2).** Last year's winners beat last year's losers by 2.34% a month for 16 years
(t = 4.5), the winners decile compounding at 26% a year against the index's 10%. The signal's rank
correlation with next month's return (IC 0.06) is small but persistent. It fails in one recognisable
situation: sharp rebounds after a fall (June 2020, April 2020, January 2012). The database design is
part of the result: a backtest on today's survivors would have added 2.4 points a year that never
existed.

**Kinds of stock (§3–5).** Four segments built only from price behaviour (Momentum Leaders,
Defensive Compounders, Dividend Yielders, Volatile Laggards) line up with sectors the model never
saw (Cramér's V 0.43). Defensive Compounders and Dividend Yielders lose least when the market falls;
Volatile Laggards lose most and don't recover it.

**Limitations.**
* Gross, price-only, equal-weighted returns; one flat cost assumption (0.5% per rebalance). Impact
  costs in the least liquid names would be higher.
* Sectors exist only for today's NIFTY 500 members, so delisted and smaller stocks are "unclassified".
* 82 price jumps around demergers and schemes of arrangement are set to 0 because NSE's notices give
  no ratio; a professional data vendor would adjust them.
* Segments are descriptive: features and outcomes (S2) come from the same five years.

*Research use only; not investment advice.*
