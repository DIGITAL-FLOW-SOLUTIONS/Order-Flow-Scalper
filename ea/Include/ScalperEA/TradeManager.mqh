//+------------------------------------------------------------------+
//|  TradeManager.mqh  —  Trade Execution & Signal Aggregation       |
//|  Combines order flow, volume profile and ORB signals into        |
//|  structured entry/exit decisions.                                 |
//+------------------------------------------------------------------+
#ifndef TRADEMANAGER_MQH
#define TRADEMANAGER_MQH
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include "OrderFlow.mqh"
#include "VolumeProfile.mqh"
#include "ORB.mqh"
#include "RiskManager.mqh"

//--------------------------------------------------------------------
//  Signal strength thresholds
//--------------------------------------------------------------------
#define SIG_MIN_OF_SCORE      2     // Minimum order flow score to consider entry
#define SIG_MIN_CONFLUENCE    2     // Minimum number of confirming signals

//--------------------------------------------------------------------
//  Entry signal structure
//  (also carries signal conditions for the Adaptive Journal)
//--------------------------------------------------------------------
struct EntrySignal
{
   int      direction;       // +1 long, -1 short, 0 no signal
   double   entryPrice;      // Suggested entry (0 = market)
   double   stopLoss;        // Suggested SL price
   double   tp1;             // First take profit
   double   tp2;             // Second take profit
   int      confluence;      // Number of confirming conditions
   string   reason;          // Human-readable log reason
   // Signal conditions captured for Adaptive Journal + Guardian
   int      ofScore;         // Raw order flow score
   int      vpBias;          // Volume profile bias vote
   int      orbSig;          // ORB signal vote
   bool     absorption;      // Absorption detected on signal bar
   int      exhaustion;      // Exhaustion level
   int      deltaDiv;        // Delta divergence
   double   atr;             // ATR at time of signal
   double   slDist;          // SL distance in price (for Guardian spawn)
   double   tp1Dist;         // TP1 distance in price (for Guardian spawn)
};

//--------------------------------------------------------------------
//  Score confluence of VP signals
//  Returns +1/−1/0 based on price relative to profile levels
//--------------------------------------------------------------------
int VPBias(const VolumeProfile &vp, double price, double atr)
{
   if(!vp.isValid) return 0;
   int score = 0;

   // Price at or below VAL → bullish
   if(price <= vp.val + atr * 0.3) score++;
   // Price at or above VAH → bearish
   if(price >= vp.vah - atr * 0.3) score--;
   // Price at POC (neutral / reload zone)
   if(MathAbs(price - vp.poc) < atr * 0.2) score = 0;

   // Price above VAH (imbalance up) → potential breakout long
   if(price > vp.vah + atr * 0.1) score++;
   // Price below VAL (imbalance down) → potential breakout short
   if(price < vp.val - atr * 0.1) score--;

   return MathMax(-2, MathMin(2, score));
}

//--------------------------------------------------------------------
//  Build an EntrySignal by aggregating all strategy layers
//--------------------------------------------------------------------
EntrySignal EvaluateEntry(string symbol, ENUM_TIMEFRAMES tf,
                          const VolumeProfile &vp, const OpeningRange &orb,
                          double riskPct, double slATRMultiple)
{
   EntrySignal sig;
   sig.direction  = 0;
   sig.entryPrice = 0;
   sig.stopLoss   = 0;
   sig.tp1        = 0;
   sig.tp2        = 0;
   sig.confluence = 0;
   sig.reason     = "";
   sig.ofScore    = 0;
   sig.vpBias     = 0;
   sig.orbSig     = 0;
   sig.absorption = false;
   sig.exhaustion = 0;
   sig.deltaDiv   = 0;
   sig.atr        = 0;
   sig.slDist     = 0;
   sig.tp1Dist    = 0;

   double atr   = CalcATR(symbol, tf);
   double price = iClose(symbol, tf, 1);   // bar 1 = last CLOSED bar, avoids look-ahead bias
   double pts   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits= (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(g_debugMode) DBG(StringFormat("  ATR=%.5f | Price(bar1)=%.5f", atr, price));

   if(atr <= 0)
   {
      DBG("  ATR=0 — cannot evaluate, skipping bar");
      return sig;
   }

   // ---------------------------------------------------------------
   // 1. Order Flow Score
   // ---------------------------------------------------------------
   int ofScore = GetOrderFlowScore(symbol, tf);
   if(g_debugMode)
      DBG(StringFormat("  [OF ] OrderFlow score=%+d  (long needs >%d, short needs <%d)",
                        ofScore, SIG_MIN_OF_SCORE - 1, -(SIG_MIN_OF_SCORE - 1)));

   // ---------------------------------------------------------------
   // 2. Volume Profile bias
   // ---------------------------------------------------------------
   int vpBias = VPBias(vp, price, atr);
   if(g_debugMode)
   {
      string vpStr = vp.isValid
         ? StringFormat("POC=%.5f VAH=%.5f VAL=%.5f", vp.poc, vp.vah, vp.val)
         : "VP not valid";
      DBG(StringFormat("  [VP ] Bias=%+d | %s", vpBias, vpStr));
   }

   // ---------------------------------------------------------------
   // 3. ORB signal: either breakout or mean-reversion
   // ---------------------------------------------------------------
   int orbSignal = 0;
   if(orb.isFormed)
   {
      if(orb.breakoutUp)   orbSignal =  1;
      if(orb.breakoutDown) orbSignal = -1;
      if(orbSignal == 0)
         orbSignal = CheckORBMeanReversion(orb, price);
   }
   if(g_debugMode)
      DBG(StringFormat("  [ORB] Signal=%+d | Formed=%s BrkUp=%s BrkDn=%s | Hi=%.5f Lo=%.5f",
                        orbSignal,
                        orb.isFormed      ? "Y" : "N",
                        orb.breakoutUp    ? "Y" : "N",
                        orb.breakoutDown  ? "Y" : "N",
                        orb.high, orb.low));

   // ---------------------------------------------------------------
   // 4. Absorption at current bar
   // ---------------------------------------------------------------
   int absDir = 0;
   bool hasAbsorption = IsAbsorption(symbol, tf, 1, absDir);
   if(g_debugMode)
      DBG(StringFormat("  [ABS] Absorption=%s dir=%+d",
                        hasAbsorption ? "YES" : "no", absDir));

   // ---------------------------------------------------------------
   // 5. Exhaustion — acts as a FILTER (blocks entry in that direction)
   // ---------------------------------------------------------------
   int exhaustion = IsExhaustion(symbol, tf);
   if(g_debugMode)
      DBG(StringFormat("  [EXH] Exhaustion=%+d %s",
                        exhaustion,
                        exhaustion == 0 ? "(none)" :
                        exhaustion > 0  ? "(upside exhaustion — would block LONG)" :
                                          "(downside exhaustion — would block SHORT)"));

   // ---------------------------------------------------------------
   // 6. Delta divergence
   // ---------------------------------------------------------------
   int deltaDivergence = CalcDeltaDivergence(symbol, tf);
   if(g_debugMode)
      DBG(StringFormat("  [DDV] DeltaDivergence=%+d %s",
                        deltaDivergence,
                        deltaDivergence == 0 ? "(neutral)" :
                        deltaDivergence > 0  ? "(hidden bullish pressure)" :
                                               "(hidden bearish pressure)"));

   // ---------------------------------------------------------------
   // Aggregate direction vote
   // ---------------------------------------------------------------
   int longVotes  = 0;
   int shortVotes = 0;

   if(ofScore >  SIG_MIN_OF_SCORE - 1) longVotes  += (ofScore >  1 ? 2 : 1);
   if(ofScore < -SIG_MIN_OF_SCORE + 1) shortVotes += (-ofScore > 1 ? 2 : 1);

   if(vpBias >  0) longVotes++;
   if(vpBias <  0) shortVotes++;

   if(orbSignal >  0) { longVotes++;  sig.reason += "ORB_Long "; }
   if(orbSignal <  0) { shortVotes++; sig.reason += "ORB_Short "; }

   if(hasAbsorption && absDir >  0) { longVotes++;  sig.reason += "Absorb_Bull "; }
   if(hasAbsorption && absDir <  0) { shortVotes++; sig.reason += "Absorb_Bear "; }

   if(deltaDivergence >  0) { longVotes++;  sig.reason += "DeltaDiv_Bull "; }
   if(deltaDivergence <  0) { shortVotes++; sig.reason += "DeltaDiv_Bear "; }

   // Book sweep lowers conviction (thin liquidity — skip entry)
   bool bookSweep = IsBookSweep(symbol, tf, 1);
   if(g_debugMode)
      DBG(StringFormat("  [BSW] BookSweep=%s", bookSweep ? "YES — skipping entry" : "no"));
   if(bookSweep)
   {
      sig.reason += "BookSweep_Skip ";
      return sig;
   }

   // Exhaust filter: if exhaustion matches proposed direction → block
   int dominantDir = (longVotes > shortVotes) ? 1 : (shortVotes > longVotes) ? -1 : 0;
   if(g_debugMode)
      DBG(StringFormat("  VOTES → Long=%d  Short=%d | Dominant=%s",
                        longVotes, shortVotes,
                        dominantDir > 0 ? "LONG" : dominantDir < 0 ? "SHORT" : "FLAT/TIE"));

   if(exhaustion != 0 && exhaustion == dominantDir)
   {
      if(g_debugMode)
         DBG(StringFormat("  Exhaustion (%+d) matches dominant direction → BLOCKED", exhaustion));
      sig.reason += "Exhaustion_Block ";
      return sig;
   }

   // ---------------------------------------------------------------
   // Minimum confluence gate
   // ---------------------------------------------------------------
   int confluence = (dominantDir > 0) ? longVotes : shortVotes;
   if(g_debugMode)
      DBG(StringFormat("  Confluence=%d (min gate=%d) — %s",
                        confluence, SIG_MIN_CONFLUENCE,
                        confluence >= SIG_MIN_CONFLUENCE ? "PASSES ✓" : "BELOW threshold → no signal"));
   if(confluence < SIG_MIN_CONFLUENCE) return sig;

   // ---------------------------------------------------------------
   // Build the signal
   // ---------------------------------------------------------------
   sig.direction  = dominantDir;
   sig.confluence = confluence;
   sig.entryPrice = (dominantDir > 0)
                     ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                     : SymbolInfoDouble(symbol, SYMBOL_BID);

   // Stop loss: ATR-based behind entry
   double slDist = slATRMultiple * atr;
   string slSource = "ATR";

   // Tighten SL if we have an ORB reference
   if(orb.isFormed && orb.breakoutUp && dominantDir > 0)
   {
      double orbSL = ORBInvalidationLevel(orb, 1, atr);
      double dist  = sig.entryPrice - orbSL;
      if(dist > 0 && dist < slDist) { slDist = dist; slSource = "ORB_invalidation"; }
   }
   else if(orb.isFormed && orb.breakoutDown && dominantDir < 0)
   {
      double orbSL = ORBInvalidationLevel(orb, -1, atr);
      double dist  = orbSL - sig.entryPrice;
      if(dist > 0 && dist < slDist) { slDist = dist; slSource = "ORB_invalidation"; }
   }

   if(dominantDir > 0)
   {
      sig.stopLoss = NormalizeDouble(sig.entryPrice - slDist, digits);
      sig.tp1      = NormalizeDouble(sig.entryPrice + slDist * 1.5, digits);
      sig.tp2      = NormalizeDouble(sig.entryPrice + slDist * 3.0, digits);
   }
   else
   {
      sig.stopLoss = NormalizeDouble(sig.entryPrice + slDist, digits);
      sig.tp1      = NormalizeDouble(sig.entryPrice - slDist * 1.5, digits);
      sig.tp2      = NormalizeDouble(sig.entryPrice - slDist * 3.0, digits);
   }

   // ORB has its own targets — override if ORB signal dominated
   if(orb.isFormed && (orb.breakoutUp || orb.breakoutDown) && orbSignal == dominantDir)
   {
      double orbTP1, orbTP2;
      ORBProfitTargets(orb, dominantDir, orbTP1, orbTP2);
      sig.tp1 = NormalizeDouble(orbTP1, digits);
      sig.tp2 = NormalizeDouble(orbTP2, digits);
      if(g_debugMode) DBG("  TP targets overridden by ORB projection");
   }

   if(g_debugMode)
      DBG(StringFormat("  → SIGNAL: %s | Conf=%d | Entry=%.5f SL=%.5f (dist=%.5f via %s) TP1=%.5f TP2=%.5f | [%s]",
                        dominantDir > 0 ? "LONG ▲" : "SHORT ▼",
                        confluence,
                        sig.entryPrice, sig.stopLoss, slDist, slSource,
                        sig.tp1, sig.tp2, sig.reason));

   // ---- Populate signal snapshot fields for Adaptive Journal & Guardian ----
   sig.ofScore    = ofScore;
   sig.vpBias     = vpBias;
   sig.orbSig     = orbSignal;
   sig.absorption = hasAbsorption;
   sig.exhaustion = exhaustion;
   sig.deltaDiv   = deltaDivergence;
   sig.atr        = atr;
   sig.slDist     = slDist;
   sig.tp1Dist    = MathAbs(sig.tp1 - sig.entryPrice);

   return sig;
}

//--------------------------------------------------------------------
//  Place a trade from an EntrySignal
//  Returns deal ticket number or 0 on failure
//--------------------------------------------------------------------
ulong PlaceTrade(CTrade &trade, const EntrySignal &sig,
                 string symbol, double riskPct,
                 ulong magic, string comment = "ScalperEA")
{
   if(sig.direction == 0 || sig.stopLoss == 0) return 0;

   double slPoints = MathAbs(sig.entryPrice - sig.stopLoss);
   if(slPoints <= 0) return 0;

   double lots = CalcLotSize(symbol, riskPct, slPoints);
   if(lots <= 0) return 0;

   if(g_debugMode)
      DBG(StringFormat("PlaceTrade: %s %.2f lots | Entry=%.5f  SL=%.5f  TP1=%.5f  TP2=%.5f | SL=%.1f pts | Risk=%.2f%%",
                        sig.direction > 0 ? "BUY" : "SELL", lots,
                        sig.entryPrice, sig.stopLoss, sig.tp1, sig.tp2,
                        slPoints / SymbolInfoDouble(symbol, SYMBOL_POINT),
                        riskPct * 100.0));

   trade.SetExpertMagicNumber(magic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   bool ok = false;
   if(sig.direction > 0)
      ok = trade.Buy(lots, symbol, 0, sig.stopLoss, sig.tp1, comment);
   else
      ok = trade.Sell(lots, symbol, 0, sig.stopLoss, sig.tp1, comment);

   if(!ok)
   {
      Print(StringFormat("ScalperEA: Order FAILED retcode=%d: %s",
                          trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      return 0;
   }

   if(g_debugMode)
      DBG(StringFormat("PlaceTrade: ORDER SENT OK → Deal #%I64u  Price=%.5f",
                        trade.ResultDeal(), trade.ResultPrice()));

   return trade.ResultDeal();
}

//--------------------------------------------------------------------
//  Manage all open positions for a symbol (BE, trail, partial close)
//--------------------------------------------------------------------
void ManagePositions(CTrade &trade, CPositionInfo &pos,
                     string symbol, ulong magic,
                     ENUM_TIMEFRAMES tf,
                     double beATRMult, double trailATRMult,
                     double tp1ATRMult, bool &tp1DoneMap[])
{
   int idx = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      bool   isBuy     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double curPrice  = isBuy ? SymbolInfoDouble(symbol, SYMBOL_BID)
                               : SymbolInfoDouble(symbol, SYMBOL_ASK);
      double atr   = CalcATR(symbol, tf);
      double profit= PositionGetDouble(POSITION_PROFIT);
      double pts   = SymbolInfoDouble(symbol, SYMBOL_POINT);

      if(g_debugMode)
      {
         double pipFactor = (SymbolInfoInteger(symbol, SYMBOL_DIGITS) % 2 == 1) ? 10.0 : 1.0;
         double floatPips = (isBuy ? curPrice - openPrice : openPrice - curPrice)
                            / (pts * pipFactor);
         DBG(StringFormat("  [Pos #%I64u] %s | Open=%.5f  Cur=%.5f  SL=%.5f  TP=%.5f | "
                           "ATR=%.5f | Vol=%.2f | P&L=%.2f (%.1f pips)",
                           ticket, isBuy ? "BUY" : "SELL",
                           openPrice, curPrice, curSL, curTP,
                           atr, volume, profit, floatPips));
      }

      // ---- Move to break-even ----
      double slBefore = PositionGetDouble(POSITION_SL);
      MoveToBreakEven(trade, pos, ticket, beATRMult, symbol, tf);
      if(g_debugMode)
      {
         // Re-select to check if SL changed
         if(PositionSelectByTicket(ticket))
         {
            double slAfter = PositionGetDouble(POSITION_SL);
            if(MathAbs(slAfter - slBefore) > pts * 0.5)
               DBG(StringFormat("    BE: SL moved %.5f → %.5f (BE triggered ✓)", slBefore, slAfter));
            else
               DBG(StringFormat("    BE: not triggered yet (need %.1f ATR profit, have %.5f move)",
                                  beATRMult, MathAbs(curPrice - openPrice)));
         }
      }

      // ---- Partial close at TP1 (once per position) ----
      bool tp1Done = (idx < ArraySize(tp1DoneMap)) ? tp1DoneMap[idx] : false;
      if(!tp1Done)
      {
         double tp1Threshold = openPrice + (isBuy ? 1.0 : -1.0) * tp1ATRMult * atr * 1.4;
         bool   nearTP1      = isBuy ? (curPrice >= tp1Threshold)
                                     : (curPrice <= tp1Threshold);

         if(g_debugMode)
            DBG(StringFormat("    TP1: %s (need %.5f, cur %.5f)",
                               nearTP1    ? "TRIGGERED → partial close 50% ✓"
                                          : "not yet reached",
                               tp1Threshold, curPrice));

         if(nearTP1)
         {
            PartialClose(trade, pos, ticket, 0.5);
            if(idx < ArraySize(tp1DoneMap)) tp1DoneMap[idx] = true;
         }
      }
      else
      {
         if(g_debugMode) DBG("    TP1: already done — running on trail");
      }

      // ---- Trail stop for the runner ----
      double slBeforeTrail = PositionSelectByTicket(ticket)
                             ? PositionGetDouble(POSITION_SL) : curSL;
      TrailStop(trade, pos, ticket, trailATRMult, symbol, tf);
      if(g_debugMode && PositionSelectByTicket(ticket))
      {
         double slAfterTrail = PositionGetDouble(POSITION_SL);
         if(MathAbs(slAfterTrail - slBeforeTrail) > pts * 0.5)
            DBG(StringFormat("    Trail: SL moved %.5f → %.5f ✓", slBeforeTrail, slAfterTrail));
         else
            DBG(StringFormat("    Trail: no move (need price %.1f ATR away from SL)",
                               trailATRMult));
      }

      idx++;
   }
   if(g_debugMode && idx == 0)
      DBG("  No managed positions found for this symbol/magic");
}

#endif // TRADEMANAGER_MQH
