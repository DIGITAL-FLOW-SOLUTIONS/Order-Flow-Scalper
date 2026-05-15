//+------------------------------------------------------------------+
//|  Guardian.mqh  —  Phantom Trade Layer (The Guardian)            |
//|  Places imaginary (phantom) trade pairs — one in the signal     |
//|  direction (NORMAL) and one reversed — monitoring which side    |
//|  reaches TP vs SL in live market conditions.                    |
//|                                                                  |
//|  Rolling window of results gates real trading and advises       |
//|  whether to trade normal or reversed on next signal.            |
//|  Monitoring runs 24/7 (every tick), not just session bars.      |
//+------------------------------------------------------------------+
#ifndef GUARDIAN_MQH
#define GUARDIAN_MQH

#define GRD_MAX_ACTIVE   10    // Max phantom pairs open simultaneously
#define GRD_WINDOW_SIZE  20    // Rolling result window
#define GRD_CSV_DEFAULT  "ScalperEA_Guardian.csv"

//--------------------------------------------------------------------
//  A phantom pair: one NORMAL leg + one REVERSED leg
//  Monitored until one side closes (SL or TP hit)
//--------------------------------------------------------------------
struct GRD_Phantom
{
   ulong    id;
   string   symbol;
   // NORMAL leg (same direction as signal)
   int      normalDir;
   double   normalEntry;
   double   normalSL;
   double   normalTP;
   bool     normalClosed;
   bool     normalWon;          // true=TP hit, false=SL hit
   // REVERSED leg (opposite direction, same distances)
   int      revDir;
   double   revEntry;
   double   revSL;
   double   revTP;
   bool     revClosed;
   bool     revWon;
   // Meta
   datetime openTime;
   bool     active;
   bool     pairComplete;       // both legs resolved
};

//--------------------------------------------------------------------
//  Guardian state — rolling window + decision outputs
//--------------------------------------------------------------------
struct GRD_State
{
   // Circular rolling window (last GRD_WINDOW_SIZE completed pairs)
   bool  normalWon[GRD_WINDOW_SIZE];
   bool  revWon[GRD_WINDOW_SIZE];
   int   windowHead;            // next write position
   int   totalCompleted;        // total pairs ever completed

   // Computed after each update
   double normalWinRate;
   double revWinRate;
   int    sampleCount;          // completed pairs in current window (max=GRD_WINDOW_SIZE)

   // Decision outputs (refreshed on each GRD_UpdateResults call)
   bool   canTrade;             // at least one side has edge
   bool   preferReversed;       // reversed side clearly winning
};

GRD_Phantom g_grd_phantoms[GRD_MAX_ACTIVE];
GRD_State   g_grd;
ulong       g_grd_nextId  = 1;
string      g_grd_file    = GRD_CSV_DEFAULT;
bool        g_grd_ready   = false;
int         g_grd_minSamp = 5;      // minimum before gating
double      g_grd_edgeThresh = 0.10; // 10% win-rate gap to prefer reversed

//--------------------------------------------------------------------
//  Write Guardian CSV header
//--------------------------------------------------------------------
void GRD_WriteHeader(string filename)
{
   int fh = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;
   FileWrite(fh, "PairID","Symbol","OpenTime","CloseTime",
                 "NormalDir","NormalEntry","NormalSL","NormalTP","NormalResult",
                 "RevDir","RevEntry","RevSL","RevTP","RevResult",
                 "NormalWinRate","RevWinRate","SampleCount","Decision");
   FileClose(fh);
}

//--------------------------------------------------------------------
//  Initialise — call in OnInit()
//--------------------------------------------------------------------
void GRD_Init(int minSamples = 5, double edgeThreshold = 0.10,
              string csvFile = GRD_CSV_DEFAULT)
{
   g_grd_minSamp    = minSamples;
   g_grd_edgeThresh = edgeThreshold;
   g_grd_file       = csvFile;

   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
      g_grd_phantoms[i].active = false;

   g_grd.windowHead      = 0;
   g_grd.totalCompleted  = 0;
   g_grd.normalWinRate   = 0.5;
   g_grd.revWinRate      = 0.5;
   g_grd.sampleCount     = 0;
   g_grd.canTrade        = true;  // allow trading until we have data
   g_grd.preferReversed  = false;

   ArrayInitialize(g_grd.normalWon, false);
   ArrayInitialize(g_grd.revWon, false);

   if(!FileIsExist(g_grd_file))
      GRD_WriteHeader(g_grd_file);

   g_grd_ready = true;
   Print("Guardian: ready — phantom window=", g_grd_minSamp,
         " edge-threshold=", g_grd_edgeThresh * 100, "%");
}

//--------------------------------------------------------------------
//  Find a free phantom slot
//--------------------------------------------------------------------
int GRD_FreeSlot()
{
   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
      if(!g_grd_phantoms[i].active) return i;
   return -1;
}

//--------------------------------------------------------------------
//  Spawn a new phantom pair from a valid entry signal
//  Call this BEFORE applying REVERSER so we always track the
//  natural signal direction for unbiased comparison.
//--------------------------------------------------------------------
void GRD_SpawnPhantoms(string symbol,
                       int signalDir,         // natural signal direction (+1 or -1)
                       double entryPrice,     // expected entry (ASK for long, BID for short)
                       double slDist,         // SL distance in price
                       double tp1Dist)        // TP1 distance in price
{
   if(!g_grd_ready) return;
   int slot = GRD_FreeSlot();
   if(slot < 0)
   {
      if(g_debugMode) DBG("Guardian: no free phantom slot — skipping spawn");
      return;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   GRD_Phantom &p = g_grd_phantoms[slot];
   p.id        = g_grd_nextId++;
   p.symbol    = symbol;
   p.openTime  = TimeCurrent();
   p.active    = true;
   p.pairComplete = false;

   // ---- NORMAL leg ----
   p.normalDir   = signalDir;
   if(signalDir > 0)  // LONG
   {
      p.normalEntry = SymbolInfoDouble(symbol, SYMBOL_ASK);
      p.normalSL    = NormalizeDouble(p.normalEntry - slDist, digits);
      p.normalTP    = NormalizeDouble(p.normalEntry + tp1Dist, digits);
   }
   else  // SHORT
   {
      p.normalEntry = SymbolInfoDouble(symbol, SYMBOL_BID);
      p.normalSL    = NormalizeDouble(p.normalEntry + slDist, digits);
      p.normalTP    = NormalizeDouble(p.normalEntry - tp1Dist, digits);
   }
   p.normalClosed = false;
   p.normalWon    = false;

   // ---- REVERSED leg — same distances, opposite direction ----
   p.revDir = -signalDir;
   if(p.revDir > 0)  // LONG
   {
      p.revEntry = SymbolInfoDouble(symbol, SYMBOL_ASK);
      p.revSL    = NormalizeDouble(p.revEntry - slDist, digits);
      p.revTP    = NormalizeDouble(p.revEntry + tp1Dist, digits);
   }
   else  // SHORT
   {
      p.revEntry = SymbolInfoDouble(symbol, SYMBOL_BID);
      p.revSL    = NormalizeDouble(p.revEntry + slDist, digits);
      p.revTP    = NormalizeDouble(p.revEntry - tp1Dist, digits);
   }
   p.revClosed = false;
   p.revWon    = false;

   if(g_debugMode)
      DBG(StringFormat("Guardian: spawned pair #%I64u | NORMAL %s entry=%.5f SL=%.5f TP=%.5f | "
                        "REV %s entry=%.5f SL=%.5f TP=%.5f",
                        p.id,
                        p.normalDir > 0 ? "LONG" : "SHORT",
                        p.normalEntry, p.normalSL, p.normalTP,
                        p.revDir > 0 ? "LONG" : "SHORT",
                        p.revEntry, p.revSL, p.revTP));
}

//--------------------------------------------------------------------
//  Recompute rolling statistics and update decision outputs
//--------------------------------------------------------------------
void GRD_RecomputeStats()
{
   int samples = MathMin(g_grd.totalCompleted, GRD_WINDOW_SIZE);
   g_grd.sampleCount = samples;

   if(samples == 0)
   {
      g_grd.normalWinRate  = 0.5;
      g_grd.revWinRate     = 0.5;
      g_grd.canTrade       = true;
      g_grd.preferReversed = false;
      return;
   }

   int normWins = 0, revWins = 0;
   for(int i = 0; i < samples; i++)
   {
      if(g_grd.normalWon[i]) normWins++;
      if(g_grd.revWon[i])    revWins++;
   }

   g_grd.normalWinRate = (double)normWins / samples;
   g_grd.revWinRate    = (double)revWins  / samples;

   // Only gate trading once we have minimum sample
   if(samples >= g_grd_minSamp)
   {
      // Allow trading if either side wins at least 35% of the time
      g_grd.canTrade = (g_grd.normalWinRate >= 0.35 || g_grd.revWinRate >= 0.35);
      // Prefer reversed if it beats normal by the edge threshold
      g_grd.preferReversed = (g_grd.revWinRate > g_grd.normalWinRate + g_grd_edgeThresh);
   }
   else
   {
      // Not enough data yet — allow trading, no preference
      g_grd.canTrade       = true;
      g_grd.preferReversed = false;
   }
}

//--------------------------------------------------------------------
//  Record a completed phantom pair result into the rolling window
//  and write to CSV
//--------------------------------------------------------------------
void GRD_RecordResult(GRD_Phantom &p)
{
   // Write to rolling window
   int head = g_grd.windowHead;
   g_grd.normalWon[head] = p.normalWon;
   g_grd.revWon[head]    = p.revWon;
   g_grd.windowHead      = (head + 1) % GRD_WINDOW_SIZE;
   g_grd.totalCompleted++;

   GRD_RecomputeStats();

   // Write to CSV
   int fh = FileOpen(g_grd_file, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh != INVALID_HANDLE)
   {
      FileSeek(fh, 0, SEEK_END);
      string decision = g_grd.preferReversed ? "PREFER_REVERSED" :
                        (!g_grd.canTrade)     ? "PAUSE_TRADING"  : "TRADE_NORMAL";
      FileWrite(fh,
         (string)p.id, p.symbol,
         TimeToString(p.openTime, TIME_DATE|TIME_MINUTES),
         TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
         p.normalDir > 0 ? "LONG" : "SHORT",
         DoubleToString(p.normalEntry, 5),
         DoubleToString(p.normalSL, 5),
         DoubleToString(p.normalTP, 5),
         p.normalWon ? "TP" : "SL",
         p.revDir > 0 ? "LONG" : "SHORT",
         DoubleToString(p.revEntry, 5),
         DoubleToString(p.revSL, 5),
         DoubleToString(p.revTP, 5),
         p.revWon ? "TP" : "SL",
         DoubleToString(g_grd.normalWinRate * 100, 1),
         DoubleToString(g_grd.revWinRate    * 100, 1),
         (string)g_grd.sampleCount,
         decision);
      FileClose(fh);
   }

   if(g_debugMode)
      DBG(StringFormat("Guardian: pair #%I64u done | NORMAL=%s REV=%s | "
                        "NormWR=%.0f%% RevWR=%.0f%% [%d samples] → %s",
                        p.id,
                        p.normalWon ? "TP✓" : "SL✗",
                        p.revWon    ? "TP✓" : "SL✗",
                        g_grd.normalWinRate * 100,
                        g_grd.revWinRate    * 100,
                        g_grd.sampleCount,
                        g_grd.preferReversed ? "PREFER_REVERSED" :
                        (!g_grd.canTrade)    ? "PAUSE" : "NORMAL"));

   p.active = false;
}

//--------------------------------------------------------------------
//  Check a single phantom leg against current bid/ask
//  Returns true if the leg has just closed (SL or TP hit)
//--------------------------------------------------------------------
bool GRD_CheckLeg(int legDir, double legEntry, double legSL, double legTP,
                  string symbol, bool &won)
{
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   if(legDir > 0)  // phantom LONG — SL below, TP above
   {
      if(bid <= legSL) { won = false; return true; }  // SL hit
      if(bid >= legTP) { won = true;  return true; }  // TP hit
   }
   else  // phantom SHORT — SL above, TP below
   {
      if(ask >= legSL) { won = false; return true; }  // SL hit
      if(ask <= legTP) { won = true;  return true; }  // TP hit
   }
   return false;
}

//--------------------------------------------------------------------
//  Update all active phantom pairs — call on EVERY TICK (24/7)
//--------------------------------------------------------------------
void GRD_UpdateOnTick(string symbol)
{
   if(!g_grd_ready) return;

   for(int i = 0; i < GRD_MAX_ACTIVE; i++)
   {
      GRD_Phantom &p = g_grd_phantoms[i];
      if(!p.active || p.symbol != symbol) continue;

      // Check NORMAL leg
      if(!p.normalClosed)
      {
         bool won = false;
         if(GRD_CheckLeg(p.normalDir, p.normalEntry, p.normalSL, p.normalTP, symbol, won))
         {
            p.normalClosed = true;
            p.normalWon    = won;
         }
      }

      // Check REVERSED leg
      if(!p.revClosed)
      {
         bool won = false;
         if(GRD_CheckLeg(p.revDir, p.revEntry, p.revSL, p.revTP, symbol, won))
         {
            p.revClosed = true;
            p.revWon    = won;
         }
      }

      // If BOTH legs have resolved, record results
      if(p.normalClosed && p.revClosed && !p.pairComplete)
      {
         p.pairComplete = true;
         GRD_RecordResult(p);
      }
   }
}

//--------------------------------------------------------------------
//  Public accessors — call from OnTick() to gate trading decisions
//--------------------------------------------------------------------
bool   GRD_CanTrade()        { return g_grd.canTrade; }
bool   GRD_PreferReversed()  { return g_grd.preferReversed; }
double GRD_NormalWinRate()   { return g_grd.normalWinRate; }
double GRD_RevWinRate()      { return g_grd.revWinRate; }
int    GRD_SampleCount()     { return g_grd.sampleCount; }

#endif // GUARDIAN_MQH
