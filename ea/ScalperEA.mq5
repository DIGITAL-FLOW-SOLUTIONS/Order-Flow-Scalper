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

//====================================================================
//  INPUT PARAMETERS
//====================================================================

// --- General ---
input group "=== General ==="
input ulong    InpMagic           = 20240101;   // Magic number
input string   InpComment         = "ScalperEA";// Order comment

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
double         g_dayOpenBalance = 0;      // Balance recorded at session open (for intraday DD)
int            g_lastDayOfWeek  = -1;     // Track day boundary for DD reset

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

   Print("ScalperEA v1.00 initialised on ", Symbol(),
         " | OF TF: ", EnumToString(g_ofTF),
         " | VP TF: ", EnumToString(g_vpTF));
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

   // Only process logic on a new bar (bar-close confirmed signals)
   if(!IsNewBar(symbol, g_ofTF)) return;

   // ---- Daily risk checks ----
   if(DailyDrawdownBreached(InpMaxDailyDD, g_dayOpenBalance))
   {
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
   if(!IsInSession()) return;

   // ---- Spread filter ----
   if(!SpreadOK(symbol)) return;

   // ---- Track day open balance for accurate intraday drawdown ----
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week != g_lastDayOfWeek)
      {
         g_dayOpenBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         g_lastDayOfWeek  = dt.day_of_week;
         g_tradingAllowed = true;   // Reset daily gate each new day
         ResetOpeningRange(g_orb);  // New day — fresh ORB
      }
   }

   // ---- Update ORB ----
   if(InpORBEnabled)
   {
      UpdateOpeningRange(g_orb, symbol, g_ofTF, InpNYOpenHour, InpORBMinutes);
      // CRITICAL: check for breakout on every bar after ORB is formed
      if(g_orb.isFormed)
         CheckORBBreakout(g_orb, symbol, g_ofTF);
   }

   // ---- Rebuild volume profile (once per bar on VP timeframe) ----
   RebuildVolumeProfile(symbol);

   // ---- Manage existing positions ----
   int openPos = CountOpenPositions(symbol, InpMagic);
   if(openPos > 0)
   {
      // Ensure tp1Done array is large enough
      if(ArraySize(g_tp1Done) < openPos)
         ArrayResize(g_tp1Done, openPos + 2);

      ManagePositions(g_trade, g_pos, symbol, InpMagic, g_ofTF,
                      InpBEATRMult, InpTrailATRMult, InpTP1ATRMult, g_tp1Done);
   }

   // ---- Cooldown check ----
   if(InpCooldownBars && g_cooldown > 0)
   {
      g_cooldown--;
      return;
   }

   // ---- Entry logic ----
   if(openPos >= InpMaxPositions) return;

   // Evaluate all strategy layers
   EntrySignal sig = EvaluateEntry(symbol, g_ofTF, g_vp, g_orb,
                                   InpRiskPct, InpSLATRMult);

   // Apply direction filters
   if(sig.direction > 0 && !InpAllowLong)  sig.direction = 0;
   if(sig.direction < 0 && !InpAllowShort) sig.direction = 0;

   // Confluence gate
   if(sig.confluence < InpMinConfluence) sig.direction = 0;

   if(sig.direction == 0) return;

   // ORB: only enter after ORB is formed (if ORB is enabled)
   if(InpORBEnabled && !g_orb.isFormed) return;

   // Place trade
   Print("ScalperEA Signal | ", symbol,
         " Dir: ", sig.direction > 0 ? "LONG" : "SHORT",
         " Conf: ", sig.confluence,
         " SL: ", sig.stopLoss,
         " TP1: ", sig.tp1, " TP2: ", sig.tp2,
         " Reason: [", sig.reason, "]");

   ulong deal = PlaceTrade(g_trade, sig, symbol, InpRiskPct, InpMagic, InpComment);

   if(deal > 0)
   {
      Print("ScalperEA: Trade placed. Deal #", deal);

      // After entry: set the second TP as a separate pending limit? 
      // Instead we trail into TP2 — no second order needed.

      // Reset cooldown
      g_cooldown = InpCooldownBarsCnt;

      // Reset TP1 done flag for new positions
      ArrayInitialize(g_tp1Done, false);
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
