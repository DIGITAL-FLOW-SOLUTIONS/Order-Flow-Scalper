# ScalperEA — Order Flow Scalper for MetaTrader 5

A professional-grade scalping Expert Advisor for **GBPUSD, EURUSD, USDJPY, USDCHF and XAUUSD** built on order flow analysis, session volume profile, and opening range breakout.

---

## Strategy Overview

The EA combines three complementary layers to produce high-probability scalp entries:

### Layer 1 — Order Flow Analysis
Approximates institutional-grade order flow signals using tick volume:
- **Delta**: Net buying vs. selling pressure per bar
- **Cumulative Volume Delta (CVD)**: Running total of delta — rising CVD in a falling market = hidden buying (bullish divergence)
- **Absorption**: High-volume candle with a small body → aggressive orders were absorbed by passive counterparty. Strong reversal signal.
- **Initiative Auction**: N consecutive bars in the same direction with increasing volume → sustained directional momentum
- **Exhaustion**: Price making a new extreme while volume is declining → momentum is dying, reversal likely
- **Book Sweeping**: Large price move on low relative volume → thin liquidity, be cautious

### Layer 2 — Session Volume Profile
Builds an intraday volume profile from bar-by-bar tick volume:
- **POC** (Point of Control): Price where most volume traded — acts as a magnet / pivot
- **VAH / VAL** (Value Area High/Low): Top and bottom of the 70% volume zone — boundaries of "fair value"
- **LVNs** (Low Volume Nodes): Price levels that were quickly passed through — act as rejection points and fast-travel zones
- Price *inside* the value area = balanced/ranging market
- Price *outside* the value area = imbalanced/trending market

### Layer 3 — Opening Range Breakout (ORB)
Tracks the first 30 minutes of the NY session (configurable):
- **Range High/Low** established during the opening period
- **Breakout** confirmed when price closes outside the range with above-average volume
- **Invalidation level** set at ORB mid or POC — keeps stop losses tight
- **Mean reversion** trades available when price touches range extremes without breaking
- Profit targets: 1× range extension (TP1) and 2× range extension (TP2)

### Risk Management
- ATR-based position sizing (% of account balance at risk per trade)
- **Small account safe** — when the risk-correct lot is below the broker minimum (0.01), the EA forces the minimum lot and places the trade anyway instead of skipping it. A journal warning is printed showing the actual risk % so you always know
- Break-even stop triggered after price moves `BEATRMult × ATR` in favour
- ATR trailing stop for the runner after partial close
- 50% partial close at TP1
- Daily drawdown hard stop (default 3%)
- Daily profit lock (default 4%)
- Maximum concurrent positions per symbol
- Spread filter per pair (auto-adjusted for XAUUSD / USDJPY)
- Cooldown bars after every entry to prevent over-trading

---

## File Structure

```
ea/
├── ScalperEA.mq5                    ← Main EA file (attach to chart)
├── README.md                        ← This file
└── Include/
    └── ScalperEA/
        ├── OrderFlow.mqh            ← Delta, CVD, absorption, initiative, exhaustion
        ├── VolumeProfile.mqh        ← Session volume profile (VAH/VAL/POC/LVNs)
        ├── ORB.mqh                  ← Opening Range Breakout module
        ├── RiskManager.mqh          ← Lot sizing, BE stop, trailing, partial close
        └── TradeManager.mqh         ← Signal aggregation & trade execution
```

---

## Installation

1. Open **MetaEditor** (F4 from MT5, or from the Tools menu)
2. Copy **`ScalperEA.mq5`** to:
   ```
   <MT5 Data Folder>/MQL5/Experts/ScalperEA.mq5
   ```
3. Copy the entire **`Include/ScalperEA/`** folder to:
   ```
   <MT5 Data Folder>/MQL5/Include/ScalperEA/
   ```
   The final Include path must look like:
   ```
   MQL5/Include/ScalperEA/OrderFlow.mqh
   MQL5/Include/ScalperEA/VolumeProfile.mqh
   MQL5/Include/ScalperEA/ORB.mqh
   MQL5/Include/ScalperEA/RiskManager.mqh
   MQL5/Include/ScalperEA/TradeManager.mqh
   ```
4. In MetaEditor, open `ScalperEA.mq5` and press **F7** to compile. It should show **0 errors, 0 warnings**.
5. In MT5, open a **5-minute chart** of any supported pair.
6. Drag **ScalperEA** from the Navigator onto the chart.
7. In the EA settings dialog, check **"Allow automated trading"**.
8. Press **OK**.

> **Find your MT5 Data Folder:** In MT5, go to File → Open Data Folder.

---

## Recommended Chart Setup

| Setting | Value |
|---|---|
| Chart timeframe | M5 (5-minute) |
| Symbols | EURUSD, GBPUSD, USDJPY, USDCHF, XAUUSD |
| One chart per symbol | Yes — run a separate instance per pair |
| Broker | ECN/STP with tight spreads |
| Account type | Netting or Hedging (both supported) |

---

## Input Parameters

### General
| Parameter | Default | Description |
|---|---|---|
| Magic | 20240101 | Unique ID per EA instance. Use different values per chart. |
| Comment | ScalperEA | Order comment label |

### Session (GMT Hours)
| Parameter | Default | Description |
|---|---|---|
| NY Open Hour | 13 | GMT hour of NY session start (13 = 9 AM EST) |
| NY Close Hour | 21 | GMT hour to stop trading (21 = 5 PM EST) |
| London Open Hour | 8 | Used as fallback for volume profile build |
| ORB Minutes | 30 | Duration of the opening range (15 or 30 recommended) |
| Trade NY Only | true | Restrict entries to the NY session window |

> Adjust these if your broker uses a different server timezone. Use `TimeCurrent()` in a test script to verify.

### Risk Management
| Parameter | Default | Description |
|---|---|---|
| Risk Per Trade | 0.01 | 1% of account balance risked per trade |
| Max Daily DD | 0.03 | Stop all trading if equity drops 3% below daily open |
| Daily Profit Stop | 0.04 | Lock profits and stop after 4% daily gain |
| Max Positions | 2 | Concurrent open positions per symbol |
| SL ATR Mult | 1.0 | Stop loss = 1× ATR from entry |
| BE ATR Mult | 0.8 | Move to break-even after 0.8× ATR profit |
| Trail ATR Mult | 1.2 | Trailing stop distance = 1.2× ATR |
| TP1 ATR Mult | 1.5 | Partial close trigger = 1.5× ATR profit |

### Entry Filters
| Parameter | Default | Description |
|---|---|---|
| OF Timeframe | 5 | Minutes for order flow analysis (5 or 15 recommended) |
| VP Timeframe | 15 | Minutes for volume profile construction |
| ATR Period | 14 | Period for ATR calculations |
| Max Spread (pips) | 3.0 | Skip entry if spread exceeds this |
| XAUUSD Max Spread | 8.0 | Separate spread limit for Gold |
| USDJPY Max Spread | 2.0 | Separate spread limit for JPY pairs |
| Min Confluence | 2 | How many confirming signals required (2–3 recommended) |
| Allow Long | true | Enable long trades |
| Allow Short | true | Enable short trades |
| ORB Enabled | true | Enable the ORB layer |
| VP Enabled | true | Enable the volume profile layer |
| Cooldown Bars | true | Pause entries for N bars after a trade |
| Cooldown Count | 3 | Number of bars to wait after entry |

---

## Signal Logic (How Entries Are Triggered)

An entry is generated when a minimum number of the following signals align in the same direction:

**Bullish signals (+1 each):**
- Order flow score > threshold (net buying pressure)
- Price at or below VAL (value area support)
- CVD slope accelerating upward (buying momentum)
- Delta divergence bullish (price falling while CVD rising)
- Absorption detected on last bar, bullish direction
- ORB bullish breakout or mean-reversion from range bottom

**Bearish signals (−1 each, mirror of above)**

**Blockers (entry skipped):**
- Book sweep detected (thin liquidity — unreliable)
- Exhaustion signal matches proposed direction (momentum dying)
- Spread exceeds limit
- Outside session hours
- Daily risk limits hit
- Cooldown active
- Max positions reached

---

## Backtesting Guide

1. Open MetaStrategy Tester (Ctrl+R in MT5)
2. Select **ScalperEA** from the Expert dropdown
3. Choose your symbol (e.g. EURUSD)
4. Set timeframe to **M5**
5. Set model to **"Every tick based on real ticks"** (most accurate) or **"Every tick"**
6. Select a date range — minimum 6 months of data recommended
7. Click **Start**

**Expected characteristics in backtesting:**
- Win rate: targeting 60–70%+ (from notes: high win rate is essential for prop firm survival)
- Risk:Reward: 1:1.5 on TP1 (50%), trailing into TP2 (runner)
- Average trades per day: 1–4 per symbol depending on session volatility
- Should see reduced drawdown during low-volume / choppy periods due to confluence filters

**Optimisation suggestions:**
- `InpSLATRMult` (0.8–1.5): Tighter SL = better RR but lower win rate
- `InpMinConfluence` (2–3): Higher = fewer but better trades
- `InpORBMinutes` (15 or 30): Test both for your broker's data
- `InpRiskPct` (0.005–0.015): Adjust after establishing profitability

---

## Live Trading Notes

- **One EA instance per chart per symbol.** Set different `Magic` numbers if you run multiple symbols.
- The EA trades the **New York session by default** — the highest liquidity period where order flow signals are most reliable.
- For **XAUUSD (Gold)**: spreads are wider and volatility is higher. The EA automatically applies a wider spread filter. Consider using M5 with `InpMinConfluence = 3` for Gold.
- For **USDJPY**: fast-moving pair with tight spreads — works well with default settings.
- **Always run on a demo account first** for at least 2–4 weeks before live trading.
- Ensure your broker provides **real-time tick data** and **has minimal requotes**.

---

## Strategy Notes from Order Flow Research

Key principles embedded in this EA:
- **Absorption** is the most reliable signal: high volume + small candle body = strong counterparty defending a level. Enter when the defending side is expected to push back.
- **Initiative Auction** confirms trend: multiple bars with increasing volume in the same direction means institutional momentum — trade with it, not against it.
- **CVD Divergence** reveals hidden hands: when price falls but CVD rises, large buyers are absorbing sellers quietly. High-probability reversal setup.
- **ORB + Volume confirmation** filters fake breakouts: a breakout needs volume to be real. Low-volume ORB breaks are traps.
- **Stop losses placed behind absorption levels**: if the absorption zone breaks, the thesis is wrong. This keeps losses small and precise.
- **Partial close at TP1 + trail**: locks in profit while letting winners run — the professional approach described across all the session notes.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| Compile error: file not found | Ensure Include/ScalperEA/ is in MQL5/Include/ScalperEA/ |
| No trades firing | Check session hours match your broker timezone; verify spread is within limit |
| Too many trades | Increase `InpMinConfluence` to 3 |
| Too few trades | Decrease `InpMinConfluence` to 2, or disable `InpTradeNYOnly` |
| Wrong session timing | Check your broker's server time vs GMT in the journal |
| EA stops trading mid-day | Daily DD or profit target hit — normal protective behaviour |

---

## Disclaimer

This EA is for educational and research purposes. Past performance in backtesting does not guarantee future results. All trading involves risk of loss. Always test thoroughly on a demo account before risking real capital.
