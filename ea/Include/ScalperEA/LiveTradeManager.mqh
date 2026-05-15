//+------------------------------------------------------------------+
//|  LiveTradeManager.mqh  —  Intelligent Position Exit             |
//|  Monitors open trades against live market conditions.           |
//|  Uses signal re-evaluation to decide when to take profit early  |
//|  vs when to hold. Never closes at a loss — SL handles that.    |
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
   int      direction;       // +1=LONG  -1=SHORT
   double   entryPrice;
   double   slPrice;
   double   tp1Price;        // TP1 used as reference for MFE threshold
   double   mfe;             // Max Favorable Excursion (price terms, always >=0)
   double   mae;             // Max Adverse Excursion  (price terms, always >=0)
   double   tp1Dist;         // tp1Price - entryPrice (absolute, always positive)
   bool     monitoringActive;  // MFE threshold has been hit — enhanced monitoring on
   bool     active;
};

LTM_TradeState g_ltm_trades[LTM_MAX_TRADES];
bool           g_ltm_ready       = false;
double         g_ltm_mfeThresh   = 0.50;   // MFE as fraction of TP1 dist to activate
double         g_ltm_retracePct  = 0.80;   // Close if MFE retraces this fraction
int            g_ltm_flipConf    = 2;      // Min confluence for signal-flip close

//--------------------------------------------------------------------
//  Initialise — call in OnInit()
//--------------------------------------------------------------------
void LTM_Init(double mfeThreshold = 0.50,
              double retracePct   = 0.80,
              int    flipConf     = 2)
{
   g_ltm_mfeThresh  = mfeThreshold;
   g_ltm_retracePct = retracePct;
   g_ltm_flipConf   = flipConf;

   for(int i = 0; i < LTM_MAX_TRADES; i++)
      g_ltm_trades[i].active = false;

   g_ltm_ready = true;
   Print(StringFormat("LiveTradeManager: ready | MFEthresh=%.0f%% RetracePct=%.0f%% FlipConf=%d",
                       mfeThreshold * 100, retracePct * 100, flipConf));
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
//  Register a newly placed trade with the Live Trade Manager
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
//  Sync: remove any trades that are no longer open (SL/TP/trail)
//--------------------------------------------------------------------
void LTM_SyncClosed(string symbol)
{
   if(!g_ltm_ready) return;
   for(int i = 0; i < LTM_MAX_TRADES; i++)
   {
      if(!g_ltm_trades[i].active || g_ltm_trades[i].symbol != symbol) continue;
      if(!PositionSelectByTicket(g_ltm_trades[i].ticket))
         g_ltm_trades[i].active = false;
   }
}

//--------------------------------------------------------------------
//  Re-evaluate the market signal for an open trade.
//  Returns +1 (bullish), -1 (bearish), 0 (neutral) with the
//  confluence count as an output parameter.
//  Uses OrderFlow score + VP bias — fastest live indicators.
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
      // Price below VAL → bullish pressure; above VAH → bearish
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

   // Delta divergence adds weight
   int ddv = CalcDeltaDivergence(symbol, tf);
   if(ddv > 0) longScore++;
   if(ddv < 0) shortScore++;

   if(longScore > shortScore)
   {
      confluence = longScore;
      return 1;
   }
   if(shortScore > longScore)
   {
      confluence = shortScore;
      return -1;
   }
   confluence = 0;
   return 0;
}

//--------------------------------------------------------------------
//  Main management loop — call each new bar for each open trade
//  This runs IN ADDITION to the basic BE/trail in ManagePositions.
//  It handles the intelligent exit decisions only.
//--------------------------------------------------------------------
void LTM_ManagePositions(string symbol, ENUM_TIMEFRAMES tf,
                         const VolumeProfile &vp, CTrade &trade)
{
   if(!g_ltm_ready) return;

   for(int i = 0; i < LTM_MAX_TRADES; i++)
   {
      if(!g_ltm_trades[i].active || g_ltm_trades[i].symbol != symbol) continue;

      // Check position still open
      if(!PositionSelectByTicket(g_ltm_trades[i].ticket))
      {
         g_ltm_trades[i].active = false;
         continue;
      }

      double curPrice = (g_ltm_trades[i].direction > 0)
                        ? SymbolInfoDouble(symbol, SYMBOL_BID)
                        : SymbolInfoDouble(symbol, SYMBOL_ASK);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit    = PositionGetDouble(POSITION_PROFIT);

      // ---- Update MFE / MAE ----
      double excursion = (g_ltm_trades[i].direction > 0)
                         ? curPrice - g_ltm_trades[i].entryPrice
                         : g_ltm_trades[i].entryPrice - curPrice;

      if(excursion > g_ltm_trades[i].mfe)   g_ltm_trades[i].mfe = excursion;
      if(-excursion > g_ltm_trades[i].mae)  g_ltm_trades[i].mae = -excursion;

      // ---- Never close a losing trade (SL handles it) ----
      if(excursion < 0) continue;

      // ---- Activate enhanced monitoring once MFE threshold is reached ----
      if(!g_ltm_trades[i].monitoringActive && g_ltm_trades[i].tp1Dist > 0 &&
         g_ltm_trades[i].mfe >= g_ltm_trades[i].tp1Dist * g_ltm_mfeThresh)
      {
         g_ltm_trades[i].monitoringActive = true;
         Print(StringFormat("LiveTradeManager: #%I64u [%s] MFE reached %.0f%% of TP1 — enhanced monitoring ON",
                             g_ltm_trades[i].ticket, g_ltm_trades[i].symbol,
                             g_ltm_trades[i].mfe / g_ltm_trades[i].tp1Dist * 100));
      }

      if(!g_ltm_trades[i].monitoringActive) continue;

      // ---- Rule 1: Price has retraced most of the MFE gain ----
      // If price was at MFE and has come back to < 20% of that gain,
      // take what's left rather than give it all back.
      bool retracedMostOfGain = (g_ltm_trades[i].mfe > 0 && excursion >= 0 &&
                                  excursion < g_ltm_trades[i].mfe * (1.0 - g_ltm_retracePct));

      // ---- Rule 2: Signal has flipped against the trade ----
      int confluence = 0;
      int reEval     = LTM_ReEvaluate(symbol, tf, vp, confluence);
      bool signalFlipped = (reEval != 0 &&
                            reEval != g_ltm_trades[i].direction &&
                            confluence >= g_ltm_flipConf);

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
         // Price retraced a lot but signal not yet flipped — borderline case.
         // Only close if MFE was very significant (>80% of TP1) meaning real
         // profit is at risk.
         if(g_ltm_trades[i].mfe >= g_ltm_trades[i].tp1Dist * 0.80)
         {
            closeReason = "LTM_RETRACE_DEEP";
            shouldClose = true;
         }
         else
         {
            if(g_debugMode)
               DBG(StringFormat("LTM: #%I64u retrace detected but signal neutral & MFE moderate — HOLDING",
                                  g_ltm_trades[i].ticket));
         }
      }
      else if(signalFlipped && !retracedMostOfGain)
      {
         // Signal flipped but price hasn't retraced much yet.
         // Only act if we're in decent profit (>50% to TP1).
         if(excursion >= g_ltm_trades[i].tp1Dist * 0.50)
         {
            closeReason = "LTM_SIGNAL_FLIP";
            shouldClose = true;
         }
         else
         {
            if(g_debugMode)
               DBG(StringFormat("LTM: #%I64u signal flipped but profit only %.0f%% of TP — holding for now",
                                  g_ltm_trades[i].ticket,
                                  excursion / (g_ltm_trades[i].tp1Dist > 0 ? g_ltm_trades[i].tp1Dist : 1) * 100));
         }
      }

      // ---- Execute close ----
      if(shouldClose)
      {
         if(g_debugMode)
            DBG(StringFormat("LTM: #%I64u CLOSING — reason=%s | profit=%.2f | MFE=%.5f excursion=%.5f",
                              g_ltm_trades[i].ticket, closeReason, profit, g_ltm_trades[i].mfe, excursion));

         Print(StringFormat("LiveTradeManager: closing #%I64u [%s] | P&L=%.2f | MFE_R=%.2fx | %s",
                             g_ltm_trades[i].ticket, symbol, profit,
                             (MathAbs(g_ltm_trades[i].entryPrice - g_ltm_trades[i].slPrice) > 0)
                                ? g_ltm_trades[i].mfe / MathAbs(g_ltm_trades[i].entryPrice - g_ltm_trades[i].slPrice) : 0,
                             closeReason));

         trade.PositionClose(g_ltm_trades[i].ticket);
         AJ_NotifyClose(g_ltm_trades[i].ticket, closeReason);
         g_ltm_trades[i].active = false;
      }
      else if(g_debugMode)
      {
         DBG(StringFormat("LTM: #%I64u %s | MFE=%.5f (%.0f%% TP1) | cur_excur=%.5f | signal=%+d conf=%d | HOLD",
                           g_ltm_trades[i].ticket,
                           g_ltm_trades[i].monitoringActive ? "MONITORED" : "watching",
                           g_ltm_trades[i].mfe,
                           g_ltm_trades[i].tp1Dist > 0 ? g_ltm_trades[i].mfe / g_ltm_trades[i].tp1Dist * 100 : 0,
                           excursion, reEval, confluence));
      }
   }
}

#endif // LIVETRADEMANAGER_MQH
