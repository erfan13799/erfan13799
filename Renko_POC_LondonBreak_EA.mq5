//+------------------------------------------------------------------+
//| Expert Advisor: Renko + POC + London Break (Full Version)      |
//| Language:   MQL5                                                |
//| Author:     ChatGPT (rev)                                       |
//| Note:       Template EA – use on your own risk.                 |
//+------------------------------------------------------------------+
#property copyright "ChatGPT"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

//--- trading helper
CTrade trade;

//----------------- INPUTS -----------------
input bool   UseInternalRenko      = true;   // build renko boxes internally?
input double RenkoBoxATRFactor     = 0.25;   // BoxSize = ATR(14)*Factor
input int    ATRPeriod            = 14;

input bool   UseVolumeProfile      = true;   // use prev-day volume profile (POC)
input double ProfileTickSize       = 0.5;    // bucket size for profile (price)

input bool   UseDeltaVolume        = true;   // not implemented – placeholder
input int    LondonOpenHourGMT     = 8;      // London open (GMT)
input int    LondonWindowMin       = 120;    // minutes for initial range

input double ATR_SL_Multiplier     = 1.5;    // SL = ATR * Multiplier
input double RR_Target             = 2.0;    // Risk-Reward target
input double RiskPercent           = 1.0;    // % balance risk per trade

input bool   UseTrailing           = true;
input double TrailingStartRR       = 1.0;    // activate trailing after RR>=
input double TrailingStepPoints    = 50;     // not used – placeholder

input bool   AvoidNews             = true;   // disable trading during news
input string NewsDisableFrom       = "00:00"; // HH:MM GMT
input string NewsDisableTo         = "00:30";

input double MinBalanceForTrade    = 50.0;   // minimal balance to trade

// broker/order settings
input ENUM_ORDER_TYPE_FILLING FillingType  = ORDER_FILLING_FOK;
input ENUM_ORDER_TYPE_TIME    OrderTypeTime = ORDER_TIME_GTC;

//----------------- GLOBALS -----------------
double   BoxSizePoints      = 0;   // renko box size (points)
datetime lastProfileCalc    = 0;   // last POC calculation time
double   POC_price          = 0.0; // prev-day POC

// London session tracking
static   bool london_range_active   = false;
static   double london_high         = -1e9;
static   double london_low          = 1e9;
static   bool london_window_passed  = false;

//----------------- UTIL FUNCTIONS -----------------
// price -> points
int PriceToPoints(double price)
  {
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return(int)MathRound(price / pt);
  }

// calc ATR value (wrapper – keeps signature concise)
double ATR(string symbol,int timeframe,int period,int shift)
  {
   return iATR(symbol,timeframe,period,shift);
  }

// box size based on daily ATR
double CalculateBoxSize()
  {
   double atr = iATR(_Symbol,PERIOD_D1,ATRPeriod,0);
   if(atr<=0)
      atr = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); // fallback
   return NormalizeDouble(atr*RenkoBoxATRFactor,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
  }

// build previous day volume profile – returns POC
bool BuildVolumeProfilePrevDay(double &poc)
  {
   datetime now_gmt          = TimeGMT();
   datetime today_midnight   = now_gmt - (now_gmt % 86400);
   datetime day_start        = today_midnight - 86400;
   datetime day_end          = today_midnight - 1;

   int bars = iBars(_Symbol,PERIOD_M1);
   if(bars<2) return(false);

   // determine day high/low first
   double lowp  = 1e9;
   double highp = 0;
   for(int i=0;i<bars;i++)
     {
      datetime bt = iTime(_Symbol,PERIOD_M1,i);
      if(bt<day_start || bt>day_end) continue;
      double lo = iLow (_Symbol,PERIOD_M1,i);
      double hi = iHigh(_Symbol,PERIOD_M1,i);
      if(lo<lowp)  lowp  = lo;
      if(hi>highp) highp = hi;
     }
   if(lowp>=highp || lowp==1e9) return(false);

   int buckets = (int)MathCeil((highp-lowp)/ProfileTickSize)+3;
   if(buckets<=0) return(false);

   double vol[];
   ArrayResize(vol,buckets);
   ArrayInitialize(vol,0.0);

   // accumulate volume
   for(int i=0;i<bars;i++)
     {
      datetime bt = iTime(_Symbol,PERIOD_M1,i);
      if(bt<day_start || bt>day_end) continue;
      double close_price = iClose(_Symbol,PERIOD_M1,i);
      long   v          = (long)iVolume(_Symbol,PERIOD_M1,i);
      int idx = (int)((close_price - lowp)/ProfileTickSize);
      if(idx<0) idx=0;
      if(idx>=buckets) idx=buckets-1;
      vol[idx] += (double)v;
     }

   // find poc
   int    poc_idx = 0;
   double best    = -1;
   for(int i=0;i<buckets;i++)
     {
      if(vol[i]>best)
        {
         best    = vol[i];
         poc_idx = i;
        }
     }
   poc = lowp + poc_idx*ProfileTickSize + ProfileTickSize/2.0;
   return(true);
  }

// check news window
bool IsInNewsWindow()
  {
   if(!AvoidNews) return(false);

   int from_h = StringToInteger(StringSubstr(NewsDisableFrom,0,2));
   int from_m = StringToInteger(StringSubstr(NewsDisableFrom,3,2));
   int to_h   = StringToInteger(StringSubstr(NewsDisableTo,0,2));
   int to_m   = StringToInteger(StringSubstr(NewsDisableTo,3,2));

   int from_min = from_h*60 + from_m;
   int to_min   = to_h*60   + to_m;

   datetime now_gmt = TimeGMT();
   int now_min = TimeHour(now_gmt)*60 + TimeMinute(now_gmt);

   if(from_min<=to_min)
      return(now_min>=from_min && now_min<=to_min);
   else // window crosses midnight
      return(now_min>=from_min || now_min<=to_min);
  }

// lot calculation by SL size (points)
double CalcLotByRisk(double sl_points)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<MinBalanceForTrade || sl_points<=0) return(0.0);

   double risk_amount = balance*RiskPercent/100.0;

   double tick_value  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_size   = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_value<=0 || tick_size<=0) return(0.0);

   double value_per_lot_per_point = tick_value/tick_size;
   double lots = risk_amount/(sl_points*value_per_lot_per_point);

   // broker limits
   double minlot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxlot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(lots<minlot)  lots = 0.0;
   else             lots = MathFloor(lots/step)*step;
   if(lots>maxlot)  lots = maxlot;

   return(lots);
  }

// order placement helper
bool PlaceOrder(ENUM_ORDER_TYPE type,double lot,double sl,double tp)
  {
   if(lot<=0.0) return(false);

   trade.SetExpertMagicNumber(20250526);
   trade.SetDeviationInPoints(10);

   bool res=false;
   if(type==ORDER_TYPE_BUY)
      res = trade.Buy(lot,NULL,0.0,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits));
   else if(type==ORDER_TYPE_SELL)
      res = trade.Sell(lot,NULL,0.0,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits));

   if(!res)
     {
      Print("Order failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
      return(false);
     }
   return(true);
  }

// trailing management
void ManageTrailing()
  {
   if(!UseTrailing) return;

   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double atr   = iATR(_Symbol,PERIOD_D1,ATRPeriod,0);
   double sl_points = ATR_SL_Multiplier*atr/point;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl         = PositionGetDouble(POSITION_SL);
      double tp         = PositionGetDouble(POSITION_TP);
      double current_price = (ptype==POSITION_TYPE_BUY)?
                              SymbolInfoDouble(_Symbol,SYMBOL_BID):
                              SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double rr=0.0;
      if(ptype==POSITION_TYPE_BUY)
         rr = (current_price - open_price)/(open_price - sl);
      else
         rr = (open_price - current_price)/(sl - open_price);

      if(rr<TrailingStartRR) continue;

      double new_sl;
      if(ptype==POSITION_TYPE_BUY)
        {
         new_sl = open_price + (rr-0.5)*(open_price - sl);
         if(new_sl>sl)
            trade.PositionModify(ticket,NormalizeDouble(new_sl,_Digits),tp);
        }
      else
        {
         new_sl = open_price - (rr-0.5)*(sl - open_price);
         if(new_sl<sl)
            trade.PositionModify(ticket,NormalizeDouble(new_sl,_Digits),tp);
        }
     }
  }

// core – trade logic after London range break
void CheckAndTrade()
  {
   // 1. skip during news
   if(IsInNewsWindow())
     {
      return;
     }

   // 2. update POC every 30 minutes
   if(UseVolumeProfile && (TimeCurrent()-lastProfileCalc>1800))
     {
      double tmp_poc=0;
      if(BuildVolumeProfilePrevDay(tmp_poc))
        {
         POC_price      = tmp_poc;
         lastProfileCalc= TimeCurrent();
         PrintFormat("POC updated: %.5f",POC_price);
        }
     }

   // 3. box size (renko) – might be used later
   BoxSizePoints = CalculateBoxSize();

   // 4. London session timing (GMT)
   datetime now_gmt   = TimeGMT();
   datetime today_mid = now_gmt - (now_gmt%86400);
   datetime london_open  = today_mid + LondonOpenHourGMT*3600;
   datetime london_close = london_open + LondonWindowMin*60;

   // inside London initial range – record extremes
   if(TimeCurrent()>=london_open && TimeCurrent()<=london_close)
     {
      double cur_high = iHigh(_Symbol,PERIOD_M1,0);
      double cur_low  = iLow (_Symbol,PERIOD_M1,0);
      if(!london_range_active)
        {
         london_high = cur_high;
         london_low  = cur_low;
         london_range_active = true;
        }
      else
        {
         if(cur_high>london_high) london_high = cur_high;
         if(cur_low <london_low)  london_low  = cur_low;
        }
      london_window_passed=false;
      return; // wait until window ends
     }
   else if(TimeCurrent()>london_close && !london_window_passed && london_range_active)
     {
      london_window_passed = true; // range ready to use
     }

   // if range not defined yet – nothing to do
   if(!london_window_passed) return;

   //---------------- signal check ----------------
   // renko direction (very simplified placeholder)
   int    renko_dir  = 0; // +1 long, -1 short
   double renko_price= SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(UseInternalRenko)
     {
      double rc = iClose(_Symbol,PERIOD_M1,0);
      double ro = iOpen (_Symbol,PERIOD_M1,0);
      if(rc>ro)      renko_dir = 1;
      else if(rc<ro) renko_dir = -1;
      renko_price = rc;
     }
   else // assume chart already renko
     {
      double rclose = iClose(_Symbol,PERIOD_CURRENT,0);
      double ropen  = iOpen (_Symbol,PERIOD_CURRENT,0);
      if(rclose>ropen)      renko_dir = 1;
      else if(rclose<ropen) renko_dir = -1;
      renko_price = rclose;
     }

   double price = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   // BUY conditions
   if(renko_dir==1 && renko_price>london_high && (!UseVolumeProfile || price>POC_price))
     {
      double atr = iATR(_Symbol,PERIOD_D1,ATRPeriod,0);
      double sl  = renko_price - ATR_SL_Multiplier*atr;
      double tp  = renko_price + ATR_SL_Multiplier*atr*RR_Target;
      double sl_pts = (renko_price - sl)/SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      double lot = CalcLotByRisk(sl_pts);
      if(lot>0) PlaceOrder(ORDER_TYPE_BUY,lot,sl,tp);
     }

   // SELL conditions
   if(renko_dir==-1 && renko_price<london_low && (!UseVolumeProfile || price<POC_price))
     {
      double atr = iATR(_Symbol,PERIOD_D1,ATRPeriod,0);
      double sl  = renko_price + ATR_SL_Multiplier*atr;
      double tp  = renko_price - ATR_SL_Multiplier*atr*RR_Target;
      double sl_pts = (sl - renko_price)/SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      double lot = CalcLotByRisk(sl_pts);
      if(lot>0) PlaceOrder(ORDER_TYPE_SELL,lot,sl,tp);
     }
  }

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("EA Renko+POC+London initialised.");
   BoxSizePoints = CalculateBoxSize();
   EventSetTimer(60); // 60-second timer
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ManageTrailing();

   // keep profile refreshed (fallback when tick quiet)
   if(TimeCurrent()-lastProfileCalc>1800)
     {
      double tmp;
      if(BuildVolumeProfilePrevDay(tmp))
        {
         POC_price      = tmp;
         lastProfileCalc= TimeCurrent();
        }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CheckAndTrade();
  }

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+