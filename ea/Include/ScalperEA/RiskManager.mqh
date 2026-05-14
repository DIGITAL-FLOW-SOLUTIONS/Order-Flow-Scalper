//+------------------------------------------------------------------+
//|  RiskManager.mqh  —  Risk & Position Sizing Module               |
//|  Handles lot sizing, trailing stops, break-even, partial close.  |
//+------------------------------------------------------------------+
#pragma once
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--------------------------------------------------------------------
//  Calculate ATR for a given symbol/tf/period
//--------------------------------------------------------------------
double CalcATR(string symbol, ENUM_TIMEFRAMES tf, int period = 14)
{
   double handle_atr[];
   int atrHandle = iATR(symbol, tf, period);
   if(atrHandle == INVALID_HANDLE) return 0;
   if(CopyBuffer(atrHandle, 0, 1, 1, handle_atr) <= 0) return 0;
   IndicatorRelease(atrHandle);
   return handle_atr[0];
}

//--------------------------------------------------------------------
//  Lot size based on % risk of balance
//  riskPct  : e.g. 0.01 = 1%
//  slPoints : stop loss in points (not pips)
//  Returns 0.0 if cannot compute
//--------------------------------------------------------------------
double CalcLotSize(string symbol, double riskPct, double slPoints)
{
   if(slPoints <= 0) return 0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * riskPct;

   double tickVal   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotMin    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lotMax    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0 || tickSize <= 0) return lotMin;

   // Money risk per lot = (slPoints / tickSize) * tickVal
   double moneyPerLot = (slPoints / tickSize) * tickVal;
   if(moneyPerLot <= 0) return lotMin;

   double lots = riskMoney / moneyPerLot;

   // Normalise to broker constraints
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lotMin, MathMin(lotMax, lots));
   return NormalizeDouble(lots, 2);
}

//--------------------------------------------------------------------
//  Move stop loss to break-even
//  Triggers once floating profit >= beATRMultiple * ATR
//--------------------------------------------------------------------
bool MoveToBreakEven(CTrade &trade, CPositionInfo &pos,
                     ulong ticket, double beATRMultiple,
                     string symbol, ENUM_TIMEFRAMES tf)
{
   if(!pos.SelectByTicket(ticket)) return false;
   double openPrice = pos.PriceOpen();
   double currentSL = pos.StopLoss();
   double curPrice  = (pos.PositionType() == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(symbol, SYMBOL_BID)
                     : SymbolInfoDouble(symbol, SYMBOL_ASK);
   double atr = CalcATR(symbol, tf);
   if(atr <= 0) return false;

   double pts = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD) * pts;

   if(pos.PositionType() == POSITION_TYPE_BUY)
   {
      double profitDist = curPrice - openPrice;
      if(profitDist >= beATRMultiple * atr && currentSL < openPrice)
      {
         double newSL = openPrice + spread;   // BE + spread buffer
         trade.PositionModify(ticket, newSL, pos.TakeProfit());
         return true;
      }
   }
   else // SELL
   {
      double profitDist = openPrice - curPrice;
      if(profitDist >= beATRMultiple * atr && (currentSL > openPrice || currentSL == 0))
      {
         double newSL = openPrice - spread;
         trade.PositionModify(ticket, newSL, pos.TakeProfit());
         return true;
      }
   }
   return false;
}

//--------------------------------------------------------------------
//  ATR-based trailing stop
//  Trails the stop by trailATRMultiple * ATR behind current price
//--------------------------------------------------------------------
bool TrailStop(CTrade &trade, CPositionInfo &pos, ulong ticket,
               double trailATRMultiple, string symbol, ENUM_TIMEFRAMES tf)
{
   if(!pos.SelectByTicket(ticket)) return false;
   double atr = CalcATR(symbol, tf);
   if(atr <= 0) return false;

   double trailDist = trailATRMultiple * atr;
   double pts       = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(pos.PositionType() == POSITION_TYPE_BUY)
   {
      double curBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double newSL  = curBid - trailDist;
      newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      if(newSL > pos.StopLoss() + pts)
         trade.PositionModify(ticket, newSL, pos.TakeProfit());
   }
   else
   {
      double curAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double newSL  = curAsk + trailDist;
      newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      if(pos.StopLoss() == 0 || newSL < pos.StopLoss() - pts)
         trade.PositionModify(ticket, newSL, pos.TakeProfit());
   }
   return true;
}

//--------------------------------------------------------------------
//  Partial close: close pct% of position
//  e.g. pct = 0.5 closes half
//--------------------------------------------------------------------
bool PartialClose(CTrade &trade, CPositionInfo &pos,
                  ulong ticket, double pct = 0.5)
{
   if(!pos.SelectByTicket(ticket)) return false;
   double curVol  = pos.Volume();
   double minVol  = SymbolInfoDouble(pos.Symbol(), SYMBOL_VOLUME_MIN);
   double step    = SymbolInfoDouble(pos.Symbol(), SYMBOL_VOLUME_STEP);
   double closeVol = NormalizeDouble(MathFloor(curVol * pct / step) * step, 2);
   if(closeVol < minVol) return false;
   return trade.PositionClosePartial(ticket, closeVol);
}

//--------------------------------------------------------------------
//  Check if daily drawdown limit has been hit
//  dayOpenBalance: account balance at session start (recorded once per day)
//  Falls back to live balance if dayOpenBalance is 0.
//  This mirrors prop firm rules: drawdown measured from day-open equity.
//--------------------------------------------------------------------
bool DailyDrawdownBreached(double maxDailyDrawdownPct, double dayOpenBalance = 0)
{
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double refBal   = (dayOpenBalance > 0) ? dayOpenBalance
                                          : AccountInfoDouble(ACCOUNT_BALANCE);
   if(refBal <= 0) return false;
   double ddPct = (refBal - equity) / refBal;
   return (ddPct >= maxDailyDrawdownPct);
}

//--------------------------------------------------------------------
//  Check daily profit target — stop trading once hit
//  dayOpenBalance: account balance at session start
//--------------------------------------------------------------------
bool DailyProfitTargetHit(double targetPct, double dayOpenBalance = 0)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double refBal  = (dayOpenBalance > 0) ? dayOpenBalance
                                         : AccountInfoDouble(ACCOUNT_BALANCE);
   if(refBal <= 0) return false;
   double profitPct = (equity - refBal) / refBal;
   return (profitPct >= targetPct);
}

//--------------------------------------------------------------------
//  Count open positions for a symbol with given magic number
//--------------------------------------------------------------------
int CountOpenPositions(string symbol, ulong magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)magic)
            count++;
      }
   }
   return count;
}

//--------------------------------------------------------------------
//  Get total open profit/loss for a symbol with given magic number
//--------------------------------------------------------------------
double GetOpenPnL(string symbol, ulong magic)
{
   double pnl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)magic)
            pnl += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return pnl;
}

//--------------------------------------------------------------------
//  Close all positions for a symbol with given magic
//--------------------------------------------------------------------
void CloseAllPositions(CTrade &trade, string symbol, ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)magic)
            trade.PositionClose(ticket);
      }
   }
}
