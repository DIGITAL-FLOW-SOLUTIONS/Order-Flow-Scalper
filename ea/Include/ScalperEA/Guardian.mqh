//+------------------------------------------------------------------+
//|  Guardian.mqh  —  Phantom Trade Layer (The Guardian)            |
//|                                                                  |
//|  On every valid signal, spawns two imaginary trades in          |
//|  parallel: one NORMAL (same as signal) and one REVERSED.        |
//|  Monitors which side hits TP vs SL in the live market.          |
//|                                                                  |
//|  Decision rule: the 2 most recent completed phantom pairs       |
//|  must BOTH confirm the same direction before any real trade     |
//|  is allowed for that symbol today.                              |
//|                                                                  |
//|  Resets at midnight GMT every day — yesterday's data is never   |
//|  used to trade today. Unresolved pairs are discarded on reset.  |
//|  Phantom spawning is session-gated; monitoring runs every tick. |
//+------------------------------------------------------------------+
#ifndef GUARDIAN_MQH
#define GUARDIAN_MQH

#define GRD_MAX_ACTIVE   10    // Max phantom pairs open simultaneously
#define GRD_HISTORY_SIZE 50    // Ring-buffer depth for today's completed pairs

//--------------------------------------------------------------------
//  A phantom pair: one NORMAL leg + one REVERSED leg, tracked live
//--------------------------------------------------------------------
struct GRD_Phantom
{
   ulong    id;
   string   symbol;

   // NORMAL leg  (same direction as the signal)
   int      normalDir;
   double   normalEntry;
   double   normalSL;
   double   normalTP;
   bool     normalClosed;
   bool     normalWon;       // true = TP hit, false = SL hit

   // REVERSED leg  (opposite direction, same SL/TP distances)
   int      revDir;
   double   revEntry;
   double   revSL;
   double   revTP;
   bool     revClosed;
   bool     revWon;

   datetime openTime;
   bool     active;
   bool     pairComplete;
};

//--------------------------------------------------------------------
//  Guardian state  — per EA instance (= per symbol, per chart)
//--------------------------------------------------------------------
struct GRD_State
{
   // Today's result ring-buffer
   bool  normalWon[GRD_HISTORY_SIZE];
   bool  revWon[GRD_HISTORY_SIZE];
   int   windowHead;       // next write position (circular)
   int   totalCompleted;   // total pairs completed today

   // Decision outputs (refreshed after every pair completes)
   bool  canTrade;         // last g_grd_minSamp pairs all agree on a direction
   bool  preferReversed;   // last g_grd_minSamp pairs all say reversed wins

   // Daily tracking
   int   lastGMTDay;       // GMT calendar day of last reset (set to today on init)
};

GRD_Phantom g_grd_phantoms[GRD_MAX_ACTIVE];
GRD_State   g_grd;
ulong       g_grd_nextId  = 1;
string      g_grd_file    = "";
bool        g_grd_ready   = false;
int         g_grd_minSamp = 2;   // phantom pairs required before first real trade each day

//--------------------------------------------------------------------
//  Write CSV header (called once when file doesn't yet exist)
//--------------------------------------------------------------------
void GRD_WriteHeader(string filename)
{
   int fh = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;
   FileWrite(fh,
      "PairID","Symbol","OpenTime(GMT)","CloseTime(GMT)",
      "NormalDir","NormalEntry","NormalSL","NormalTP","NormalResult",
      "RevDir","RevEntry","RevSL","RevTP","RevResult",
      "TodayPairs","Decision");
   FileClose(fh);
}

//--------------------------------------------------------------------
//  Initialise Guardian — call once in OnInit()
//
//  symbol     : EA's chart symbol (_Symbol)
//  minSamples : completed phantom pairs required per day before
//               real trading is allowed (default 2)
//  csvFile    : leave "" to auto-generate per-symbol filename
//--------------------------------------------------------------------
void GRD_Init(string symbol, int minSamples = 2, string csvFile = "")
{
   g_grd_minSamp = minSamples;

   // Each symbol gets its own log so multiple EA instances never conflict
   g_grd_file = (csvFile == "" || csvFile == "ScalperEA_Guardian.csv")
                ? "ScalperEA_Guardian_" + symbol + ".csv"
                : csvFile;

   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
      g_grd_phantoms[i].active = false;

   ArrayInitialize(g_grd.normalWon, false);
   ArrayInitialize(g_grd.revWon,    false);
   g_grd.windowHead     = 0;
   g_grd.totalCompleted = 0;
   g_grd.canTrade       = false;   // gate is always ON — must earn permission daily
   g_grd.preferReversed = false;
   // Initialise to today's actual GMT day — GRD_Init already clears all state,
   // so there's no need to fire GRD_DailyReset again on the very first tick.
   MqlDateTime gmtNow;
   TimeToStruct(TimeGMT(), gmtNow);
   g_grd.lastGMTDay = gmtNow.day;

   if(!FileIsExist(g_grd_file))
      GRD_WriteHeader(g_grd_file);

   g_grd_ready = true;
   Print(StringFormat("Guardian [%s]: ready | requires %d phantom pair(s)/day | log → %s",
                      symbol, g_grd_minSamp, g_grd_file));
}

//--------------------------------------------------------------------
//  Daily reset — called automatically at midnight GMT.
//  Wipes today's results and expires all unresolved phantom pairs.
//  After reset canTrade = false until fresh phantom data confirms.
//--------------------------------------------------------------------
void GRD_DailyReset(string symbol)
{
   // Expire unresolved phantoms — discard, do NOT record a result
   int expired = 0;
   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
   {
      if(g_grd_phantoms[i].active && g_grd_phantoms[i].symbol == symbol)
      {
         g_grd_phantoms[i].active = false;
         expired++;
      }
   }

   ArrayInitialize(g_grd.normalWon, false);
   ArrayInitialize(g_grd.revWon,    false);
   g_grd.windowHead     = 0;
   g_grd.totalCompleted = 0;
   g_grd.canTrade       = false;   // must collect fresh phantom data first
   g_grd.preferReversed = false;

   Print(StringFormat("Guardian [%s]: DAILY RESET at midnight GMT | "
                      "%d unresolved pair(s) discarded | "
                      "waiting for %d phantom pair(s) before real trading",
                      symbol, expired, g_grd_minSamp));
}

//--------------------------------------------------------------------
//  Find a free phantom slot (returns -1 if all 10 are occupied)
//--------------------------------------------------------------------
int GRD_FreeSlot()
{
   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
      if(!g_grd_phantoms[i].active) return i;
   return -1;
}

//--------------------------------------------------------------------
//  Recompute decision outputs from the last InpGRD_MinSample results.
//
//  Checks the last g_grd_minSamp completed phantom pairs (default 2):
//    All NORMAL hit TP   →  canTrade=true,  preferReversed=false
//    All REVERSED hit TP →  canTrade=true,  preferReversed=true
//    Anything else       →  canTrade=false  (wait for next pair)
//--------------------------------------------------------------------
void GRD_RecomputeStats()
{
   // Not enough phantom pairs completed today yet
   // g_grd_minSamp is the runtime value of InpGRD_MinSample (default 2)
   if(g_grd.totalCompleted < g_grd_minSamp)
   {
      g_grd.canTrade       = false;
      g_grd.preferReversed = false;
      return;
   }

   // Check that the last g_grd_minSamp completed pairs all agree on direction
   bool allNormal   = true;
   bool allReversed = true;
   for(int k = 1; k <= g_grd_minSamp; k++)
   {
      int idx = (g_grd.windowHead - k + GRD_HISTORY_SIZE) % GRD_HISTORY_SIZE;
      if(!g_grd.normalWon[idx]) allNormal   = false;
      if(!g_grd.revWon[idx])    allReversed = false;
   }

   if(allNormal)
   {
      // Last 2: normal TP, normal TP  → trend confirmed, trade normal direction
      g_grd.canTrade       = true;
      g_grd.preferReversed = false;
   }
   else if(allReversed)
   {
      // Last 2: reversed TP, reversed TP → counter-signal confirmed, trade reversed
      g_grd.canTrade       = true;
      g_grd.preferReversed = true;
   }
   else
   {
      // Mixed result — no consistent direction yet, wait for next phantom pair
      g_grd.canTrade       = false;
      g_grd.preferReversed = false;
   }
}

//--------------------------------------------------------------------
//  Record a completed pair result into today's ring buffer + CSV
//--------------------------------------------------------------------
void GRD_RecordResult(GRD_Phantom &p)
{
   int head = g_grd.windowHead;
   g_grd.normalWon[head] = p.normalWon;
   g_grd.revWon[head]    = p.revWon;
   g_grd.windowHead      = (head + 1) % GRD_HISTORY_SIZE;
   g_grd.totalCompleted++;

   GRD_RecomputeStats();

   string decision = g_grd.canTrade
                   ? (g_grd.preferReversed ? "TRADE_REVERSED" : "TRADE_NORMAL")
                   : "WAIT_CONFIRM";

   // Write to per-symbol CSV
   int fh = FileOpen(g_grd_file, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh != INVALID_HANDLE)
   {
      FileSeek(fh, 0, SEEK_END);
      FileWrite(fh,
         (string)p.id,
         p.symbol,
         TimeToString(p.openTime, TIME_DATE|TIME_MINUTES),
         TimeToString(TimeGMT(),  TIME_DATE|TIME_MINUTES),
         p.normalDir > 0 ? "LONG" : "SHORT",
         DoubleToString(p.normalEntry, 5),
         DoubleToString(p.normalSL,    5),
         DoubleToString(p.normalTP,    5),
         p.normalWon ? "TP" : "SL",
         p.revDir > 0 ? "LONG" : "SHORT",
         DoubleToString(p.revEntry, 5),
         DoubleToString(p.revSL,    5),
         DoubleToString(p.revTP,    5),
         p.revWon ? "TP" : "SL",
         (string)g_grd.totalCompleted,
         decision);
      FileClose(fh);
   }

   Print(StringFormat("Guardian [%s]: pair #%I64u done | NORMAL=%s REV=%s | "
                      "today's pairs=%d → %s",
                      p.symbol, p.id,
                      p.normalWon ? "TP" : "SL",
                      p.revWon    ? "TP" : "SL",
                      g_grd.totalCompleted,
                      decision));

   p.active = false;
}

//--------------------------------------------------------------------
//  Check a single phantom leg against live bid/ask
//  Returns true when the leg has just resolved (SL or TP touched)
//--------------------------------------------------------------------
bool GRD_CheckLeg(int legDir, double legSL, double legTP,
                  string symbol, bool &won)
{
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   if(legDir > 0)   // phantom LONG — exits on bid
   {
      if(bid <= legSL) { won = false; return true; }
      if(bid >= legTP) { won = true;  return true; }
   }
   else             // phantom SHORT — exits on ask
   {
      if(ask >= legSL) { won = false; return true; }
      if(ask <= legTP) { won = true;  return true; }
   }
   return false;
}

//--------------------------------------------------------------------
//  Update all active phantom pairs — call on EVERY TICK.
//  Also checks for midnight GMT daily reset at the top.
//--------------------------------------------------------------------
void GRD_UpdateOnTick(string symbol)
{
   if(!g_grd_ready) return;

   // --- Midnight GMT reset ---
   MqlDateTime gmt;
   TimeToStruct(TimeGMT(), gmt);
   if(gmt.day != g_grd.lastGMTDay)
   {
      GRD_DailyReset(symbol);
      g_grd.lastGMTDay = gmt.day;
   }

   // --- Monitor every active phantom pair tick by tick ---
   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
   {
      if(!g_grd_phantoms[i].active || g_grd_phantoms[i].symbol != symbol) continue;

      if(!g_grd_phantoms[i].normalClosed)
      {
         bool won = false;
         if(GRD_CheckLeg(g_grd_phantoms[i].normalDir,
                         g_grd_phantoms[i].normalSL, g_grd_phantoms[i].normalTP,
                         symbol, won))
         {
            g_grd_phantoms[i].normalClosed = true;
            g_grd_phantoms[i].normalWon    = won;
         }
      }

      if(!g_grd_phantoms[i].revClosed)
      {
         bool won = false;
         if(GRD_CheckLeg(g_grd_phantoms[i].revDir,
                         g_grd_phantoms[i].revSL, g_grd_phantoms[i].revTP,
                         symbol, won))
         {
            g_grd_phantoms[i].revClosed = true;
            g_grd_phantoms[i].revWon    = won;
         }
      }

      // Both legs resolved → record result and update decision
      if(g_grd_phantoms[i].normalClosed && g_grd_phantoms[i].revClosed
         && !g_grd_phantoms[i].pairComplete)
      {
         g_grd_phantoms[i].pairComplete = true;
         GRD_RecordResult(g_grd_phantoms[i]);
      }
   }
}

//--------------------------------------------------------------------
//  Spawn a new phantom pair on a valid entry signal.
//
//  MUST be called BEFORE the Guardian gate check so phantoms
//  accumulate even while real trading is blocked.
//
//  Session-gated: phantoms only spawn inside the trading session
//  so Guardian never collects data from the wrong market hours.
//--------------------------------------------------------------------
void GRD_SpawnPhantoms(string symbol,
                       int    signalDir,    // +1 = long signal, -1 = short signal
                       double entryPrice,   // reference price (for logging only)
                       double slDist,       // SL distance in price
                       double tp1Dist)      // TP distance in price
{
   if(!g_grd_ready) return;

   // Only collect data inside the session we actually trade
   if(!IsInSession())
   {
      if(g_debugMode) DBG("Guardian: outside session — phantom spawn skipped");
      return;
   }

   int slot = GRD_FreeSlot();
   if(slot < 0)
   {
      if(g_debugMode) DBG("Guardian: no free phantom slot — skipping spawn");
      return;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   g_grd_phantoms[slot].id           = g_grd_nextId++;
   g_grd_phantoms[slot].symbol       = symbol;
   g_grd_phantoms[slot].openTime     = TimeGMT();
   g_grd_phantoms[slot].active       = true;
   g_grd_phantoms[slot].pairComplete = false;

   // --- NORMAL leg (signal direction) ---
   g_grd_phantoms[slot].normalDir = signalDir;
   if(signalDir > 0)
   {
      g_grd_phantoms[slot].normalEntry = SymbolInfoDouble(symbol, SYMBOL_ASK);
      g_grd_phantoms[slot].normalSL    = NormalizeDouble(g_grd_phantoms[slot].normalEntry - slDist,  digits);
      g_grd_phantoms[slot].normalTP    = NormalizeDouble(g_grd_phantoms[slot].normalEntry + tp1Dist, digits);
   }
   else
   {
      g_grd_phantoms[slot].normalEntry = SymbolInfoDouble(symbol, SYMBOL_BID);
      g_grd_phantoms[slot].normalSL    = NormalizeDouble(g_grd_phantoms[slot].normalEntry + slDist,  digits);
      g_grd_phantoms[slot].normalTP    = NormalizeDouble(g_grd_phantoms[slot].normalEntry - tp1Dist, digits);
   }
   g_grd_phantoms[slot].normalClosed = false;
   g_grd_phantoms[slot].normalWon    = false;

   // --- REVERSED leg (opposite direction, same distances) ---
   g_grd_phantoms[slot].revDir = -signalDir;
   if(g_grd_phantoms[slot].revDir > 0)
   {
      g_grd_phantoms[slot].revEntry = SymbolInfoDouble(symbol, SYMBOL_ASK);
      g_grd_phantoms[slot].revSL    = NormalizeDouble(g_grd_phantoms[slot].revEntry - slDist,  digits);
      g_grd_phantoms[slot].revTP    = NormalizeDouble(g_grd_phantoms[slot].revEntry + tp1Dist, digits);
   }
   else
   {
      g_grd_phantoms[slot].revEntry = SymbolInfoDouble(symbol, SYMBOL_BID);
      g_grd_phantoms[slot].revSL    = NormalizeDouble(g_grd_phantoms[slot].revEntry + slDist,  digits);
      g_grd_phantoms[slot].revTP    = NormalizeDouble(g_grd_phantoms[slot].revEntry - tp1Dist, digits);
   }
   g_grd_phantoms[slot].revClosed = false;
   g_grd_phantoms[slot].revWon    = false;

   if(g_debugMode)
      DBG(StringFormat("Guardian: spawned pair #%I64u | signal@%.5f | "
                       "NORMAL %s entry=%.5f SL=%.5f TP=%.5f | "
                       "REV %s entry=%.5f SL=%.5f TP=%.5f | "
                       "today=%d pairs completed",
                       g_grd_phantoms[slot].id,
                       entryPrice,
                       g_grd_phantoms[slot].normalDir > 0 ? "LONG" : "SHORT",
                       g_grd_phantoms[slot].normalEntry,
                       g_grd_phantoms[slot].normalSL,
                       g_grd_phantoms[slot].normalTP,
                       g_grd_phantoms[slot].revDir > 0 ? "LONG" : "SHORT",
                       g_grd_phantoms[slot].revEntry,
                       g_grd_phantoms[slot].revSL,
                       g_grd_phantoms[slot].revTP,
                       g_grd.totalCompleted));
}

//--------------------------------------------------------------------
//  Public accessors — call from OnTick() to gate trading decisions
//--------------------------------------------------------------------
bool GRD_CanTrade()       { return g_grd.canTrade; }
bool GRD_PreferReversed() { return g_grd.preferReversed; }
int  GRD_SampleCount()    { return g_grd.totalCompleted; }

// Win rates over today's completed pairs — informational, not used in decisions
double GRD_NormalWinRate()
{
   int n = MathMin(g_grd.totalCompleted, GRD_HISTORY_SIZE);
   if(n == 0) return 0.0;
   int wins = 0;
   for(int i = 0; i < n; i++) if(g_grd.normalWon[i]) wins++;
   return (double)wins / n;
}
double GRD_RevWinRate()
{
   int n = MathMin(g_grd.totalCompleted, GRD_HISTORY_SIZE);
   if(n == 0) return 0.0;
   int wins = 0;
   for(int i = 0; i < n; i++) if(g_grd.revWon[i]) wins++;
   return (double)wins / n;
}

#endif // GUARDIAN_MQH
