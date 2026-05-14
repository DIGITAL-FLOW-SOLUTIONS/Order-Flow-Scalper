//+------------------------------------------------------------------+
//|  ORB.mqh  —  Opening Range Breakout Module                       |
//|  Defines the NY session opening range (first N minutes) and       |
//|  detects confirmed breakouts with order flow validation.          |
//+------------------------------------------------------------------+
#pragma once

//--------------------------------------------------------------------
//  Opening Range Structure
//--------------------------------------------------------------------
struct OpeningRange
{
   double   high;          // Opening range high
   double   low;           // Opening range low
   double   mid;           // Mid-point of the range
   double   poc;           // Volume POC inside the range
   datetime startTime;     // Range start timestamp
   datetime endTime;       // Range end timestamp
   bool     isFormed;      // Range fully formed for today
   bool     breakoutUp;    // Confirmed upside breakout
   bool     breakoutDown;  // Confirmed downside breakout
   double   breakoutLevel; // Price level at breakout
   int      breakoutBar;   // Bar index of breakout
};

//--------------------------------------------------------------------
//  Reset opening range for a new session
//--------------------------------------------------------------------
void ResetOpeningRange(OpeningRange &orb)
{
   orb.high          =  0;
   orb.low           =  0;
   orb.mid           =  0;
   orb.poc           =  0;
   orb.startTime     =  0;
   orb.endTime       =  0;
   orb.isFormed      = false;
   orb.breakoutUp    = false;
   orb.breakoutDown  = false;
   orb.breakoutLevel =  0;
   orb.breakoutBar   = -1;
}

//--------------------------------------------------------------------
//  Build / update the opening range
//  nyOpenHour:    GMT hour of NY session open (default 13 = 9 AM EST)
//  orbMinutes:    Length of opening range in minutes (15 or 30)
//
//  Call on every new bar. Returns true when range is freshly formed.
//--------------------------------------------------------------------
bool UpdateOpeningRange(OpeningRange &orb, string symbol, ENUM_TIMEFRAMES tf,
                        int nyOpenHour = 13, int orbMinutes = 30)
{
   MqlDateTime dt;
   datetime now = iTime(symbol, tf, 0);
   TimeToStruct(now, dt);

   // Check if we're in a new trading day (reset range)
   if(orb.isFormed)
   {
      MqlDateTime orbDay;
      TimeToStruct(orb.startTime, orbDay);
      if(orbDay.day != dt.day || orbDay.mon != dt.mon)
         ResetOpeningRange(orb);
   }

   if(orb.isFormed) return false;   // Already built for today

   // Find the opening range bar boundaries
   int bars = iBars(symbol, tf);
   int tfMins = (int)(PeriodSeconds(tf) / 60);
   if(tfMins <= 0) tfMins = 1;

   datetime sessionStart = 0;
   datetime sessionEnd   = 0;

   // Scan back to find today's NY open bar
   for(int i = 1; i < MathMin(bars, 500); i++)
   {
      datetime bt = iTime(symbol, tf, i);
      MqlDateTime bdt;
      TimeToStruct(bt, bdt);

      if(bdt.hour == nyOpenHour && bdt.min < tfMins)
      {
         // Check it's the same day as current bar
         MqlDateTime cdt;
         TimeToStruct(now, cdt);
         if(bdt.day == cdt.day && bdt.mon == cdt.mon && bdt.year == cdt.year)
         {
            sessionStart = bt;
            break;
         }
      }
   }

   if(sessionStart == 0) return false;   // NY open not found yet

   sessionEnd = sessionStart + orbMinutes * 60;

   // Check if ORB period has elapsed
   if(now < sessionEnd) return false;

   // Build opening range from bars within [sessionStart, sessionEnd)
   orb.high      = -DBL_MAX;
   orb.low       =  DBL_MAX;
   double totalVol = 0, weightedPrice = 0;
   int   orbBars = 0;

   for(int i = 1; i < MathMin(bars, 500); i++)
   {
      datetime bt = iTime(symbol, tf, i);
      if(bt < sessionStart || bt >= sessionEnd) continue;

      double hi  = iHigh(symbol, tf, i);
      double lo  = iLow(symbol, tf, i);
      double vol = (double)iTickVolume(symbol, tf, i);
      double mid = (hi + lo) / 2.0;

      if(hi > orb.high) orb.high = hi;
      if(lo < orb.low)  orb.low  = lo;
      totalVol       += vol;
      weightedPrice  += vol * mid;
      orbBars++;
   }

   if(orbBars == 0 || orb.high <= orb.low) return false;

   orb.mid       = (orb.high + orb.low) / 2.0;
   orb.poc       = (totalVol > 0) ? weightedPrice / totalVol : orb.mid;
   orb.startTime = sessionStart;
   orb.endTime   = sessionEnd;
   orb.isFormed  = true;

   return true;   // Range just formed
}

//--------------------------------------------------------------------
//  Check for ORB breakout on the current bar
//  Requires a close beyond the range + above-average volume
//  Returns: +1 = bullish breakout, -1 = bearish breakout, 0 = none
//--------------------------------------------------------------------
int CheckORBBreakout(OpeningRange &orb, string symbol, ENUM_TIMEFRAMES tf,
                     double volMultiplier = 1.2)
{
   if(!orb.isFormed)           return 0;
   if(orb.breakoutUp || orb.breakoutDown) return 0;  // Already triggered

   double cl  = iClose(symbol, tf, 1);
   double vol = (double)iTickVolume(symbol, tf, 1);

   // Average volume for last 20 bars
   double avgVol = 0;
   int lim = MathMin(20, iBars(symbol, tf) - 1);
   for(int i = 2; i <= lim; i++)
      avgVol += (double)iTickVolume(symbol, tf, i);
   if(lim > 1) avgVol /= (lim - 1);

   bool volConfirm = (vol >= avgVol * volMultiplier);

   if(cl > orb.high && volConfirm)
   {
      orb.breakoutUp    = true;
      orb.breakoutLevel = orb.high;
      orb.breakoutBar   = 1;
      return 1;
   }
   if(cl < orb.low && volConfirm)
   {
      orb.breakoutDown  = true;
      orb.breakoutLevel = orb.low;
      orb.breakoutBar   = 1;
      return -1;
   }
   return 0;
}

//--------------------------------------------------------------------
//  Mean reversion setup within the ORB range
//  Returns +1 if near VAL/low with bullish OF, -1 if near VAH/high with bearish OF
//--------------------------------------------------------------------
int CheckORBMeanReversion(const OpeningRange &orb, double currentPrice,
                          double proximity = 0.2)
{
   if(!orb.isFormed) return 0;

   double rng = orb.high - orb.low;
   if(rng <= 0) return 0;

   // Near the bottom of the range
   if(currentPrice <= orb.low + rng * proximity) return 1;

   // Near the top of the range
   if(currentPrice >= orb.high - rng * proximity) return -1;

   return 0;
}

//--------------------------------------------------------------------
//  Calculate invalidation level for a breakout trade
//  For a long breakout: SL below POC or ORB mid
//  For a short breakout: SL above POC or ORB mid
//--------------------------------------------------------------------
double ORBInvalidationLevel(const OpeningRange &orb, int direction, double atr)
{
   if(!orb.isFormed) return 0;
   if(direction > 0) return MathMin(orb.low, orb.poc) - atr * 0.3;
   if(direction < 0) return MathMax(orb.high, orb.poc) + atr * 0.3;
   return 0;
}

//--------------------------------------------------------------------
//  Compute first profit target from a breakout (TP1 and TP2)
//  Based on ORB range projection
//--------------------------------------------------------------------
void ORBProfitTargets(const OpeningRange &orb, int direction,
                      double &tp1, double &tp2)
{
   double rng = orb.high - orb.low;
   if(direction > 0)
   {
      tp1 = orb.high + rng * 1.0;    // 1× range extension
      tp2 = orb.high + rng * 2.0;    // 2× range extension
   }
   else
   {
      tp1 = orb.low - rng * 1.0;
      tp2 = orb.low - rng * 2.0;
   }
}
