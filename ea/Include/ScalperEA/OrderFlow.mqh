//+------------------------------------------------------------------+
//|  OrderFlow.mqh  —  Order Flow Analysis Module                    |
//|  Approximates delta, CVD, absorption, initiative, exhaustion      |
//|  using tick volume (forex proxy for real volume).                 |
//+------------------------------------------------------------------+
#ifndef ORDERFLOW_MQH
#define ORDERFLOW_MQH

//--- Constants
#define OF_BARS_LOOKBACK       100    // Bars used for averages
#define OF_CVD_PERIOD          20     // Bars for CVD rolling window
#define OF_ABSORPTION_VOL_MULT 1.5    // Volume multiple to flag high-vol
#define OF_BODY_RATIO_MAX      0.35   // Max body/range for absorption bar
#define OF_EXHAUST_BARS        3      // Bars to check exhaustion trend
#define OF_INITIATIVE_BARS     3      // Consecutive bars for initiative auction

//--------------------------------------------------------------------
//  Per-bar delta approximation
//  delta = volume * ((Close - Low) - (High - Close)) / (High - Low)
//  Positive → net buying pressure, Negative → net selling pressure
//--------------------------------------------------------------------
double CalcBarDelta(int bar, string symbol, ENUM_TIMEFRAMES tf)
{
   double hi   = iHigh(symbol, tf, bar);
   double lo   = iLow(symbol, tf, bar);
   double cl   = iClose(symbol, tf, bar);
   double vol  = (double)iTickVolume(symbol, tf, bar);
   double rng  = hi - lo;
   if(rng < 1e-10) return 0.0;
   double buyFrac  = (cl - lo) / rng;
   double sellFrac = (hi - cl) / rng;
   return vol * (buyFrac - sellFrac);
}

//--------------------------------------------------------------------
//  Average bar volume over [1..lookback]
//--------------------------------------------------------------------
double AvgVolume(string symbol, ENUM_TIMEFRAMES tf, int lookback = OF_BARS_LOOKBACK)
{
   double sum = 0;
   int lim = MathMin(lookback, iBars(symbol, tf) - 1);
   for(int i = 1; i <= lim; i++)
      sum += (double)iTickVolume(symbol, tf, i);
   return lim > 0 ? sum / lim : 0;
}

//--------------------------------------------------------------------
//  Cumulative Volume Delta (last N bars ending at bar=1)
//  Returns positive if buyers dominate, negative if sellers
//--------------------------------------------------------------------
double CalcCVD(string symbol, ENUM_TIMEFRAMES tf, int period = OF_CVD_PERIOD)
{
   double cvd = 0;
   int lim = MathMin(period, iBars(symbol, tf) - 1);
   for(int i = 1; i <= lim; i++)
      cvd += CalcBarDelta(i, symbol, tf);
   return cvd;
}

//--------------------------------------------------------------------
//  CVD slope: CVD(last half) vs CVD(first half) — rising or falling
//--------------------------------------------------------------------
double CalcCVDSlope(string symbol, ENUM_TIMEFRAMES tf, int period = OF_CVD_PERIOD)
{
   int half = period / 2;
   double cvd_recent = 0, cvd_old = 0;
   int lim = MathMin(period, iBars(symbol, tf) - 1);
   for(int i = 1; i <= half && i <= lim; i++)
      cvd_recent += CalcBarDelta(i, symbol, tf);
   for(int i = half + 1; i <= lim; i++)
      cvd_old += CalcBarDelta(i, symbol, tf);
   return cvd_recent - cvd_old;   // Positive = accelerating buy pressure
}

//--------------------------------------------------------------------
//  ABSORPTION DETECTION
//  High volume bar + small body (wicks absorbing aggression)
//  direction: +1 = bullish absorption (buyers defended), -1 = bearish
//--------------------------------------------------------------------
bool IsAbsorption(string symbol, ENUM_TIMEFRAMES tf, int bar, int &direction)
{
   direction = 0;
   double hi  = iHigh(symbol, tf, bar);
   double lo  = iLow(symbol, tf, bar);
   double op  = iOpen(symbol, tf, bar);
   double cl  = iClose(symbol, tf, bar);
   double vol = (double)iTickVolume(symbol, tf, bar);
   double avg = AvgVolume(symbol, tf);
   double rng = hi - lo;
   if(rng < 1e-10 || avg < 1e-10) return false;

   // Must be high volume
   if(vol < OF_ABSORPTION_VOL_MULT * avg) return false;

   // Body must be small relative to total range
   double body = MathAbs(cl - op);
   if(body / rng > OF_BODY_RATIO_MAX) return false;

   // Determine which side is absorbing
   double upperWick = hi - MathMax(op, cl);
   double lowerWick = MathMin(op, cl) - lo;

   if(lowerWick > upperWick && lowerWick > rng * 0.3)
      direction = 1;    // Sellers tried to push down, buyers absorbed
   else if(upperWick > lowerWick && upperWick > rng * 0.3)
      direction = -1;   // Buyers tried to push up, sellers absorbed
   else
      return false;

   return true;
}

//--------------------------------------------------------------------
//  INITIATIVE AUCTION DETECTION
//  N consecutive bars in the same direction with rising volume
//  Returns +1 = bullish initiative, -1 = bearish initiative, 0 = none
//--------------------------------------------------------------------
int IsInitiativeAuction(string symbol, ENUM_TIMEFRAMES tf, int barsCheck = OF_INITIATIVE_BARS)
{
   int lim = MathMin(barsCheck, iBars(symbol, tf) - 1);
   if(lim < 2) return 0;

   // Check direction of most recent bar
   double cl1 = iClose(symbol, tf, 1);
   double op1 = iOpen(symbol, tf, 1);
   int dir = (cl1 > op1) ? 1 : -1;

   double prevVol = (double)iTickVolume(symbol, tf, lim);
   bool volumeRising = true;

   for(int i = lim; i >= 1; i--)
   {
      double cl = iClose(symbol, tf, i);
      double op = iOpen(symbol, tf, i);
      int barDir = (cl > op) ? 1 : -1;
      double vol = (double)iTickVolume(symbol, tf, i);

      if(barDir != dir) return 0;          // Direction broken
      if(i < lim && vol < prevVol * 0.7)   // Volume should not collapse
         volumeRising = false;
      prevVol = vol;
   }
   return dir;
}

//--------------------------------------------------------------------
//  EXHAUSTION DETECTION
//  Price making new extreme but volume declining — momentum waning
//  Returns +1 = bullish exhaustion (short setup), -1 = bearish exhaustion (long)
//--------------------------------------------------------------------
int IsExhaustion(string symbol, ENUM_TIMEFRAMES tf, int barsCheck = OF_EXHAUST_BARS)
{
   int lim = MathMin(barsCheck, iBars(symbol, tf) - 1);
   if(lim < 2) return 0;

   double vol_recent = (double)iTickVolume(symbol, tf, 1);
   double vol_prev   = (double)iTickVolume(symbol, tf, lim);

   // Volume must be declining significantly
   if(vol_recent > vol_prev * 0.75) return 0;

   // Check if price is at new high
   double hi_recent = iHigh(symbol, tf, 1);
   double lo_recent = iLow(symbol, tf, 1);
   bool   newHigh   = true, newLow = true;

   for(int i = 2; i <= lim; i++)
   {
      if(iHigh(symbol, tf, i) >= hi_recent) newHigh = false;
      if(iLow(symbol, tf, i)  <= lo_recent) newLow  = false;
   }

   if(newHigh) return  1;   // Price at new high but volume dropping → bearish exhaustion
   if(newLow)  return -1;   // Price at new low but volume dropping → bullish exhaustion
   return 0;
}

//--------------------------------------------------------------------
//  BOOK SWEEPING DETECTION
//  Large price move relative to volume → thin liquidity, rapid sweep
//  Returns true if current bar shows a sweep characteristic
//--------------------------------------------------------------------
bool IsBookSweep(string symbol, ENUM_TIMEFRAMES tf, int bar = 1)
{
   double rng  = iHigh(symbol, tf, bar) - iLow(symbol, tf, bar);
   double vol  = (double)iTickVolume(symbol, tf, bar);
   double avgV = AvgVolume(symbol, tf);
   if(avgV < 1e-10 || vol < 1e-10) return false;

   // Compute average range
   double avgRng = 0;
   int lim = MathMin(OF_BARS_LOOKBACK, iBars(symbol, tf) - 1);
   for(int i = 1; i <= lim; i++)
      avgRng += iHigh(symbol, tf, i) - iLow(symbol, tf, i);
   if(lim > 0) avgRng /= lim;

   // Sweep: large range (>1.5x avg) with low relative volume (<0.7x avg)
   return (rng > avgRng * 1.5 && vol < avgV * 0.7);
}

//--------------------------------------------------------------------
//  DELTA DIVERGENCE (CVD vs Price)
//  Returns +1 if price falling but CVD rising (hidden buying → long)
//  Returns -1 if price rising but CVD falling (hidden selling → short)
//--------------------------------------------------------------------
int CalcDeltaDivergence(string symbol, ENUM_TIMEFRAMES tf, int period = 10)
{
   int lim = MathMin(period, iBars(symbol, tf) - 1);
   if(lim < 2) return 0;

   double price_start = iClose(symbol, tf, lim);
   double price_end   = iClose(symbol, tf, 1);
   double cvd_start   = 0, cvd_end = 0;

   // CVD at start (older end of window)
   for(int i = lim; i > lim / 2; i--)
      cvd_start += CalcBarDelta(i, symbol, tf);
   // CVD at end (recent end of window)
   for(int i = lim / 2; i >= 1; i--)
      cvd_end += CalcBarDelta(i, symbol, tf);

   bool priceUp  = price_end > price_start;
   bool cvdUp    = cvd_end   > cvd_start;

   if(!priceUp && cvdUp)  return  1;   // Bullish divergence
   if(priceUp  && !cvdUp) return -1;   // Bearish divergence
   return 0;
}

//--------------------------------------------------------------------
//  COMPOSITE ORDER FLOW SCORE
//  Returns a score from -3 to +3 combining all signals
//  +ve = bullish bias, -ve = bearish bias
//--------------------------------------------------------------------
int GetOrderFlowScore(string symbol, ENUM_TIMEFRAMES tf)
{
   int score = 0;

   // 1. Initiative auction
   int ia = IsInitiativeAuction(symbol, tf);
   score += ia;

   // 2. Absorption on bar 1
   int absDir = 0;
   if(IsAbsorption(symbol, tf, 1, absDir))
      score += absDir;

   // 3. CVD slope
   double slopeVal = CalcCVDSlope(symbol, tf);
   double avgV = AvgVolume(symbol, tf) * OF_CVD_PERIOD;
   if(avgV > 0)
   {
      if(slopeVal >  avgV * 0.05) score++;
      if(slopeVal < -avgV * 0.05) score--;
   }

   // 4. Delta divergence
   score += CalcDeltaDivergence(symbol, tf);

   // 5. Exhaustion penalizes the direction
   int ex = IsExhaustion(symbol, tf);
   score -= ex;   // Exhaustion to upside = subtract from bull score

   return MathMax(-3, MathMin(3, score));
}

#endif // ORDERFLOW_MQH
