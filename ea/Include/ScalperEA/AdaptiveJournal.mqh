//+------------------------------------------------------------------+
//|  AdaptiveJournal.mqh  —  Adaptive Trade Journal                  |
//|  Records every real trade with full signal conditions,           |
//|  tracks MAE/MFE on every tick while open, writes CSV on close.  |
//|  Each symbol gets its own CSV: ScalperEA_Journal_SYMBOL.csv     |
//|  CSV lives in: MT5/MQL5/Files/  (standard Files folder)         |
//|                                                                  |
//|  Stats Cache: rolling in-memory performance window that feeds   |
//|  three live intelligence systems:                                |
//|    1. Adaptive SL/TP  — widens/tightens based on real noise     |
//|    2. Signal Filter   — raises entry bar when win rate drops     |
//|    3. LTM Pattern     — flags trades matching loser profile      |
//+------------------------------------------------------------------+
#ifndef ADAPTIVEJOURNAL_MQH
#define ADAPTIVEJOURNAL_MQH

#define AJ_MAX_TRADES    20    // Max concurrent tracked positions
#define AJ_CSV_DEFAULT   "ScalperEA_Journal.csv"
#define AJ_CACHE_SIZE    50    // Rolling stats window depth

//--------------------------------------------------------------------
//  Signal snapshot captured at trade entry
//--------------------------------------------------------------------
struct AJ_Snapshot
{
   int      ofScore;
   int      vpBias;
   int      orbSig;
   bool     absorption;
   int      exhaustion;
   int      deltaDiv;
   int      confluence;
   double   atr;
   double   spreadPips;
   int      hourGMT;
};

//--------------------------------------------------------------------
//  Per-trade tracking record (lives in memory while trade is open)
//--------------------------------------------------------------------
struct AJ_TradeRecord
{
   ulong       ticket;
   string      symbol;
   int         direction;        // +1=LONG  -1=SHORT
   bool        wasReversed;      // Was REVERSER active for this trade?
   datetime    entryTime;
   double      entryPrice;
   double      slPrice;
   double      tp1Price;
   double      tp2Price;
   AJ_Snapshot snap;
   // Running extremes — updated on EVERY TICK to capture intra-bar spikes
   double      mfe;              // Max Favorable Excursion (price, in trade direction)
   double      mae;              // Max Adverse Excursion  (price, stored positive)
   int         barsOpen;
   bool        active;
};

//--------------------------------------------------------------------
//  Rolling stats cache — populated on trade close, read on every bar.
//  No CSV I/O on hot path; all queries are cheap array scans.
//--------------------------------------------------------------------
struct AJ_StatsCache
{
   double maeR[AJ_CACHE_SIZE];             // MAE in R-multiples (positive)
   double mfeR[AJ_CACHE_SIZE];             // MFE in R-multiples (positive)
   bool   won[AJ_CACHE_SIZE];              // true = trade was profitable
   bool   reversalWouldWin[AJ_CACHE_SIZE]; // true = reverse direction likely won
   int    confluence[AJ_CACHE_SIZE];       // signal confluence at entry
   int    ofScore[AJ_CACHE_SIZE];          // order flow score at entry
   int    hourGMT[AJ_CACHE_SIZE];          // GMT hour of entry
   double spreadPips[AJ_CACHE_SIZE];       // spread at entry
   int    barsOpen[AJ_CACHE_SIZE];         // how many bars the trade stayed open

   int    head;   // next write position (circular)
   int    count;  // total trades recorded (capped at AJ_CACHE_SIZE)
};

AJ_TradeRecord g_aj_trades[AJ_MAX_TRADES];
AJ_StatsCache  g_aj_cache;
string         g_aj_file  = AJ_CSV_DEFAULT;
bool           g_aj_ready = false;

//--------------------------------------------------------------------
//  Write the CSV header (called once on first run or new file)
//--------------------------------------------------------------------
void AJ_WriteHeader(string filename)
{
   int fh = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;
   FileWrite(fh,
      "Ticket","Symbol","Direction","Reversed",
      "EntryTime","EntryPrice","SL","TP1","TP2",
      "ExitTime","ExitPrice","ExitReason",
      "ProfitLoss",
      "MAE_price","MFE_price","MAE_R","MFE_R",
      "BarsOpen",
      "OFScore","VPBias","ORBSignal","Absorption",
      "Exhaustion","DeltaDiv","Confluence",
      "HourGMT","ATR","SpreadPips",
      "ReversalWouldWin");
   FileClose(fh);
}

//--------------------------------------------------------------------
//  Initialise — call once in OnInit()
//--------------------------------------------------------------------
void AJ_Init(string symbol, string filename = AJ_CSV_DEFAULT)
{
   g_aj_file = (filename == "" || filename == AJ_CSV_DEFAULT)
               ? "ScalperEA_Journal_" + symbol + ".csv"
               : filename;

   for(int i = 0; i < AJ_MAX_TRADES; i++)
      g_aj_trades[i].active = false;

   ArrayInitialize(g_aj_cache.maeR,            0);
   ArrayInitialize(g_aj_cache.mfeR,            0);
   ArrayInitialize(g_aj_cache.won,         false);
   ArrayInitialize(g_aj_cache.reversalWouldWin, false);
   ArrayInitialize(g_aj_cache.confluence,       0);
   ArrayInitialize(g_aj_cache.ofScore,          0);
   ArrayInitialize(g_aj_cache.hourGMT,          0);
   ArrayInitialize(g_aj_cache.spreadPips,       0);
   ArrayInitialize(g_aj_cache.barsOpen,         0);
   g_aj_cache.head  = 0;
   g_aj_cache.count = 0;

   if(!FileIsExist(g_aj_file))
      AJ_WriteHeader(g_aj_file);

   g_aj_ready = true;
   Print("AdaptiveJournal [", symbol, "]: ready — logging to ", g_aj_file);
}

//--------------------------------------------------------------------
//  Internal: find a free tracking slot / find slot by ticket
//--------------------------------------------------------------------
int AJ_FreeSlot()
{
   for(int i = 0; i < AJ_MAX_TRADES; i++)
      if(!g_aj_trades[i].active) return i;
   return -1;
}
int AJ_FindSlot(ulong ticket)
{
   for(int i = 0; i < AJ_MAX_TRADES; i++)
      if(g_aj_trades[i].active && g_aj_trades[i].ticket == ticket) return i;
   return -1;
}

//--------------------------------------------------------------------
//  Register a newly placed real trade
//--------------------------------------------------------------------
void AJ_RegisterTrade(ulong ticket, string symbol, int direction,
                      bool wasReversed,
                      double entryPrice, double slPrice,
                      double tp1Price, double tp2Price,
                      const AJ_Snapshot &snap)
{
   if(!g_aj_ready) return;
   int slot = AJ_FreeSlot();
   if(slot < 0)
   {
      Print("AdaptiveJournal: tracking array full — cannot record #", ticket);
      return;
   }
   g_aj_trades[slot].ticket       = ticket;
   g_aj_trades[slot].symbol       = symbol;
   g_aj_trades[slot].direction    = direction;
   g_aj_trades[slot].wasReversed  = wasReversed;
   g_aj_trades[slot].entryTime    = TimeGMT();
   g_aj_trades[slot].entryPrice   = entryPrice;
   g_aj_trades[slot].slPrice      = slPrice;
   g_aj_trades[slot].tp1Price     = tp1Price;
   g_aj_trades[slot].tp2Price     = tp2Price;
   g_aj_trades[slot].snap         = snap;
   g_aj_trades[slot].mfe          = 0;
   g_aj_trades[slot].mae          = 0;
   g_aj_trades[slot].barsOpen     = 0;
   g_aj_trades[slot].active       = true;

   if(g_debugMode)
      DBG(StringFormat("AJ: registered trade #%I64u %s %s",
                        ticket, symbol, direction > 0 ? "LONG" : "SHORT"));
}

//--------------------------------------------------------------------
//  Update MAE/MFE — call on EVERY TICK.
//  Tick-level sampling captures intra-bar price spikes fully.
//  A bar that moves 100 pips then reverses is never misrecorded.
//--------------------------------------------------------------------
void AJ_UpdateOnTick(string symbol)
{
   if(!g_aj_ready) return;
   for(int i = 0; i < AJ_MAX_TRADES; i++)
   {
      if(!g_aj_trades[i].active || g_aj_trades[i].symbol != symbol) continue;
      if(!PositionSelectByTicket(g_aj_trades[i].ticket)) continue;

      double cur = (g_aj_trades[i].direction > 0)
                   ? SymbolInfoDouble(symbol, SYMBOL_BID)
                   : SymbolInfoDouble(symbol, SYMBOL_ASK);

      // excursion > 0: price moved in trade direction (favourable)
      // excursion < 0: price moved against the trade (adverse)
      double excursion = (g_aj_trades[i].direction > 0)
                         ? cur - g_aj_trades[i].entryPrice
                         : g_aj_trades[i].entryPrice - cur;

      if( excursion > g_aj_trades[i].mfe) g_aj_trades[i].mfe =  excursion;
      if(-excursion > g_aj_trades[i].mae) g_aj_trades[i].mae = -excursion;
   }
}

//--------------------------------------------------------------------
//  Increment bar counter — call each new bar (kept separate from
//  AJ_UpdateOnTick so bar counting stays bar-accurate).
//--------------------------------------------------------------------
void AJ_IncrementBars(string symbol)
{
   if(!g_aj_ready) return;
   for(int i = 0; i < AJ_MAX_TRADES; i++)
   {
      if(!g_aj_trades[i].active || g_aj_trades[i].symbol != symbol) continue;
      if(!PositionSelectByTicket(g_aj_trades[i].ticket)) continue;
      g_aj_trades[i].barsOpen++;
   }
}

//--------------------------------------------------------------------
//  Write one closed trade to CSV
//--------------------------------------------------------------------
void AJ_WriteRecord(const AJ_TradeRecord &r,
                    datetime exitTime, double exitPrice,
                    double profitLoss, string exitReason)
{
   double slDist = MathAbs(r.entryPrice - r.slPrice);
   double maeR   = (slDist > 0) ? r.mae / slDist : 0;
   double mfeR   = (slDist > 0) ? r.mfe / slDist : 0;
   bool reversalWouldWin = (profitLoss < 0 && mfeR < 0.3 && maeR > 0.8);

   int fh = FileOpen(g_aj_file, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
   {
      Print("AdaptiveJournal: cannot open file for writing: ", g_aj_file);
      return;
   }
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh,
      (string)r.ticket,
      r.symbol,
      r.direction > 0 ? "LONG" : "SHORT",
      r.wasReversed ? "YES" : "NO",
      TimeToString(r.entryTime, TIME_DATE|TIME_MINUTES),
      DoubleToString(r.entryPrice, 5),
      DoubleToString(r.slPrice, 5),
      DoubleToString(r.tp1Price, 5),
      DoubleToString(r.tp2Price, 5),
      TimeToString(exitTime, TIME_DATE|TIME_MINUTES),
      DoubleToString(exitPrice, 5),
      exitReason,
      DoubleToString(profitLoss, 2),
      DoubleToString(r.mae, 5),
      DoubleToString(r.mfe, 5),
      DoubleToString(maeR, 2),
      DoubleToString(mfeR, 2),
      (string)r.barsOpen,
      (string)r.snap.ofScore,
      (string)r.snap.vpBias,
      (string)r.snap.orbSig,
      r.snap.absorption ? "Y" : "N",
      (string)r.snap.exhaustion,
      (string)r.snap.deltaDiv,
      (string)r.snap.confluence,
      (string)r.snap.hourGMT,
      DoubleToString(r.snap.atr, 5),
      DoubleToString(r.snap.spreadPips, 2),
      reversalWouldWin ? "YES" : "NO");
   FileClose(fh);
}

//--------------------------------------------------------------------
//  Internal: populate stats cache from one completed trade.
//  Called from AJ_CheckClosedTrades after writing the CSV row.
//--------------------------------------------------------------------
void AJ_CacheRecord(const AJ_TradeRecord &r, double pl)
{
   double slDist = MathAbs(r.entryPrice - r.slPrice);
   double maeR   = (slDist > 0) ? r.mae / slDist : 0;
   double mfeR   = (slDist > 0) ? r.mfe / slDist : 0;

   int h = g_aj_cache.head;
   g_aj_cache.maeR[h]             = maeR;
   g_aj_cache.mfeR[h]             = mfeR;
   g_aj_cache.won[h]              = (pl > 0);
   g_aj_cache.reversalWouldWin[h] = (pl < 0 && mfeR < 0.3 && maeR > 0.8);
   g_aj_cache.confluence[h]       = r.snap.confluence;
   g_aj_cache.ofScore[h]          = r.snap.ofScore;
   g_aj_cache.hourGMT[h]          = r.snap.hourGMT;
   g_aj_cache.spreadPips[h]       = r.snap.spreadPips;
   g_aj_cache.barsOpen[h]         = r.barsOpen;

   g_aj_cache.head  = (h + 1) % AJ_CACHE_SIZE;
   g_aj_cache.count = MathMin(g_aj_cache.count + 1, AJ_CACHE_SIZE);
}

//--------------------------------------------------------------------
//  Detect closed trades, write CSV, populate cache.
//  Call each new bar.
//--------------------------------------------------------------------
void AJ_CheckClosedTrades(string symbol)
{
   if(!g_aj_ready) return;
   for(int i = 0; i < AJ_MAX_TRADES; i++)
   {
      if(!g_aj_trades[i].active || g_aj_trades[i].symbol != symbol) continue;
      if(PositionSelectByTicket(g_aj_trades[i].ticket)) continue;  // still open

      datetime exitTime  = TimeGMT();
      double   exitPrice = (g_aj_trades[i].direction > 0)
                           ? SymbolInfoDouble(symbol, SYMBOL_BID)
                           : SymbolInfoDouble(symbol, SYMBOL_ASK);
      double   pl        = 0;
      string   reason    = "UNKNOWN_HIST";

      if(HistorySelectByPosition(g_aj_trades[i].ticket))
      {
         int total = HistoryDealsTotal();
         for(int d = total - 1; d >= 0; d--)
         {
            ulong dk = HistoryDealGetTicket(d);
            long  de = HistoryDealGetInteger(dk, DEAL_ENTRY);
            if(de == DEAL_ENTRY_OUT || de == DEAL_ENTRY_INOUT)
            {
               exitTime  = (datetime)HistoryDealGetInteger(dk, DEAL_TIME);
               exitPrice = HistoryDealGetDouble(dk, DEAL_PRICE);
               pl        = HistoryDealGetDouble(dk, DEAL_PROFIT)
                         + HistoryDealGetDouble(dk, DEAL_SWAP)
                         + HistoryDealGetDouble(dk, DEAL_COMMISSION);
               ENUM_DEAL_REASON dr = (ENUM_DEAL_REASON)
                                     HistoryDealGetInteger(dk, DEAL_REASON);
               if(dr == DEAL_REASON_SL)          reason = "SL_HIT";
               else if(dr == DEAL_REASON_TP)     reason = "TP_HIT";
               else if(dr == DEAL_REASON_EXPERT) reason = "EA_CLOSE";
               else                              reason = "OTHER";
               break;
            }
         }
      }
      else
      {
         Print(StringFormat("AdaptiveJournal: WARNING — deal history not found for #%I64u "
                            "| using live %s price fallback | row marked UNKNOWN_HIST",
                            g_aj_trades[i].ticket,
                            g_aj_trades[i].direction > 0 ? "BID" : "ASK"));
      }

      AJ_WriteRecord(g_aj_trades[i], exitTime, exitPrice, pl, reason);
      AJ_CacheRecord(g_aj_trades[i], pl);   // feed the live intelligence layer

      double slDist = MathAbs(g_aj_trades[i].entryPrice - g_aj_trades[i].slPrice);
      double maeR   = (slDist > 0) ? g_aj_trades[i].mae / slDist : 0;
      double mfeR   = (slDist > 0) ? g_aj_trades[i].mfe / slDist : 0;
      Print(StringFormat("AdaptiveJournal: #%I64u [%s] logged → %s | P&L=%.2f | "
                         "MAE=%.2fR MFE=%.2fR | bars=%d | cache=%d trades | written to %s",
                          g_aj_trades[i].ticket, g_aj_trades[i].symbol,
                          reason, pl, maeR, mfeR,
                          g_aj_trades[i].barsOpen, g_aj_cache.count, g_aj_file));

      g_aj_trades[i].active = false;
   }
}

//--------------------------------------------------------------------
//  External close notification — called by Live Trade Manager.
//  Debug hook; EA_CLOSE reason is set automatically via DEAL_REASON_EXPERT.
//--------------------------------------------------------------------
void AJ_NotifyClose(ulong ticket, string reason)
{
   int slot = AJ_FindSlot(ticket);
   if(slot < 0) return;
   if(g_debugMode)
      DBG(StringFormat("AJ: close notification for #%I64u — %s", ticket, reason));
}

//====================================================================
//  STATS CACHE QUERY FUNCTIONS
//  All queries scan the ring buffer from newest to oldest.
//  Cold-start guard: call AJ_HasStats() before any query.
//====================================================================

//--------------------------------------------------------------------
//  Returns true when enough trades are cached for reliable stats
//--------------------------------------------------------------------
bool AJ_HasStats(int minCount = 5)
{
   return (g_aj_cache.count >= minCount);
}

//--------------------------------------------------------------------
//  Win rate over last N closed trades (1.0 = all won, 0.0 = all lost)
//--------------------------------------------------------------------
double AJ_GetWinRate(int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   if(n == 0) return 0.5;
   int wins = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(g_aj_cache.won[idx]) wins++;
   }
   return (double)wins / n;
}

//--------------------------------------------------------------------
//  Average MAE_R of winning trades — how much noise winners endure.
//  Used to calibrate the SL distance (avoid premature stops).
//--------------------------------------------------------------------
double AJ_GetWinnerAvgMAE_R(int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   double sum = 0; int cnt = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(g_aj_cache.won[idx]) { sum += g_aj_cache.maeR[idx]; cnt++; }
   }
   return (cnt > 0) ? sum / cnt : 0.5;   // default 0.5R if no data
}

//--------------------------------------------------------------------
//  Average MFE_R of winning trades — how far winners actually run.
//  Used to calibrate TP placement.
//--------------------------------------------------------------------
double AJ_GetWinnerAvgMFE_R(int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   double sum = 0; int cnt = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(g_aj_cache.won[idx]) { sum += g_aj_cache.mfeR[idx]; cnt++; }
   }
   return (cnt > 0) ? sum / cnt : 1.5;   // default 1.5R if no data
}

//--------------------------------------------------------------------
//  Count of losing trades in the last N closed — minimum sample check
//  for AJ_ShouldExitEarly before computing averages.
//--------------------------------------------------------------------
int AJ_GetLoserCount(int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   int cnt = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(!g_aj_cache.won[idx]) cnt++;
   }
   return cnt;
}

//--------------------------------------------------------------------
//  Average MFE_R of losing trades — how far losers move before failing.
//  Used by LTM to identify the harvest opportunity zone.
//--------------------------------------------------------------------
double AJ_GetLoserAvgMFE_R(int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   double sum = 0; int cnt = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(!g_aj_cache.won[idx]) { sum += g_aj_cache.mfeR[idx]; cnt++; }
   }
   return (cnt > 0) ? sum / cnt : 0.0;
}

//--------------------------------------------------------------------
//  Average barsOpen of losing trades — how long losers stay alive.
//  Used by LTM to match the temporal profile of a loser.
//--------------------------------------------------------------------
double AJ_GetLoserAvgBars(int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   double sum = 0; int cnt = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(!g_aj_cache.won[idx]) { sum += g_aj_cache.barsOpen[idx]; cnt++; }
   }
   return (cnt > 0) ? sum / cnt : 0.0;
}

//--------------------------------------------------------------------
//  SL distance multiplier derived from average winner MAE_R.
//
//  Logic: winning trades reveal how much adverse noise a trade must
//  survive before the market moves in our direction.
//    avgMAE_R_winners = 0.5 → baseline, mult = 1.0 (no change)
//    avgMAE_R_winners = 0.7 → mult = 1.2  (widen SL 20% to accommodate)
//    avgMAE_R_winners = 0.3 → mult = 0.8  (tighten SL, market is clean)
//  Clamped to [0.80, 1.50].
//--------------------------------------------------------------------
double AJ_GetSuggestedSLMult(int lookback = AJ_CACHE_SIZE)
{
   double avgMAE = AJ_GetWinnerAvgMAE_R(lookback);
   double mult   = 1.0 + (avgMAE - 0.50);   // 0.5R is the baseline noise floor
   return MathMax(0.80, MathMin(1.50, mult));
}

//--------------------------------------------------------------------
//  TP1 distance multiplier derived from average winner MFE_R.
//
//  Logic: winners tell us how far the market actually moves in our
//  direction. If they consistently reach 1.8R, TP can go wider.
//  If they only reach 0.8R before stalling, harvest should come earlier.
//  Baseline TP1 = 1.5R (InpTP1ATRMult default).
//  Clamped to [0.70, 1.30].
//--------------------------------------------------------------------
double AJ_GetSuggestedTPMult(int lookback = AJ_CACHE_SIZE)
{
   double avgMFE = AJ_GetWinnerAvgMFE_R(lookback);
   if(avgMFE <= 0) return 1.0;
   double mult = avgMFE / 1.5;   // normalize against 1.5R baseline
   return MathMax(0.70, MathMin(1.30, mult));
}

//--------------------------------------------------------------------
//  Per-hour SL multiplier — noisier hours need wider stops.
//
//  Compares average winner MAE_R at the requested GMT hour against
//  the overall average. Requires at least 3 trades in that hour;
//  returns 1.0 (no adjustment) if the sample is too thin.
//  Clamped to [0.85, 1.40].
//--------------------------------------------------------------------
double AJ_GetHourSLMult(int gmtHour, int lookback = AJ_CACHE_SIZE)
{
   int n = MathMin(g_aj_cache.count, MathMin(lookback, AJ_CACHE_SIZE));
   double allSum = 0, hourSum = 0;
   int    allCnt = 0, hourCnt = 0;

   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(!g_aj_cache.won[idx]) continue;   // winners only — we want the survivable noise
      allSum += g_aj_cache.maeR[idx];
      allCnt++;
      if(g_aj_cache.hourGMT[idx] == gmtHour)
      {
         hourSum += g_aj_cache.maeR[idx];
         hourCnt++;
      }
   }

   if(allCnt == 0 || hourCnt < 3) return 1.0;   // not enough data for this hour

   double avgAll  = allSum  / allCnt;
   double avgHour = hourSum / hourCnt;
   if(avgAll <= 0) return 1.0;

   double mult = avgHour / avgAll;   // >1.0 = noisier than average → widen SL
   return MathMax(0.85, MathMin(1.40, mult));
}

//--------------------------------------------------------------------
//  Dynamic minimum confluence — rises when win rate drops.
//
//  The EA raises the entry bar when its own recent results show
//  it is trading in poor conditions.
//    winRate >= 0.50 → baseMin            (performance acceptable)
//    winRate >= 0.40 → baseMin + 1        (underperforming — stricter)
//    winRate <  0.40 → baseMin + 2        (strongly underperforming)
//--------------------------------------------------------------------
int AJ_GetDynamicMinConfluence(int baseMin, int lookback = AJ_CACHE_SIZE)
{
   if(!AJ_HasStats(5)) return baseMin;
   double wr = AJ_GetWinRate(lookback);
   if(wr < 0.40) return baseMin + 2;
   if(wr < 0.50) return baseMin + 1;
   return baseMin;
}

//--------------------------------------------------------------------
//  Dynamic spread limit — tightens when win rate is poor.
//
//  When performance is degrading, only allow entries in the cleanest
//  spread conditions to eliminate marginal setups.
//    winRate >= 0.50 → baseLimit          (no tightening)
//    winRate >= 0.40 → baseLimit × 0.90   (10% tighter)
//    winRate <  0.40 → baseLimit × 0.75   (25% tighter)
//--------------------------------------------------------------------
double AJ_GetDynamicSpreadLimit(double baseLimit, int lookback = AJ_CACHE_SIZE)
{
   if(!AJ_HasStats(5)) return baseLimit;
   double wr = AJ_GetWinRate(lookback);
   if(wr < 0.40) return baseLimit * 0.75;
   if(wr < 0.50) return baseLimit * 0.90;
   return baseLimit;
}

//--------------------------------------------------------------------
//  Count of consecutive ReversalWouldWin flags at the end of the cache.
//  3+ consecutive = possible regime shift advisory.
//--------------------------------------------------------------------
int AJ_GetReversalStreak()
{
   int n = MathMin(g_aj_cache.count, AJ_CACHE_SIZE);
   int streak = 0;
   for(int k = 1; k <= n; k++)
   {
      int idx = (g_aj_cache.head - k + AJ_CACHE_SIZE) % AJ_CACHE_SIZE;
      if(g_aj_cache.reversalWouldWin[idx]) streak++;
      else break;
   }
   return streak;
}

//--------------------------------------------------------------------
//  LTM pattern exit — returns true when the live trade matches the
//  profile of a typical losing trade based on journal history.
//
//  Fires when ALL of the following are true:
//    • Current MFE_R is within the loser MFE zone (±30% of avg)
//    • Trade has been open at least 70% as long as the avg loser
//    • Trade is in some profit (curMFER > 0.20) — never close a loser
//    • At least 3 losing trades are in the cache for the comparison
//
//  Uses AJ_GetLoserCount / AJ_GetLoserAvgMFE_R / AJ_GetLoserAvgBars
//  so the computation lives in one place and can be read externally.
//--------------------------------------------------------------------
bool AJ_ShouldExitEarly(double curMFER, int barsInTrade, int lookback = AJ_CACHE_SIZE)
{
   if(AJ_GetLoserCount(lookback) < 3) return false;   // not enough losing trade history

   double avgLoserMFE  = AJ_GetLoserAvgMFE_R(lookback);
   double avgLoserBars = AJ_GetLoserAvgBars(lookback);

   bool inLoserMFEZone = (curMFER >= avgLoserMFE * 0.70 &&
                          curMFER <= avgLoserMFE * 1.30);
   bool openLongEnough = (barsInTrade >= (int)(avgLoserBars * 0.70));
   bool hasProfit      = (curMFER > 0.20);   // only exit while in profit

   return (inLoserMFEZone && openLongEnough && hasProfit);
}

#endif // ADAPTIVEJOURNAL_MQH
