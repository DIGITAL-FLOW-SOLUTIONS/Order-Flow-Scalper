//+------------------------------------------------------------------+
//|  LiveTradeManager.mqh  —  Intelligent Position Exit             |
//|  Monitors open trades against live market conditions.           |
//|  Uses signal re-evaluation to decide when to take profit early  |
//|  vs when to hold. Never closes at a loss — SL handles that.    |
//|                                                                  |
//|  Rule 1: MFE retraced → take remaining profit before giving    |
//|           it all back.                                          |
//|  Rule 2: Signal flips against trade → exit while in profit.    |
//|  Rule 3: AJ pattern — trade matches loser profile from journal  |
//|           stats → exit at small gain before familiar loss.      |
//|                                                                  |
//|  STREAK MODE (Feature 1):                                       |
//|  When a pair produces consecutive winning trades, the position  |
//|  cap is raised to InpLTM_StreakMaxPos for 1 hour. Deactivates  |
//|  immediately on any loss, or after the 1-hour window expires.  |
//|                                                                  |
//|  LOSS SUSPENSION (Feature 2):                                   |
//|  Escalating cooldown after consecutive losses on a pair:        |
//|    1st loss → 30 min suspension                                 |
//|    2nd loss → 60 min suspension                                 |
//|    3rd loss → suspended for the rest of the trading day         |
//|  Resets at midnight UTC each day.                               |
//+------------------------------------------------------------------+
#ifndef LIVETRADEMANAGER_MQH
#define LIVETRADEMANAGER_MQH

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

#define LTM_MAX_TRADES   20    // Max concurrent managed trades

//--------------------------------------------------------------------
//  Per-trade live state
//--------------------------------------------------------------------
struct LTM_TradeState
{
   ulong    ticket;
   string   symbol;
   int      direction;         // +1=LONG  -1=SHORT
   double   entryPrice;
   double   slPrice;
   double   tp1Price;          // TP1 used as reference for MFE threshold
   double   mfe;               // Max Favorable Excursion (price terms, always >=0)
   double   mae;               // Max Adverse Excursion  (price terms, always >=0)
   double   tp1Dist;           // |tp1Price - entryPrice| (absolute, always positive)
   int      barsOpen;          // bars this trade has been open (incremented each manage call)
   bool     monitoringActive;  // MFE threshold hit — enhanced monitoring on
   bool     active;
};

//--------------------------------------------------------------------
//  Per-symbol streak mode state  (Feature 1)
//--------------------------------------------------------------------
struct LTM_StreakState
{
   string   symbol;
   int      wins;              // consecutive winning closed trades on this symbol
   bool     active;            // streak mode currently on
   datetime startTime;         // UTC time streak mode was activated
   bool     used;              // slot is in use
};

//--------------------------------------------------------------------
//  Per-symbol loss suspension state  (Feature 2)
//--------------------------------------------------------------------
struct LTM_SuspendState
{
   string   symbol;
   int      lossCount;         // consecutive losses today (resets at midnight)
   datetime resumeTime;        // UTC time trading resumes (0 = not suspended)
   bool     dayBanned;         // banned for the rest of today
   int      lastGMTDay;        // day of last reset
   bool     used;
};

#define LTM_MAX_SYMBOLS  10    // max symbols tracked simultaneously

LTM_TradeState  g_ltm_trades[LTM_MAX_TRADES];
LTM_StreakState g_ltm_streak[LTM_MAX_SYMBOLS];
LTM_SuspendState g_ltm_suspend[LTM_MAX_SYMBOLS];

bool           g_ltm_ready       = false;
double         g_ltm_mfeThresh   = 0.50;
double         g_ltm_retracePct  = 0.80;
int            g_ltm_flipConf    = 2;
int            g_ltm_streakMin   = 2;    // wins needed to activate streak mode
int            g_ltm_streakMax   = 5;    // max positions while in streak mode
int            g_ltm_streakCap   = 10;   // absolute upper cap (user input)
int            g_ltm_streakMins  = 60;   // streak window duration (minutes)

//--------------------------------------------------------------------
//  Initialise — call in OnInit()
//--------------------------------------------------------------------
void LTM_Init(double mfeThreshold  = 0.50,
              double retracePct    = 0.80,
              int    flipConf      = 2,
              int    streakMin     = 2,
              int    streakMaxPos  = 5,
              int    streakCapPos  = 10,
              int    streakMins    = 60)
{
   g_ltm_mfeThresh  = mfeThreshold;
   g_ltm_retracePct = retracePct;
   g_ltm_flipConf   = flipConf;
   g_ltm_streakMin  = streakMin;
   g_ltm_streakMax  = MathMin(streakMaxPos, streakCapPos);
   g_ltm_streakCap  = streakCapPos;
   g_ltm_streakMins = streakMins;

   for(int i = 0; i < LTM_MAX_TRADES;   i++) g_ltm_trades[i].active  = false;
   for(int i = 0; i < LTM_MAX_SYMBOLS;  i++) { g_ltm_streak[i].used  = false; g_ltm_suspend[i].used = false; }

   g_ltm_ready = true;
   Print(StringFormat("LiveTradeManager: ready | MFEthresh=%.0f%% RetracePct=%.0f%% FlipConf=%d "
                      "| StreakMode: min=%d wins, max=%d pos, window=%d min "
                      "| LossSuspend: 1L=30m 2L=60m 3L=dayban",
                      mfeThreshold * 100, retracePct * 100, flipConf,
                      streakMin, streakMaxPos, streakMins));
}

//--------------------------------------------------------------------
//  Internal: find or create a streak slot for a symbol
//--------------------------------------------------------------------
int LTM_StreakSlot(string symbol)
{
   for(int i = 0; i < LTM_MAX_SYMBOLS; i++)
      if(g_ltm_streak[i].used && g_ltm_streak[i].symbol == symbol) return i;
   for(int i = 0; i < LTM_MAX_SYMBOLS; i++)
      if(!g_ltm_streak[i].used)
      {
         g_ltm_streak[i].symbol    = symbol;
         g_ltm_streak[i].wins      = 0;
         g_ltm_streak[i].active    = false;
         g_ltm_streak[i].startTime = 0;
         g_ltm_streak[i].used      = true;
         return i;
      }
   return -1;
}

//--------------------------------------------------------------------
//  Internal: find or create a suspend slot for a symbol
//--------------------------------------------------------------------
int LTM_SuspendSlot(string symbol)
{
   for(int i = 0; i < LTM_MAX_SYMBOLS; i++)
      if(g_ltm_suspend[i].used && g_ltm_suspend[i].symbol == symbol) return i;
   for(int i = 0; i < LTM_MAX_SYMBOLS; i++)
      if(!g_ltm_suspend[i].used)
      {
         MqlDateTime gmt; TimeToStruct(TimeGMT(), gmt);
         g_ltm_suspend[i].symbol      = symbol;
         g_ltm_suspend[i].lossCount   = 0;
         g_ltm_suspend[i].resumeTime  = 0;
         g_ltm_suspend[i].dayBanned   = false;
         g_ltm_suspend[i].lastGMTDay  = gmt.day;
         g_ltm_suspend[i].used        = true;
         return i;
      }
   return -1;
}

//--------------------------------------------------------------------
//  Feature 2: Midnight reset for loss counters
//--------------------------------------------------------------------
void LTM_CheckDailyReset(string symbol)
{
   int idx = LTM_SuspendSlot(symbol);
   if(idx < 0) return;
   MqlDateTime gmt; TimeToStruct(TimeGMT(), gmt);
   if(gmt.day != g_ltm_suspend[idx].lastGMTDay)
   {
      bool wasBanned = g_ltm_suspend[idx].dayBanned;
      g_ltm_suspend[idx].lossCount  = 0;
      g_ltm_suspend[idx].resumeTime = 0;
      g_ltm_suspend[idx].dayBanned  = false;
      g_ltm_suspend[idx].lastGMTDay = gmt.day;
      if(wasBanned)
         Print(StringFormat("LossSuspend [%s]: new trading day — daily ban lifted, loss counter reset", symbol));
   }
}

//--------------------------------------------------------------------
//  Feature 2: Public query — is trading suspended for this symbol?
//  Call this from the main EA before placing any new entry.
//--------------------------------------------------------------------
bool LTM_IsSuspended(string symbol)
{
   LTM_CheckDailyReset(symbol);
   int idx = LTM_SuspendSlot(symbol);
   if(idx < 0) return false;
   if(g_ltm_suspend[idx].dayBanned) return true;
   if(g_ltm_suspend[idx].resumeTime > 0 && TimeGMT() < g_ltm_suspend[idx].resumeTime) return true;
   return false;
}

//--------------------------------------------------------------------
//  Feature 2: Called when a trade closes at a loss on this symbol.
//  Escalates suspension: 1st=30m, 2nd=60m, 3rd=day ban.
//--------------------------------------------------------------------
void LTM_RecordLoss(string symbol)
{
   LTM_CheckDailyReset(symbol);
   int idx = LTM_SuspendSlot(symbol);
   if(idx < 0) return;

   g_ltm_suspend[idx].lossCount++;
   int n = g_ltm_suspend[idx].lossCount;

   if(n == 1)
   {
      g_ltm_suspend[idx].resumeTime = TimeGMT() + 30 * 60;
      Print(StringFormat("LossSuspend [%s]: loss #1 — suspended 30 min, resumes %s UTC",
                          symbol, TimeToString(g_ltm_suspend[idx].resumeTime, TIME_DATE|TIME_MINUTES)));
   }
   else if(n == 2)
   {
      g_ltm_suspend[idx].resumeTime = TimeGMT() + 60 * 60;
      Print(StringFormat("LossSuspend [%s]: loss #2 — suspended 60 min, resumes %s UTC",
                          symbol, TimeToString(g_ltm_suspend[idx].resumeTime, TIME_DATE|TIME_MINUTES)));
   }
   else
   {
      g_ltm_suspend[idx].dayBanned  = true;
      g_ltm_suspend[idx].resumeTime = 0;
      Print(StringFormat("LossSuspend [%s]: loss #%d — SUSPENDED for rest of trading day (resets midnight UTC)",
                          symbol, n));
   }

   // A loss also cancels any active streak mode on this symbol
   int si = LTM_StreakSlot(symbol);
   if(si >= 0 && g_ltm_streak[si].active)
   {
      g_ltm_streak[si].active = false;
      g_ltm_streak[si].wins   = 0;
      Print(StringFormat("StreakMode [%s]: deactivated — loss recorded", symbol));
   }
}

//--------------------------------------------------------------------
//  Feature 1: Called when a trade closes at a profit on this symbol.
//  Increments win streak; activates streak mode when threshold met.
//--------------------------------------------------------------------
void LTM_RecordWin(string symbol)
{
   int idx = LTM_StreakSlot(symbol);
   if(idx < 0) return;

   g_ltm_streak[idx].wins++;
   int w = g_ltm_streak[idx].wins;

   if(!g_ltm_streak[idx].active && w >= g_ltm_streakMin)
   {
      g_ltm_streak[idx].active    = true;
      g_ltm_streak[idx].startTime = TimeGMT();
      Print(StringFormat("StreakMode [%s]: ACTIVATED after %d consecutive wins — "
                         "position cap raised to %d | window = %d min (expires %s UTC)",
                          symbol, w, g_ltm_streakMax, g_ltm_streakMins,
                          TimeToString(g_ltm_streak[idx].startTime + g_ltm_streakMins * 60,
                                       TIME_DATE|TIME_MINUTES)));
   }
   else if(g_ltm_streak[idx].active)
   {
      DBG(StringFormat("StreakMode [%s]: win #%d recorded — streak mode remains active", symbol, w));
   }

   // A win clears any timed suspension (dayban stays — that requires a new day)
   int si = LTM_SuspendSlot(symbol);
   if(si >= 0 && !g_ltm_suspend[si].dayBanned && g_ltm_suspend[si].resumeTime > 0)
   {
      g_ltm_suspend[si].resumeTime = 0;
      g_ltm_suspend[si].lossCount  = 0;
      DBG(StringFormat("LossSuspend [%s]: suspension cleared by winning trade", symbol));
   }
}

//--------------------------------------------------------------------
//  Feature 1: Public query — effective max positions for this symbol.
//  Returns the streak-mode cap if active and window not expired,
//  otherwise returns the normal InpMaxPositions cap passed in.
//--------------------------------------------------------------------
int LTM_GetMaxPositions(string symbol, int normalMax)
{
   int idx = LTM_StreakSlot(symbol);
   if(idx < 0 || !g_ltm_streak[idx].active) return normalMax;

   // Check if 1-hour window has expired
   if(TimeGMT() >= g_ltm_streak[idx].startTime + g_ltm_streakMins * 60)
   {
      g_ltm_streak[idx].active = false;
      g_ltm_streak[idx].wins   = 0;
      Print(StringFormat("StreakMode [%s]: 1-hour window expired — returning to normal position cap (%d)",
                          symbol, normalMax));
      return normalMax;
   }

   return g_ltm_streakMax;
}

//--------------------------------------------------------------------
//  Find free slot / find by ticket
//--------------------------------------------------------------------
int LTM_FreeSlot()
{
   for(int i = 0; i < LTM_MAX_TRADES; i++)
      if(!g_ltm_trades[i].active) return i;
   return -1;
}
int LTM_FindSlot(ulong ticket)
{
   for(int i = 0; i < LTM_MAX_TRADES; i++)
      if(g_ltm_trades[i].active && g_ltm_trades[i].ticket == ticket) return i;
   return -1;
}

//--------------------------------------------------------------------
//  Register a newly placed trade
//--------------------------------------------------------------------
void LTM_RegisterTrade(ulong ticket, string symbol, int direction,
                       double entryPrice, double slPrice, double tp1Price)
{
   if(!g_ltm_ready) return;
   int slot = LTM_FreeSlot();
   if(slot < 0)
   {
      Print("LiveTradeManager: tracking array full — cannot manage #", ticket);
      return;
   }
   g_ltm_trades[slot].ticket           = ticket;
   g_ltm_trades[slot].symbol           = symbol;
   g_ltm_trades[slot].direction        = direction;
   g_ltm_trades[slot].entryPrice       = entryPrice;
   g_ltm_trades[slot].slPrice          = slPrice;
   g_ltm_trades[slot].tp1Price         = tp1Price;
   g_ltm_trades[slot].tp1Dist          = MathAbs(tp1Price - entryPrice);
   g_ltm_trades[slot].mfe              = 0;
   g_ltm_trades[slot].mae              = 0;
   g_ltm_trades[slot].barsOpen         = 0;
   g_ltm_trades[slot].monitoringActive = false;
   g_ltm_trades[slot].active           = true;

   if(g_debugMode)
      DBG(StringFormat("LTM: registered #%I64u %s %s | TP1dist=%.5f",
                        ticket, symbol,
                        direction > 0 ? "LONG" : "SHORT", g_ltm_trades[slot].tp1Dist));
}

//--------------------------------------------------------------------
//  Remove a trade (called when detected as closed externally)
//--------------------------------------------------------------------
void LTM_RemoveTrade(ulong ticket)
{
   int slot = LTM_FindSlot(ticket);
   if(slot >= 0) g_ltm_trades[slot].active = false;
}

//--------------------------------------------------------------------
//  Sync: remove any trades no longer open and report win/loss result.
//  This is where Feature 1 and Feature 2 counters get updated.
//--------------------------------------------------------------------
void LTM_SyncClosed(string symbol)
{
   if(!g_ltm_ready) return;
   for(int i = 0; i < LTM_MAX_TRADES; i++)
   {
      if(!g_ltm_trades[i].active || g_ltm_trades[i].symbol != symbol) continue;
      if(!PositionSelectByTicket(g_ltm_trades[i].ticket))
      {
         // Position is gone — determine result from deal history
         double closedProfit = 0;
         if(HistorySelectByPosition(g_ltm_trades[i].ticket))
         {
            int deals = HistoryDealsTotal();
            for(int d = 0; d < deals; d++)
            {
               ulong dticket = HistoryDealGetTicket(d);
               if(HistoryDealGetInteger(dticket, DEAL_ENTRY) == DEAL_ENTRY_OUT ||
                  HistoryDealGetInteger(dticket, DEAL_ENTRY) == DEAL_ENTRY_INOUT)
                  closedProfit += HistoryDealGetDouble(dticket, DEAL_PROFIT)
                                + HistoryDealGetDouble(dticket, DEAL_SWAP)
                                + HistoryDealGetDouble(dticket, DEAL_COMMISSION);
            }
         }

         if(closedProfit >= 0)
            LTM_RecordWin(symbol);
         else
            LTM_RecordLoss(symbol);

         g_ltm_trades[i].active = false;
      }
   }
}

//--------------------------------------------------------------------
//  Re-evaluate the market signal for an open trade.
//  Returns +1 (bullish), -1 (bearish), 0 (neutral).
//--------------------------------------------------------------------
int LTM_ReEvaluate(string symbol, ENUM_TIMEFRAMES tf,
                   const VolumeProfile &vp, int &confluence)
{
   double atr   = CalcATR(symbol, tf);
   double price = iClose(symbol, tf, 1);

   int ofScore = GetOrderFlowScore(symbol, tf);
   int vpBias  = 0;
   if(vp.isValid)
   {
      if(price <= vp.val + atr * 0.3) vpBias++;
      if(price >= vp.vah - atr * 0.3) vpBias--;
      if(price > vp.vah + atr * 0.1)  vpBias++;
      if(price < vp.val - atr * 0.1)  vpBias--;
   }

   int longScore  = 0;
   int shortScore = 0;
   if(ofScore > 1)  longScore  += (ofScore > 2 ? 2 : 1);
   if(ofScore < -1) shortScore += (-ofScore > 2 ? 2 : 1);
   if(vpBias  > 0)  longScore++;
   if(vpBias  < 0)  shortScore++;
   int ddv = CalcDeltaDivergence(symbol, tf);
   if(ddv > 0) longScore++;
   if(ddv < 0) shortScore++;

   if(longScore > shortScore)  { confluence = longScore;  return  1; }
   if(shortScore > longScore)  { confluence = shortScore; return -1; }
   confluence = 0;
   return 0;
}

//--------------------------------------------------------------------
//  Main management loop — call each new bar.
//  Runs IN ADDITION to the basic BE/trail in ManagePositions.
//
//  Rule 1: MFE retraced most of the gain → take remaining profit.
//  Rule 2: Signal flipped with conviction → exit while in profit.
//  Rule 3: Trade matches journal loser profile → exit at small gain.
//          (Only active when InpAdaptiveEnabled && InpAJAdaptLTM
//           and AJ_HasStats(InpAJMinSamples) is true.)
//--------------------------------------------------------------------
void LTM_ManagePositions(string symbol, ENUM_TIMEFRAMES tf,
                         const VolumeProfile &vp, CTrade &trade)
{
   if(!g_ltm_ready) return;

   for(int i = 0; i < LTM_MAX_TRADES; i++)
   {
      if(!g_ltm_trades[i].active || g_ltm_trades[i].symbol != symbol) continue;

      if(!PositionSelectByTicket(g_ltm_trades[i].ticket))
      {
         g_ltm_trades[i].active = false;
         continue;
      }

      // Increment bar counter (LTM runs once per new bar)
      g_ltm_trades[i].barsOpen++;

      double curPrice  = (g_ltm_trades[i].direction > 0)
                         ? SymbolInfoDouble(symbol, SYMBOL_BID)
                         : SymbolInfoDouble(symbol, SYMBOL_ASK);
      double profit    = PositionGetDouble(POSITION_PROFIT);

      // ---- Update MFE / MAE ----
      double excursion = (g_ltm_trades[i].direction > 0)
                         ? curPrice - g_ltm_trades[i].entryPrice
                         : g_ltm_trades[i].entryPrice - curPrice;

      if( excursion > g_ltm_trades[i].mfe) g_ltm_trades[i].mfe =  excursion;
      if(-excursion > g_ltm_trades[i].mae) g_ltm_trades[i].mae = -excursion;

      // ---- Never close a losing trade (SL handles it) ----
      if(excursion < 0) continue;

      // ---- Activate enhanced monitoring once MFE threshold is reached ----
      if(!g_ltm_trades[i].monitoringActive && g_ltm_trades[i].tp1Dist > 0 &&
         g_ltm_trades[i].mfe >= g_ltm_trades[i].tp1Dist * g_ltm_mfeThresh)
      {
         g_ltm_trades[i].monitoringActive = true;
         Print(StringFormat("LiveTradeManager: #%I64u [%s] MFE reached %.0f%% of TP1 "
                            "— enhanced monitoring ON | bars=%d",
                             g_ltm_trades[i].ticket, g_ltm_trades[i].symbol,
                             g_ltm_trades[i].mfe / g_ltm_trades[i].tp1Dist * 100,
                             g_ltm_trades[i].barsOpen));
      }

      if(!g_ltm_trades[i].monitoringActive) continue;

      // ---- Rule 1: Price has retraced most of the MFE gain ----
      bool retracedMostOfGain = (g_ltm_trades[i].mfe > 0 && excursion >= 0 &&
                                  excursion < g_ltm_trades[i].mfe * (1.0 - g_ltm_retracePct));

      // ---- Rule 2: Signal has flipped against the trade ----
      int confluence = 0;
      int reEval     = LTM_ReEvaluate(symbol, tf, vp, confluence);
      bool signalFlipped = (reEval != 0 &&
                            reEval != g_ltm_trades[i].direction &&
                            confluence >= g_ltm_flipConf);

      // ---- Rule 3: Journal pattern — matches typical loser profile ----
      bool ajPatternExit = false;
      if(InpAdaptiveEnabled && InpAJAdaptLTM && AJ_HasStats(InpAJMinSamples))
      {
         double slDist  = MathAbs(g_ltm_trades[i].entryPrice - g_ltm_trades[i].slPrice);
         double curMFER = (slDist > 0 && excursion > 0) ? excursion / slDist : 0;
         ajPatternExit  = AJ_ShouldExitEarly(curMFER, g_ltm_trades[i].barsOpen, InpAJLookback);
         if(ajPatternExit && g_debugMode)
            DBG(StringFormat("LTM Rule3: #%I64u AJ pattern match | curMFE_R=%.2f bars=%d",
                              g_ltm_trades[i].ticket, curMFER, g_ltm_trades[i].barsOpen));
      }

      // ---- Decision ----
      string closeReason = "";
      bool   shouldClose = false;

      if(retracedMostOfGain && signalFlipped)
      {
         closeReason = "LTM_FLIP+RETRACE";
         shouldClose = true;
      }
      else if(retracedMostOfGain && !signalFlipped)
      {
         if(g_ltm_trades[i].mfe >= g_ltm_trades[i].tp1Dist * 0.80)
         {
            closeReason = "LTM_RETRACE_DEEP";
            shouldClose = true;
         }
         else if(g_debugMode)
            DBG(StringFormat("LTM: #%I64u retrace detected but signal neutral & MFE moderate — HOLDING",
                               g_ltm_trades[i].ticket));
      }
      else if(signalFlipped && !retracedMostOfGain)
      {
         if(excursion >= g_ltm_trades[i].tp1Dist * 0.50)
         {
            closeReason = "LTM_SIGNAL_FLIP";
            shouldClose = true;
         }
         else if(g_debugMode)
            DBG(StringFormat("LTM: #%I64u signal flipped but profit only %.0f%% of TP — holding for now",
                               g_ltm_trades[i].ticket,
                               excursion / (g_ltm_trades[i].tp1Dist > 0 ? g_ltm_trades[i].tp1Dist : 1) * 100));
      }
      else if(ajPatternExit && !retracedMostOfGain && !signalFlipped)
      {
         closeReason = "LTM_AJ_PATTERN";
         shouldClose = true;
      }

      // ---- Execute close ----
      if(shouldClose)
      {
         double slDistLog = MathAbs(g_ltm_trades[i].entryPrice - g_ltm_trades[i].slPrice);
         double mfeRLog   = (slDistLog > 0) ? g_ltm_trades[i].mfe / slDistLog : 0;

         if(g_debugMode)
            DBG(StringFormat("LTM: #%I64u CLOSING — reason=%s | profit=%.2f | "
                              "MFE=%.5f (%.2fR) | excursion=%.5f | bars=%d",
                              g_ltm_trades[i].ticket, closeReason, profit,
                              g_ltm_trades[i].mfe, mfeRLog, excursion,
                              g_ltm_trades[i].barsOpen));

         Print(StringFormat("LiveTradeManager: closing #%I64u [%s] | P&L=%.2f | "
                            "MFE=%.2fR | bars=%d | %s",
                             g_ltm_trades[i].ticket, symbol, profit,
                             mfeRLog, g_ltm_trades[i].barsOpen, closeReason));

         trade.PositionClose(g_ltm_trades[i].ticket);
         AJ_NotifyClose(g_ltm_trades[i].ticket, closeReason);
         g_ltm_trades[i].active = false;
      }
      else if(g_debugMode)
      {
         DBG(StringFormat("LTM: #%I64u MONITORED | MFE=%.5f (%.0f%% TP1) | "
                           "excursion=%.5f | signal=%+d conf=%d | bars=%d | HOLD",
                            g_ltm_trades[i].ticket,
                            g_ltm_trades[i].mfe,
                            g_ltm_trades[i].tp1Dist > 0
                               ? g_ltm_trades[i].mfe / g_ltm_trades[i].tp1Dist * 100 : 0,
                            excursion, reEval, confluence,
                            g_ltm_trades[i].barsOpen));
      }
   }
}

#endif // LIVETRADEMANAGER_MQH
