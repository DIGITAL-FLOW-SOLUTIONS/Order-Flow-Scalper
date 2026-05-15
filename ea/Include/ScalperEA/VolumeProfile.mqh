//+------------------------------------------------------------------+
//|  VolumeProfile.mqh  —  Session Volume Profile Module             |
//|  Calculates VAH, VAL, POC and LVNs from intraday tick volume.    |
//+------------------------------------------------------------------+
#ifndef VOLUMEPROFILE_MQH
#define VOLUMEPROFILE_MQH

#define VP_BINS        200     // Price bins for profile
#define VP_VALUE_PCT   0.70    // Value area covers 70% of session volume
#define VP_LVN_RATIO   0.30    // LVN = bin volume < 30% of POC volume
#define VP_MAX_LVNS    10      // Max LVNs to track

//--------------------------------------------------------------------
//  Volume Profile Structure
//--------------------------------------------------------------------
struct VolumeProfile
{
   double   priceMin;
   double   priceMax;
   double   binSize;
   double   bins[VP_BINS];     // Volume accumulated per bin
   double   poc;               // Point of Control (price)
   double   vah;               // Value Area High
   double   val;               // Value Area Low
   double   lvn[VP_MAX_LVNS];  // Low Volume Nodes
   int      lvnCount;
   double   totalVolume;
   bool     isValid;
};

//--------------------------------------------------------------------
//  Get bin index for a given price
//--------------------------------------------------------------------
int GetBinIndex(const VolumeProfile &vp, double price)
{
   if(vp.binSize <= 0) return -1;
   int idx = (int)((price - vp.priceMin) / vp.binSize);
   return MathMax(0, MathMin(VP_BINS - 1, idx));
}

//--------------------------------------------------------------------
//  Get bin mid-price from index
//--------------------------------------------------------------------
double GetBinPrice(const VolumeProfile &vp, int idx)
{
   return vp.priceMin + (idx + 0.5) * vp.binSize;
}

//--------------------------------------------------------------------
//  Build session volume profile
//  sessionStartBar: bar index where session began (older)
//  sessionEndBar:   bar index where session ends (0 = current bar)
//--------------------------------------------------------------------
void BuildVolumeProfile(VolumeProfile &vp, string symbol, ENUM_TIMEFRAMES tf,
                        int sessionStartBar, int sessionEndBar = 0)
{
   vp.isValid    = false;
   vp.lvnCount   = 0;
   vp.totalVolume = 0;
   ArrayInitialize(vp.bins, 0);
   ArrayInitialize(vp.lvn,  0);

   int bars = iBars(symbol, tf);
   if(sessionStartBar >= bars || sessionStartBar < sessionEndBar) return;

   // Find price range across session
   vp.priceMin =  DBL_MAX;
   vp.priceMax = -DBL_MAX;
   for(int i = sessionEndBar; i <= sessionStartBar; i++)
   {
      double hi = iHigh(symbol, tf, i);
      double lo = iLow(symbol, tf, i);
      if(hi > vp.priceMax) vp.priceMax = hi;
      if(lo < vp.priceMin) vp.priceMin = lo;
   }

   if(vp.priceMax <= vp.priceMin) return;

   vp.binSize = (vp.priceMax - vp.priceMin) / VP_BINS;
   if(vp.binSize < 1e-10) return;

   // Distribute volume across bins
   // Each bar's volume is split proportionally across the bar's range
   for(int i = sessionEndBar; i <= sessionStartBar; i++)
   {
      double hi  = iHigh(symbol, tf, i);
      double lo  = iLow(symbol, tf, i);
      double vol = (double)iTickVolume(symbol, tf, i);
      double rng = hi - lo;
      if(rng < vp.binSize) rng = vp.binSize;

      int binLo = GetBinIndex(vp, lo);
      int binHi = GetBinIndex(vp, hi);

      for(int b = binLo; b <= binHi; b++)
      {
         double bLo = vp.priceMin + b * vp.binSize;
         double bHi = bLo + vp.binSize;
         double overlap = MathMin(hi, bHi) - MathMax(lo, bLo);
         if(overlap < 0) overlap = 0;
         double frac = overlap / rng;
         vp.bins[b] += vol * frac;
         vp.totalVolume += vol * frac;
      }
   }

   // Find POC (bin with max volume)
   int pocBin = 0;
   double maxVol = 0;
   for(int b = 0; b < VP_BINS; b++)
   {
      if(vp.bins[b] > maxVol)
      {
         maxVol = vp.bins[b];
         pocBin = b;
      }
   }
   vp.poc = GetBinPrice(vp, pocBin);

   // Build value area (70% of volume centred on POC)
   double target   = vp.totalVolume * VP_VALUE_PCT;
   double accumulated = vp.bins[pocBin];
   int lo_ptr = pocBin, hi_ptr = pocBin;

   while(accumulated < target)
   {
      double addHi = (hi_ptr + 1 < VP_BINS) ? vp.bins[hi_ptr + 1] : 0;
      double addLo = (lo_ptr - 1 >= 0)      ? vp.bins[lo_ptr - 1] : 0;

      if(addHi >= addLo && hi_ptr + 1 < VP_BINS)
      {
         hi_ptr++;
         accumulated += vp.bins[hi_ptr];
      }
      else if(lo_ptr - 1 >= 0)
      {
         lo_ptr--;
         accumulated += vp.bins[lo_ptr];
      }
      else break;
   }
   vp.vah = vp.priceMin + (hi_ptr + 1) * vp.binSize;
   vp.val = vp.priceMin + lo_ptr       * vp.binSize;

   // Find LVNs (bins with volume < LVN_RATIO * POC volume)
   double lvnThreshold = maxVol * VP_LVN_RATIO;
   vp.lvnCount = 0;
   bool inLVN = false;
   double lvnLo = 0, lvnHi = 0;

   for(int b = 0; b < VP_BINS && vp.lvnCount < VP_MAX_LVNS; b++)
   {
      if(vp.bins[b] < lvnThreshold && vp.bins[b] > 0)
      {
         if(!inLVN) { inLVN = true; lvnLo = GetBinPrice(vp, b); }
         lvnHi = GetBinPrice(vp, b);
      }
      else if(inLVN)
      {
         vp.lvn[vp.lvnCount++] = (lvnLo + lvnHi) * 0.5;
         inLVN = false;
      }
   }
   if(inLVN && vp.lvnCount < VP_MAX_LVNS)
      vp.lvn[vp.lvnCount++] = (lvnLo + lvnHi) * 0.5;

   vp.isValid = true;
}

//--------------------------------------------------------------------
//  Return the nearest LVN to a given price (or 0 if none found)
//--------------------------------------------------------------------
double NearestLVN(const VolumeProfile &vp, double price, double maxDist)
{
   double best = 0, bestDist = maxDist;
   for(int i = 0; i < vp.lvnCount; i++)
   {
      double d = MathAbs(vp.lvn[i] - price);
      if(d < bestDist)
      {
         bestDist = d;
         best = vp.lvn[i];
      }
   }
   return best;
}

//--------------------------------------------------------------------
//  Price position relative to value area
//  Returns: +1 = above VAH (imbalance up), -1 = below VAL (imbalance down)
//           0 = inside value area (balance)
//--------------------------------------------------------------------
int PriceVsValueArea(const VolumeProfile &vp, double price)
{
   if(!vp.isValid) return 0;
   if(price > vp.vah) return  1;
   if(price < vp.val) return -1;
   return 0;
}

//--------------------------------------------------------------------
//  Distance from price to nearest key VP level (POC, VAH, VAL)
//  Returns the closest level price and fills levelType:
//  0=POC, 1=VAH, 2=VAL
//--------------------------------------------------------------------
double NearestVPLevel(const VolumeProfile &vp, double price, int &levelType)
{
   double dPOC = MathAbs(price - vp.poc);
   double dVAH = MathAbs(price - vp.vah);
   double dVAL = MathAbs(price - vp.val);

   if(dPOC <= dVAH && dPOC <= dVAL) { levelType = 0; return vp.poc; }
   if(dVAH <= dVAL)                 { levelType = 1; return vp.vah; }
   levelType = 2; return vp.val;
}

//--------------------------------------------------------------------
//  Find session start bar for a given GMT hour  (e.g. NY = 13)
//  Returns bar index of first bar in current session, or -1
//--------------------------------------------------------------------
int FindSessionStartBar(string symbol, ENUM_TIMEFRAMES tf, int sessionGMTHour)
{
   // Convert broker bar timestamps to GMT before hour comparison so this
   // function works correctly regardless of broker server timezone.
   int gmtOffset = (int)(TimeCurrent() - TimeGMT());
   int bars = iBars(symbol, tf);
   MqlDateTime dt;
   for(int i = 0; i < bars; i++)
   {
      datetime t    = iTime(symbol, tf, i);
      datetime tGMT = t - gmtOffset;
      TimeToStruct(tGMT, dt);
      if(dt.hour == sessionGMTHour && dt.min == 0) return i;
      // Also catch bars that span the hour
      if(dt.hour < sessionGMTHour && i > 0)
      {
         datetime tPrev    = iTime(symbol, tf, i - 1);
         datetime tPrevGMT = tPrev - gmtOffset;
         MqlDateTime dp;
         TimeToStruct(tPrevGMT, dp);
         if(dp.hour >= sessionGMTHour) return i - 1;
      }
   }
   return -1;
}

#endif // VOLUMEPROFILE_MQH
