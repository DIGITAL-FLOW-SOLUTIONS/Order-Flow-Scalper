//+------------------------------------------------------------------+
//|  ScalperEA.mq5  —  Order Flow Scalper EA for MetaTrader 5       |
//|  Pairs: GBPUSD · EURUSD · USDJPY · USDCHF · XAUUSD             |
//|                                                                  |
//|  Strategy layers:                                                |
//|    1. Order Flow  (delta, CVD, absorption, initiative, exhaust)  |
//|    2. Session Volume Profile  (VAH, VAL, POC, LVNs)             |
//|    3. Opening Range Breakout  (ORB + volume confirmation)        |
//|    4. Risk Management  (ATR sizing, BE, trail, partial close)    |
//|                                                                  |
//|  INSTALLATION:                                                   |
//|    • Copy ScalperEA.mq5  → <MT5>/MQL5/Experts/                  |
//|    • Copy Include/ScalperEA/ → <MT5>/MQL5/Include/ScalperEA/    |
//|    • Compile in MetaEditor (F7)                                  |
//|    • Attach to a 5-minute chart of any supported pair            |
//|    • Allow automated trading and live ticks                      |
//+------------------------------------------------------------------+
#property copyright   "ScalperEA"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include "Include/ScalperEA/OrderFlow.mqh"
#include "Include/ScalperEA/VolumeProfile.mqh"
#include "Include/ScalperEA/ORB.mqh"
#include "Include/ScalperEA/RiskManager.mqh"
#include "Include/ScalperEA/TradeManager.mqh"
#include "Include/ScalperEA/AdaptiveJournal.mqh"
#include "Include/ScalperEA/Guardian.mqh"
#include "Include/ScalperEA/LiveTradeManager.mqh"

//====================================================================
//  INPUT PARAMETERS
//====================================================================

// --- General ---
input group "=== General ==="
input ulong    InpMagic           = 20240101;   // Magic number
input string   InpComment         = "ScalperEA";// Order comment
input bool     InpDebug           = false;       // Enable verbose debug logging

// --- Trading Session (GMT) ---
input group "=== Session (GMT Hours) ==="
input int      InpNYOpenHour      = 13;          // NY Session open hour (GMT) — 13 = 9 AM EST
input int      InpNYCloseHour     = 21;          // NY Session close hour (GMT) — 21 = 5 PM EST
input int      InpLondonOpenHour  =  8;          // London open hour (GMT)
input int      InpORBMinutes      = 30;          // Opening Range duration (minutes)
input bool     InpTradeNYOnly     = true;        // Trade NY session only

// --- Risk Management ---
input group "=== Risk Management ==="
input double   InpRiskPct         = 0.01;        // Risk per trade (0.01 = 1%)
input double   InpMaxDailyDD      = 0.03;        // Max daily drawdown (0.03 = 3%)
input double   InpDailyProfitStop = 0.04;        // Daily profit stop (0.04 = 4%)
input int      InpMaxPositions    = 2;           // Max concurrent positions (this symbol)
input double   InpSLATRMult       = 1.0;         // Stop loss in ATR multiples
input double   InpBEATRMult       = 0.8;         // Break-even trigger (ATR multiples profit)
input double   InpTrailATRMult    = 1.2;         // Trailing stop distance (ATR multiples)
input double   InpTP1ATRMult      = 1.5;         // TP1 trigger for partial close (ATR mult)

// --- Entry Filters ---
input group "=== Entry Filters ==="
input int      InpOFTF_Minutes    = 5;           // Order flow timeframe (minutes: 1,3,5,15)
input int      InpVPTF_Minutes    = 15;          // Volume profile build timeframe
input int      InpATRPeriod       = 14;          // ATR period
input double   InpSpreadMaxPips   = 3.0;         // Max allowed spread (pips)
input int      InpMinConfluence   = 2;           // Minimum signal confluence to trade
input bool     InpAllowLong       = true;        // Allow long trades
input bool     InpAllowShort      = true;        // Allow short trades
input bool     InpORBEnabled      = true;        // Enable ORB strategy layer
input bool     InpVPEnabled       = true;        // Enable Volume Profile layer
input bool     InpCooldownBars    = true;        // Enforce cooldown after entry
input int      InpCooldownBarsCnt = 3;           // Cooldown bars after entry

// --- Spread Filter per Pair (pips) ---
input group "=== Pair-Specific Spread Limits (pips) ==="
input double   InpSpreadXAUUSD    = 8.0;         // XAUUSD max spread override
input double   InpSpreadUSDJPY    = 2.0;         // USDJPY max spread override

// === REVERSER ===
// Flips the trade direction while preserving identical SL/TP distances (same R:R).
// Manual override (InpReverser=true) always reverses.
// Auto-reverse lets Guardian decide based on live phantom trade results.
input group "=== REVERSER ==="
input bool     InpReverser        = false;        // Always reverse signals (manual)
input bool     InpAutoReverse     = true;         // Auto-reverse when Guardian recommends it

// === Adaptive Journal ===
// Records every trade to CSV with full signal conditions, MAE, MFE.
input group "=== Adaptive Journal ==="
input bool     InpAdaptiveEnabled = true;         // Enable trade journal (CSV)
input string   InpJournalFile     = "ScalperEA_Journal.csv"; // Journal filename

// === Guardian — Phantom Trade Layer ===
// Spawns imaginary NORMAL + REVERSED trade pairs on each signal.
// Monitors which side hits TP vs SL to determine real-time edge.
// Gates real trading when market shows no edge; advises direction.
input group "=== Guardian ==="
input bool     InpGuardianEnabled = true;         // Enable Guardian phantom system
input int      InpGRD_Window      = 20;           // Rolling window (phantom pairs)
input int      InpGRD_MinSample   = 5;            // Min pairs before gating real trades
input double   InpGRD_EdgeThresh  = 0.10;         // Win-rate gap to prefer one side (0.10=10%)
input string   InpGRD_File        = "ScalperEA_Guardian.csv"; // Guardian log filename

// === Live Trade Manager ===
// Re-evaluates open trades each bar using live signal stack.
// Closes intelligently when profit is at risk; never closes at a loss.
input group "=== Live Trade Manager ==="
input bool     InpLTMEnabled      = true;         // Enable intelligent exit management
input double   InpLTM_MFEThresh   = 0.50;        // MFE % of TP1 to activate monitoring (0.50=50%)
input double   InpLTM_RetracePct  = 0.80;        // Close if price retraces this fraction of MFE
input int      InpLTM_FlipConf    = 2;           // Min confluence required for signal-flip close

//====================================================================
//  GLOBAL STATE
//====================================================================

CTrade         g_trade;
CPositionInfo  g_pos;
VolumeProfile  g_vp;
OpeningRange   g_orb;

ENUM_TIMEFRAMES g_ofTF;            // Order-flow timeframe
ENUM_TIMEFRAMES g_vpTF;            // Volume profile timeframe

int            g_barCount    = 0;  // Track new bars
datetime       g_lastBarTime = 0;  // Last processed bar time
int            g_cooldown    = 0;  // Bars remaining in cooldown
bool           g_tp1Done[];        // Per-position TP1 partial close flag

bool           g_tradingAllowed = true;  // Daily risk gate
double         g_dayOpenBalance = 0;     // Balance recorded at session open (for intraday DD)
int            g_lastDayOfWeek  = -1;   // Track day boundary for DD reset

bool           g_debugMode = false;     // Runtime copy of InpDebug (used by .mqh modules)

//====================================================================
//  Debug helper — only prints when InpDebug is true.
//  Format: [DBG][HH:MM:SS]  — easy to filter in MT5 Journal tab.
//====================================================================
void DBG(string msg)
{
   if(!g_debugMode) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   Print(StringFormat("[DBG][%02d:%02d:%02d] %s", dt.hour, dt.min, dt.sec, msg));
}

//====================================================================
//  Returns current spread in pips for any pair/symbol
//====================================================================
double GetSpreadPips(string symbol)
{
   double spread = (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD)
                   * SymbolInfoDouble(symbol, SYMBOL_POINT);
   bool   oddDigits = (SymbolInfoInteger(symbol, SYMBOL_DIGITS) % 2 == 1);
   double pip = SymbolInfoDouble(symbol, SYMBOL_POINT) * (oddDigits ? 10.0 : 1.0);
   return (pip > 0) ? spread / pip : spread / 0.0001;
}

//====================================================================
//  HELPER: minutes → ENUM_TIMEFRAMES
//====================================================================
ENUM_TIMEFRAMES MinutesToTF(int mins)
{
   switch(mins)
   {
      case  1: return PERIOD_M1;
      case  2: return PERIOD_M2;
      case  3: return PERIOD_M3;
      case  4: return PERIOD_M4;
      case  5: return PERIOD_M5;
      case  6: return PERIOD_M6;
      case 10: return PERIOD_M10;
      case 12: return PERIOD_M12;
      case 15: return PERIOD_M15;
      case 20: return PERIOD_M20;
      case 30: return PERIOD_M30;
      case 60: return PERIOD_H1;
      default: return PERIOD_M5;
   }
}

//====================================================================
//  HELPER: Is current GMT hour within trading session?
//====================================================================
bool IsInSession()
{
   if(!InpTradeNYOnly) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpNYOpenHour && dt.hour < InpNYCloseHour);
}

//====================================================================
//  HELPER: Spread check (auto-adjusts threshold per pair)
//====================================================================
bool SpreadOK(string symbol)
{
   double spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD) *
                   SymbolInfoDouble(symbol, SYMBOL_POINT);
   double pip    = SymbolInfoDouble(symbol, SYMBOL_POINT) *
                   ((SymbolInfoInteger(symbol, SYMBOL_DIGITS) % 2 == 1) ? 10 : 1);

   double maxSpreadPips = InpSpreadMaxPips;

   // Override for pairs with naturally wider spreads
   string sym = symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") >= 0 || StringFind(sym, "GOLD") >= 0)
      maxSpreadPips = InpSpreadXAUUSD;
   else if(StringFind(sym, "USDJPY") >= 0)
      maxSpreadPips = InpSpreadUSDJPY;

   double spreadPips = (pip > 0) ? spread / pip : spread / 0.0001;
   return (spreadPips <= maxSpreadPips);
}

//====================================================================
//  HELPER: Is a new bar available?
//====================================================================
bool IsNewBar(string symbol, ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//====================================================================
//  Rebuild Volume Profile for current session
//====================================================================
void RebuildVolumeProfile(string symbol)
{
   if(!InpVPEnabled) return;

   // Find start of current NY session
   int sessionStartBar = FindSessionStartBar(symbol, g_vpTF, InpNYOpenHour);
   if(sessionStartBar < 0)
   {
      // Try London session as fallback
      sessionStartBar = FindSessionStartBar(symbol, g_vpTF, InpLondonOpenHour);
   }
   if(sessionStartBar < 0) return;

   BuildVolumeProfile(g_vp, symbol, g_vpTF, sessionStartBar, 0);
}

//====================================================================
//  OnInit
//====================================================================
int OnInit()
{
   g_debugMode = InpDebug;   // propagate to all .mqh modules (same compilation unit)

   g_ofTF = MinutesToTF(InpOFTF_Minutes);
   g_vpTF = MinutesToTF(InpVPTF_Minutes);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   ResetOpeningRange(g_orb);
   ArrayResize(g_tp1Done, InpMaxPositions);
   ArrayInitialize(g_tp1Done, false);

   g_lastBarTime    = 0;
   g_cooldown       = 0;
   g_tradingAllowed = true;

   // ---- Initialise advanced modules ----
   if(InpAdaptiveEnabled)
      AJ_Init(InpJournalFile);

   if(InpGuardianEnabled)
      GRD_Init(InpGRD_MinSample, InpGRD_EdgeThresh, InpGRD_File);

   if(InpLTMEnabled)
      LTM_Init(InpLTM_MFEThresh, InpLTM_RetracePct, InpLTM_FlipConf);

   Print("ScalperEA v2.00 initialised on ", Symbol(),
         " | OF TF: ", EnumToString(g_ofTF),
         " | VP TF: ", EnumToString(g_vpTF),
         " | Debug: ", g_debugMode ? "ON" : "OFF",
         " | Reverser: ", InpReverser ? "MANUAL" : (InpAutoReverse ? "AUTO" : "OFF"),
         " | Guardian: ", InpGuardianEnabled ? "ON" : "OFF",
         " | LTM: ", InpLTMEnabled ? "ON" : "OFF",
         " | Journal: ", InpAdaptiveEnabled ? "ON" : "OFF");
   return INIT_SUCCEEDED;
}

//====================================================================
//  OnDeinit
//====================================================================
void OnDeinit(const int reason)
{
   Print("ScalperEA deinitialised. Reason: ", reason);
}

//====================================================================
//  OnTick  — main execution loop
//====================================================================
void OnTick()
{
   string symbol = Symbol();

   // ---- Guardian: 24/7 tick-level phantom monitoring (runs before bar gate) ----
   if(InpGuardianEnabled)
      GRD_UpdateOnTick(symbol);

   // Only process full logic on a new bar (bar-close confirmed signals)
   if(!IsNewBar(symbol, g_ofTF)) return;

   // ---- Debug: new bar header ----
   if(g_debugMode)
   {
      double bid        = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double spreadPips = GetSpreadPips(symbol);
      DBG(StringFormat("========== NEW BAR [%s] %s ==========",
                        symbol, TimeToString(iTime(symbol, g_ofTF, 0), TIME_DATE|TIME_MINUTES)));
      DBG(StringFormat("Bid=%.5f  Ask=%.5f  Spread=%.2f pips", bid, ask, spreadPips));
   }

   // ---- Adaptive Journal: update MAE/MFE for open trades + detect closures ----
   if(InpAdaptiveEnabled)
   {
      AJ_UpdateActive(symbol);
      AJ_CheckClosedTrades(symbol);
   }

   // ---- Daily risk checks ----
   if(g_debugMode)
   {
      double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
      double refBal = (g_dayOpenBalance > 0) ? g_dayOpenBalance : bal;
      double dd     = (refBal > 0) ? (refBal - eq) / refBal * 100.0 : 0;
      double prof   = (refBal > 0) ? (eq - refBal) / refBal * 100.0 : 0;
      DBG(StringFormat("Account: Bal=%.2f  Equity=%.2f  DayOpen=%.2f  DrawDn=%.2f%%/%.0f%%  Profit=%.2f%%/%.0f%%",
                        bal, eq, g_dayOpenBalance,
                        dd, InpMaxDailyDD * 100.0,
                        prof, InpDailyProfitStop * 100.0));
   }

   if(DailyDrawdownBreached(InpMaxDailyDD, g_dayOpenBalance))
   {
      DBG("DAILY DD LIMIT HIT → closing all positions, trading halted for today");
      if(g_tradingAllowed)
      {
         Print("ScalperEA: Daily drawdown limit reached — closing all & stopping.");
         CloseAllPositions(g_trade, symbol, InpMagic);
         g_tradingAllowed = false;
      }
      return;
   }
   if(DailyProfitTargetHit(InpDailyProfitStop, g_dayOpenBalance))
   {
      DBG("DAILY PROFIT TARGET HIT → closing all positions, locking gains");
      if(g_tradingAllowed)
      {
         Print("ScalperEA: Daily profit target hit — locking in gains.");
         CloseAllPositions(g_trade, symbol, InpMagic);
         g_tradingAllowed = false;
      }
      return;
   }
   g_tradingAllowed = true;

   // ---- Session filter ----
   {
      bool inSession = IsInSession();
      if(g_debugMode)
      {
         MqlDateTime dtNow; TimeToStruct(TimeCurrent(), dtNow);
         DBG(StringFormat("Session: %s (GMT hour=%d, window=%d-%d)",
                           inSession ? "IN SESSION ✓" : "OUT OF SESSION — skipping bar",
                           dtNow.hour, InpNYOpenHour, InpNYCloseHour));
      }
      if(!inSession) return;
   }

   // ---- Spread filter ----
   {
      bool spreadOk    = SpreadOK(symbol);
      double spreadNow = GetSpreadPips(symbol);
      if(g_debugMode)
         DBG(StringFormat("Spread: %.2f pips — %s (limit %.1f pips)",
                           spreadNow,
                           spreadOk ? "OK ✓" : "TOO WIDE → skipping bar",
                           InpSpreadMaxPips));
      if(!spreadOk) return;
   }

   // ---- Track day open balance for accurate intraday drawdown ----
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week != g_lastDayOfWeek)
      {
         g_dayOpenBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         g_lastDayOfWeek  = dt.day_of_week;
         g_tradingAllowed = true;
         ResetOpeningRange(g_orb);
         DBG(StringFormat("NEW TRADING DAY — DayOpenBalance=%.2f, ORB reset", g_dayOpenBalance));
      }
   }

   // ---- Update ORB ----
   if(InpORBEnabled)
   {
      UpdateOpeningRange(g_orb, symbol, g_ofTF, InpNYOpenHour, InpORBMinutes);
      if(g_orb.isFormed)
         CheckORBBreakout(g_orb, symbol, g_ofTF);
   }
   if(g_debugMode)
   {
      if(InpORBEnabled)
         DBG(StringFormat("ORB: %s | Hi=%.5f Lo=%.5f | BreakoutUp=%s BreakoutDown=%s",
                           g_orb.isFormed ? "FORMED ✓" : "NOT YET FORMED",
                           g_orb.high, g_orb.low,
                           g_orb.breakoutUp   ? "YES" : "no",
                           g_orb.breakoutDown ? "YES" : "no"));
      else
         DBG("ORB: DISABLED");
   }

   // ---- Rebuild volume profile ----
   RebuildVolumeProfile(symbol);
   if(g_debugMode)
   {
      if(InpVPEnabled && g_vp.isValid)
      {
         double pr    = iClose(symbol, g_ofTF, 1);
         string vaLoc = (pr >= g_vp.val && pr <= g_vp.vah) ? "INSIDE value area" :
                        (pr  > g_vp.vah)                   ? "ABOVE value area" :
                                                             "BELOW value area";
         DBG(StringFormat("VP: VALID | POC=%.5f  VAH=%.5f  VAL=%.5f | Price=%.5f — %s",
                           g_vp.poc, g_vp.vah, g_vp.val, pr, vaLoc));
      }
      else
         DBG(InpVPEnabled ? "VP: INVALID (not enough bars yet)" : "VP: DISABLED");
   }

   // ---- Manage existing positions ----
   int openPos = CountOpenPositions(symbol, InpMagic);
   DBG(StringFormat("Open positions: %d/%d | Cooldown: %d bars remaining",
                     openPos, InpMaxPositions, g_cooldown));

   if(openPos > 0)
   {
      if(ArraySize(g_tp1Done) < openPos)
         ArrayResize(g_tp1Done, openPos + 2);

      DBG("--- Managing open positions (BE / trail / partial close) ---");
      ManagePositions(g_trade, g_pos, symbol, InpMagic, g_ofTF,
                      InpBEATRMult, InpTrailATRMult, InpTP1ATRMult, g_tp1Done);

      // Live Trade Manager: intelligent exit — runs alongside BE/trail
      if(InpLTMEnabled)
      {
         LTM_SyncClosed(symbol);
         LTM_ManagePositions(symbol, g_ofTF, g_vp, g_trade);
      }
   }

   // ---- Cooldown check ----
   if(InpCooldownBars && g_cooldown > 0)
   {
      DBG(StringFormat("Cooldown active — %d bars remaining → skipping entry", g_cooldown));
      g_cooldown--;
      return;
   }

   // ---- Entry logic ----
   if(openPos >= InpMaxPositions)
   {
      DBG(StringFormat("Max positions (%d) already open → no new entry", InpMaxPositions));
      return;
   }

   // ---- Guardian: gate trading if phantom data shows no edge ----
   if(InpGuardianEnabled && !GRD_CanTrade())
   {
      Print(StringFormat("Guardian: trading PAUSED | NormWR=%.0f%% RevWR=%.0f%% [%d samples] — waiting for edge",
                          GRD_NormalWinRate() * 100, GRD_RevWinRate() * 100, GRD_SampleCount()));
      return;
   }
   if(InpGuardianEnabled && g_debugMode)
      DBG(StringFormat("Guardian: NormWR=%.0f%% RevWR=%.0f%% [%d samples] | AutoRev=%s",
                        GRD_NormalWinRate() * 100, GRD_RevWinRate() * 100, GRD_SampleCount(),
                        GRD_PreferReversed() ? "YES" : "NO"));

   // ---- Evaluate all strategy layers ----
   DBG("--- EvaluateEntry ---");
   EntrySignal sig = EvaluateEntry(symbol, g_ofTF, g_vp, g_orb,
                                   InpRiskPct, InpSLATRMult);

   // Apply direction filters
   if(sig.direction > 0 && !InpAllowLong)  { DBG("Long blocked by InpAllowLong=false");  sig.direction = 0; }
   if(sig.direction < 0 && !InpAllowShort) { DBG("Short blocked by InpAllowShort=false"); sig.direction = 0; }

   // Confluence gate
   if(sig.direction != 0 && sig.confluence < InpMinConfluence)
   {
      DBG(StringFormat("Confluence %d < minimum %d → no trade", sig.confluence, InpMinConfluence));
      sig.direction = 0;
   }

   if(sig.direction == 0)
   {
      DBG(StringFormat("No valid signal | [%s]", sig.reason != "" ? sig.reason : "none"));
      return;
   }

   // ORB: only enter after ORB is formed (if ORB is enabled)
   if(InpORBEnabled && !g_orb.isFormed)
   {
      DBG("ORB not yet formed — waiting before entry");
      return;
   }

   // ---- REVERSER: flip signal while preserving identical R:R ratios ----
   // origDir is the natural signal direction — saved BEFORE any flip.
   // Guardian phantom spawning always uses origDir so its data is unbiased.
   int  origDir       = sig.direction;
   bool applyReverser = InpReverser ||
                        (InpAutoReverse && InpGuardianEnabled && GRD_PreferReversed());

   if(applyReverser)
   {
      int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double tp2Dist = MathAbs(sig.tp2 - sig.entryPrice); // preserve TP2 distance

      sig.direction *= -1;  // flip

      if(sig.direction > 0)   // flipped to LONG
      {
         sig.entryPrice = NormalizeDouble(SymbolInfoDouble(symbol, SYMBOL_ASK), digits);
         sig.stopLoss   = NormalizeDouble(sig.entryPrice - sig.slDist,  digits);
         sig.tp1        = NormalizeDouble(sig.entryPrice + sig.tp1Dist, digits);
         sig.tp2        = NormalizeDouble(sig.entryPrice + tp2Dist,     digits);
      }
      else                    // flipped to SHORT
      {
         sig.entryPrice = NormalizeDouble(SymbolInfoDouble(symbol, SYMBOL_BID), digits);
         sig.stopLoss   = NormalizeDouble(sig.entryPrice + sig.slDist,  digits);
         sig.tp1        = NormalizeDouble(sig.entryPrice - sig.tp1Dist, digits);
         sig.tp2        = NormalizeDouble(sig.entryPrice - tp2Dist,     digits);
      }
      sig.reason += "REVERSED ";
      Print(StringFormat("REVERSER: %s → %s | SL_dist=%.5f TP1_dist=%.5f [%s]",
                          origDir > 0 ? "LONG" : "SHORT",
                          sig.direction > 0 ? "LONG" : "SHORT",
                          sig.slDist, sig.tp1Dist,
                          InpReverser ? "manual" : "Guardian-auto"));
   }

   // ---- Signal confirmed — log and place trade ----
   string dirStr = (sig.direction > 0) ? "LONG" : "SHORT";
   Print(StringFormat("ScalperEA SIGNAL | %s %s | Conf=%d | Entry=%.5f SL=%.5f TP1=%.5f TP2=%.5f | [%s]",
                       symbol, dirStr, sig.confluence,
                       sig.entryPrice, sig.stopLoss, sig.tp1, sig.tp2, sig.reason));

   ulong deal = PlaceTrade(g_trade, sig, symbol, InpRiskPct, InpMagic, InpComment);

   if(deal > 0)
   {
      Print(StringFormat("ScalperEA: Trade placed. Deal #%I64u | %s %s", deal, symbol, dirStr));
      g_cooldown = InpCooldownBarsCnt;
      ArrayInitialize(g_tp1Done, false);
      DBG(StringFormat("Cooldown set to %d bars after entry", InpCooldownBarsCnt));

      // Find the position ticket for the newly placed trade
      ulong posTicket = 0;
      for(int pi = PositionsTotal() - 1; pi >= 0; pi--)
      {
         if(PositionGetSymbol(pi) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         {
            posTicket = PositionGetTicket(pi);
            break;
         }
      }

      if(posTicket > 0)
      {
         // Spawn Guardian phantom pair using ORIGINAL pre-reversal direction
         // so phantom statistics remain unbiased regardless of REVERSER state
         if(InpGuardianEnabled)
            GRD_SpawnPhantoms(symbol, origDir, sig.entryPrice, sig.slDist, sig.tp1Dist);

         // Register with Adaptive Journal
         if(InpAdaptiveEnabled)
         {
            AJ_Snapshot snap;
            snap.ofScore    = sig.ofScore;
            snap.vpBias     = sig.vpBias;
            snap.orbSig     = sig.orbSig;
            snap.absorption = sig.absorption;
            snap.exhaustion = sig.exhaustion;
            snap.deltaDiv   = sig.deltaDiv;
            snap.confluence = sig.confluence;
            snap.atr        = sig.atr;
            snap.spreadPips = GetSpreadPips(symbol);
            MqlDateTime dtSnap;
            TimeToStruct(TimeCurrent(), dtSnap);
            snap.hourGMT = dtSnap.hour;
            AJ_RegisterTrade(posTicket, symbol, sig.direction, applyReverser,
                             sig.entryPrice, sig.stopLoss, sig.tp1, sig.tp2, snap);
         }

         // Register with Live Trade Manager
         if(InpLTMEnabled)
            LTM_RegisterTrade(posTicket, symbol, sig.direction,
                              sig.entryPrice, sig.stopLoss, sig.tp1);
      }
      else
         DBG("WARNING: could not find position ticket after placement — skipping module registration");
   }
   else
   {
      DBG(StringFormat("Trade placement FAILED — retcode %d: %s",
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   }
}

//====================================================================
//  OnChartEvent — handle manual interaction (optional)
//====================================================================
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   // Reserved for future dashboard or button interaction
}
