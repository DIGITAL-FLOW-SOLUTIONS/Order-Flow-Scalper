//+------------------------------------------------------------------+
//|  AdaptiveJournal.mqh  —  Adaptive Trade Journal                  |
//|  Records every real trade with full signal conditions,           |
//|  tracks MAE/MFE while open, writes CSV on close.                |
//|  CSV lives in: MT5/MQL5/Files/  (standard Files folder)         |
//+------------------------------------------------------------------+
#ifndef ADAPTIVEJOURNAL_MQH
#define ADAPTIVEJOURNAL_MQH

#define AJ_MAX_TRADES    20     // Max concurrent tracked positions
#define AJ_CSV_DEFAULT   "ScalperEA_Journal.csv"

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
   // Running stats updated every bar
   double      mfe;              // Max Favorable Excursion in price
   double      mae;              // Max Adverse Excursion in price (stored positive)
   int         barsOpen;
   bool        active;
};

AJ_TradeRecord g_aj_trades[AJ_MAX_TRADES];
string         g_aj_file = AJ_CSV_DEFAULT;
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
void AJ_Init(string filename = AJ_CSV_DEFAULT)
{
   g_aj_file = filename;
   for(int i = 0; i < AJ_MAX_TRADES; i++)
      g_aj_trades[i].active = false;

   if(!FileIsExist(g_aj_file))
      AJ_WriteHeader(g_aj_file);

   g_aj_ready = true;
   Print("AdaptiveJournal: ready — logging to ", g_aj_file);
}

//--------------------------------------------------------------------
//  Find a free tracking slot
//--------------------------------------------------------------------
int AJ_FreeSlot()
{
   for(int i = 0; i < AJ_MAX_TRADES; i++)
      if(!g_aj_trades[i].active) return i;
   return -1;
}

//--------------------------------------------------------------------
//  Find slot by ticket
//--------------------------------------------------------------------
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
//  Update MAE/MFE for all open tracked trades — call each new bar
//--------------------------------------------------------------------
void AJ_UpdateActive(string symbol)
{
   if(!g_aj_ready) return;
   for(int i = 0; i < AJ_MAX_TRADES; i++)
   {
      if(!g_aj_trades[i].active || g_aj_trades[i].symbol != symbol) continue;
      if(!PositionSelectByTicket(g_aj_trades[i].ticket)) continue;

      double cur = (g_aj_trades[i].direction > 0)
                   ? SymbolInfoDouble(symbol, SYMBOL_BID)
                   : SymbolInfoDouble(symbol, SYMBOL_ASK);

      double excursion = (g_aj_trades[i].direction > 0)
                         ? cur - g_aj_trades[i].entryPrice
                         : g_aj_trades[i].entryPrice - cur;

      if(excursion > g_aj_trades[i].mfe)   g_aj_trades[i].mfe = excursion;
      if(-excursion > g_aj_trades[i].mae)  g_aj_trades[i].mae = -excursion;
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

   // "Would reversal have won?" — reversal wins if the trade lost AND
   // the reversed direction had a favorable price move.
   // Approximation: if we lost and MFE was <0.3R while MAE >1R → reversal likely won.
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
//  Detect any tracked trades that have closed, write them to CSV
//  Call each new bar for the EA's symbol
//--------------------------------------------------------------------
void AJ_CheckClosedTrades(string symbol)
{
   if(!g_aj_ready) return;
   for(int i = 0; i < AJ_MAX_TRADES; i++)
   {
      if(!g_aj_trades[i].active || g_aj_trades[i].symbol != symbol) continue;
      if(PositionSelectByTicket(g_aj_trades[i].ticket)) continue;  // still open

      // Position gone — find the closing deal in history
      datetime exitTime  = TimeGMT();
      double   exitPrice = g_aj_trades[i].entryPrice;
      double   pl        = 0;
      string   reason    = "CLOSED";

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

      AJ_WriteRecord(g_aj_trades[i], exitTime, exitPrice, pl, reason);

      double slDist = MathAbs(g_aj_trades[i].entryPrice - g_aj_trades[i].slPrice);
      double maeR   = (slDist > 0) ? g_aj_trades[i].mae / slDist : 0;
      double mfeR   = (slDist > 0) ? g_aj_trades[i].mfe / slDist : 0;
      Print(StringFormat("AdaptiveJournal: #%I64u [%s] logged → %s | P&L=%.2f | MAE=%.2fR MFE=%.2fR | written to %s",
                          g_aj_trades[i].ticket, g_aj_trades[i].symbol,
                          reason, pl, maeR, mfeR, g_aj_file));

      g_aj_trades[i].active = false;
   }
}

//--------------------------------------------------------------------
//  External close notification — called by Live Trade Manager
//  so the exit reason is recorded correctly before AJ_CheckClosed runs
//--------------------------------------------------------------------
void AJ_NotifyClose(ulong ticket, string reason)
{
   int slot = AJ_FindSlot(ticket);
   if(slot < 0) return;
   // Override the reason so AJ_CheckClosedTrades picks it up correctly
   // We do this by marking a custom reason via a small trick:
   // We'll just let AJ_CheckClosed handle it, the DEAL_REASON will say EXPERT
   // The reason string is passed from LTM in the deal comment — logged already
   // This function is a hook for future use / additional annotation
   if(g_debugMode)
      DBG(StringFormat("AJ: close notification for #%I64u — %s", ticket, reason));
}

#endif // ADAPTIVEJOURNAL_MQH
