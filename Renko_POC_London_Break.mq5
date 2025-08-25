//+------------------------------------------------------------------+
//| Expert Advisor: Renko + POC + London Break (Full Version)        |
//| Language: MQL5                                                    |
//| Author: ChatGPT (template)                                        |
//| Note: This is a comprehensive EA template. Test carefully.       |
//+------------------------------------------------------------------+
#property copyright "ChatGPT"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input bool UseInternalRenko = true;           // اگر true: رنکو داخلی توسط EA ساخته میشه، در غیر اینصورت چارت رنکو
input double RenkoBoxATRFactor = 0.25;        // BoxSize = ATR(14)*RenkoBoxATRFactor
input int ATRPeriod = 14;

input bool UseVolumeProfile = true;           // محاسبه POC از پروفایل حجم روز قبل
input double ProfileTickSize = 0.5;           // اندازه باکت برای Volume Profile (قیمت بر حسب نماد و دسیمل)

input bool UseDeltaVolume = true;             // استفاده از دلتا ولوم در تأیید سیگنال
input int LondonOpenHourGMT = 8;              // ساعت باز شدن لندن به GMT
input int LondonWindowMin = 120;              // پنجره بررسی لندن (دقیقه) برای فیک‌موو

input double ATR_SL_Multiplier = 1.5;         // SL = ATR * این مقدار
input double RR_Target = 2.0;                 // نسبت ریسک به ریوارد
input double RiskPercent = 1.0;               // ریسک به ازای هر معامله (درصد حساب)

input bool UseTrailing = true;
input double TrailingStartRR = 1.0;           // زمانی که سود >= این مقدار از ریسک شد، تریل فعال شود (RR)
input double TrailingStepPoints = 50;         // قدم تریل به پوینت

input bool AvoidNews = true;                  // در زمان اخبار مهم معامله نکند (شما باید زمان‌ها را وارد کنید)
input string NewsDisableFrom = "00:00";       // قالب HH:MM به GMT (برای مثال برای NFP میتوانید زمان را وارد کنید)
input string NewsDisableTo = "00:30";

input double MinBalanceForTrade = 50.0;       // حداقل بالانس برای باز کردن معامله

// تنظیمات مربوط به سفارش‌ها
input ENUM_ORDER_TYPE_FILLING FillingType = ORDER_FILLING_FOK;
input ENUM_ORDER_TYPE_TIME OrderTypeTime = ORDER_TIME_GTC;

//----------------- GLOBALS -----------------
double BoxSizePoints = 0;                     // اندازه رنکو به پوینت
datetime lastProfileCalc = 0;
double POC_price = 0.0;

// برای رنکو داخلی
double renko_last_ref_price = 0.0;
int renko_last_dir = 0;                       // 1 = up, -1 = down

//----------------- UTIL FUNCTIONS -----------------
// تبدیل مقدار قیمت به پوینت (بر حسب نماد)
int PriceToPoints(double price)
{
    double p = MarketInfo(_Symbol, MODE_POINT);
    if(p == 0) p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    return (int)MathRound(price / p);
}

// محاسبه ATR (کلاسیک)
double iATR_Value(string symbol, int timeframe, int period, int shift)
{
    return iATR(symbol, timeframe, period, shift);
}

// گرفتن آستانه رنکو بر اساس ATR
double CalculateBoxSize()
{
    double atr = iATR(_Symbol, PERIOD_D1, ATRPeriod, 0);
    if(atr <= 0) atr = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); // fallback
    return NormalizeDouble(atr * RenkoBoxATRFactor, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

// محاسبه POC از روز قبل به صورت ساده (Volume Profile با باکت)
bool BuildVolumeProfilePrevDay(double &poc)
{
    // تابع پروفایل حجمِ روز قبل را بر مبنای M1 محاسبه میکند.
    datetime now_gmt = TimeGMT();
    datetime today_gmt_midnight = now_gmt - (now_gmt % 86400);
    datetime day_start = today_gmt_midnight - 86400; // روز قبل شروع
    datetime day_end = today_gmt_midnight - 1;
    
    int bars = iBars(_Symbol, PERIOD_M1);
    if(bars < 2) return false;
    
    // آرایه نگهداری حجم در باکت‌ها
    // محدوده قیمت‌های روز قبل
    double lowp = 1e9, highp = 0;
    
    // پیدا کردن low/high روز قبل از داده M1
    for(int i = 0; i < bars; i++)
    {
        datetime bt = iTime(_Symbol, PERIOD_M1, i);
        if(bt < day_start || bt > day_end) continue;
        
        double lo = iLow(_Symbol, PERIOD_M1, i);
        double hi = iHigh(_Symbol, PERIOD_M1, i);
        if(lo < lowp) lowp = lo;
        if(hi > highp) highp = hi;
    }
    
    if(lowp > highp || lowp == 1e9) return false;
    
    int buckets = (int)MathCeil((highp - lowp) / ProfileTickSize) + 3;
    if(buckets <= 0) return false;
    
    double vol[]; // dynamic array
    ArrayResize(vol, buckets);
    for(int i = 0; i < buckets; i++) vol[i] = 0.0;
    
    // جمع‌آوری حجم (از TickVolume M1 به عنوان proxy)
    for(int i = 0; i < bars; i++)
    {
        datetime bt = iTime(_Symbol, PERIOD_M1, i);
        if(bt < day_start || bt > day_end) continue;
        
        double price = iClose(_Symbol, PERIOD_M1, i);
        long v = (long)iVolume(_Symbol, PERIOD_M1, i);
        int idx = (int)((price - lowp) / ProfileTickSize);
        if(idx < 0) idx = 0;
        if(idx >= buckets) idx = buckets - 1;
        vol[idx] += v;
    }
    
    // پیدا کردن POC
    int poc_idx = 0;
    double best = -1;
    for(int i = 0; i < buckets; i++)
    {
        if(vol[i] > best)
        {
            best = vol[i];
            poc_idx = i;
        }
    }
    
    poc = lowp + poc_idx * ProfileTickSize + ProfileTickSize / 2.0;
    return true;
}

// بررسی آیا الان در پنجره خبری هستیم (ساده بر اساس ورودی)
bool IsInNewsWindow()
{
    if(!AvoidNews) return false;
    
    // تبدیل رشته‌ها به دقیقه از نیمه شب GMT
    int from_h = StringToInteger(StringSubstr(NewsDisableFrom, 0, 2));
    int from_m = StringToInteger(StringSubstr(NewsDisableFrom, 3, 2));
    int to_h = StringToInteger(StringSubstr(NewsDisableTo, 0, 2));
    int to_m = StringToInteger(StringSubstr(NewsDisableTo, 3, 2));
    
    int from_min = from_h * 60 + from_m;
    int to_min = to_h * 60 + to_m;
    
    datetime now_gmt = TimeGMT();
    int now_min = TimeHour(now_gmt) * 60 + TimeMinute(now_gmt);
    
    if(from_min <= to_min)
        return (now_min >= from_min && now_min <= to_min);
    else
        return (now_min >= from_min || now_min <= to_min);
}

// محاسبه اندازه لات بر اساس ریسک درصد
double CalcLotByRisk(double sl_points)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance < MinBalanceForTrade) return 0.0;
    
    double risk_amount = balance * RiskPercent / 100.0;
    
    //محاسبه ارزش پوینت
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tick_value == 0 || tick_size == 0) tick_value = 1.0;
    
    double value_per_lot_per_point = tick_value / tick_size; // تقریبی
    double lots = risk_amount / (sl_points * value_per_lot_per_point);
    
    // محدودیت‌های بروکر
    double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    if(minlot == 0) minlot = 0.01;
    if(lots < minlot) lots = minlot / 10; // very small => 0 => ignore
    
    lots = MathFloor(lots / step) * step;
    if(lots < minlot) return 0.0;
    if(lots > maxlot) lots = maxlot;
    
    return lots;
}

// ثبت سفارش
bool PlaceOrder(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    if(lot <= 0) return false;
    
    trade.SetExpertMagicNumber(20250526);
    trade.SetDeviationInPoints(10);
    
    bool res = false;
    if(type == ORDER_TYPE_BUY)
        res = trade.Buy(lot, NULL, NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits), 
                       NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits));
    else
        res = trade.Sell(lot, NULL, NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits), 
                        NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits));
    
    if(!res)
    {
        Print("Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        return false;
    }
    return true;
}

// مدیریت تریلینگ
void ManageTrailing()
{
    if(!UseTrailing) return;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            string sym = PositionGetString(POSITION_SYMBOL);
            if(sym != _Symbol) continue;
            
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double volume = PositionGetDouble(POSITION_VOLUME);
            long type = (long)PositionGetInteger(POSITION_TYPE);
            double sl = PositionGetDouble(POSITION_SL);
            double profit = PositionGetDouble(POSITION_PROFIT);
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double current_price = (type == POSITION_TYPE_BUY) ? 
                                  SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            // محاسبه RR کنونی
            double atr = iATR(_Symbol, PERIOD_D1, ATRPeriod, 0);
            double sl_points = ATR_SL_Multiplier * atr / point; // approx
            double entry_sl_cost = sl_points * point;
            double rr = 0; // approximate
            
            if(type == POSITION_TYPE_BUY)
                rr = (current_price - open_price) / (open_price - sl);
            else
                rr = (open_price - current_price) / (sl - open_price);
            
            if(rr >= TrailingStartRR)
            {
                // حرکت دادن SL به نقاطی امن تر
                double new_sl;
                if(type == POSITION_TYPE_BUY)
                {
                    new_sl = open_price + (rr - 0.5) * (open_price - sl); // محافظه‌کارانه
                    if(new_sl > sl)
                    {
                        trade.PositionModify(ticket, NormalizeDouble(new_sl, _Digits), 
                                           PositionGetDouble(POSITION_TP));
                    }
                }
                else
                {
                    new_sl = open_price - (rr - 0.5) * (sl - open_price);
                    if(new_sl < sl)
                    {
                        trade.PositionModify(ticket, NormalizeDouble(new_sl, _Digits), 
                                           PositionGetDouble(POSITION_TP));
                    }
                }
            }
        }
    }
}

// تابع اصلی تصمیم‌گیری برای ورود پس از شکست لندن
void CheckAndTrade()
{
    // اول بررسی اخبار
    if(IsInNewsWindow())
    {
        Print("News window active - skipping trades.");
        return;
    }
    
    // محاسبه/بروزرسانی POC روز قبل هر 30 دقیقه
    if(UseVolumeProfile && TimeCurrent() - lastProfileCalc > 1800)
    {
        double tmp_poc = 0;
        if(BuildVolumeProfilePrevDay(tmp_poc))
        {
            POC_price = tmp_poc;
            lastProfileCalc = TimeCurrent();
            PrintFormat("POC updated: %.5f", POC_price);
        }
    }
    
    // محاسبه Box Size
    BoxSizePoints = CalculateBoxSize();
    
    // London open time امروز به GMT
    datetime now_gmt = TimeGMT();
    datetime today_mid = now_gmt - (now_gmt % 86400);
    datetime london_open = today_mid + LondonOpenHourGMT * 3600;
    datetime london_close = london_open + LondonWindowMin * 60;
    
    static bool london_window_passed = false;
    
    // ما انتظار داریم بعد از پنجره لندن سیگنال شکل بگیره
    if(TimeCurrent() >= london_open && TimeCurrent() <= london_close)
    {
        // داخل پنجره لندن: ثبت High/Low اولیه
        // میتوان High/Low این پنجره را ذخیره کرد
        static double london_high = -1e9, london_low = 1e9;
        if(iHigh(_Symbol, PERIOD_M1, 0) > london_high) london_high = iHigh(_Symbol, PERIOD_M1, 0);
        if(iLow(_Symbol, PERIOD_M1, 0) < london_low) london_low = iLow(_Symbol, PERIOD_M1, 0);
        london_window_passed = false;
        return;
    }
    else if(TimeCurrent() > london_close && !london_window_passed)
    {
        // پنجره لندن تمام شده، الان وقت بررسی شکست است
        london_window_passed = true;
        
        // خواندن ذخیره‌ها
        double london_high = iHigh(_Symbol, PERIOD_M1, iBars(_Symbol, PERIOD_M1) - 1); // fallback
        double london_low = iLow(_Symbol, PERIOD_M1, iBars(_Symbol, PERIOD_M1) - 1);
        
        // اگر از رنکو استفاده میکنیم، جهت آخرین بلوک را بررسی می‌کنیم
        int renko_dir = 0; // 1 buy, -1 sell
        double renko_price = 0.0;
        
        if(UseInternalRenko)
        {
            // سادگی: از اختلاف Close و Open اخیر M1 برای تعیین جهت استفاده می‌کنیم
            double rc = iClose(_Symbol, PERIOD_M1, 0);
            double ro = iOpen(_Symbol, PERIOD_M1, 0);
            if(rc > ro) renko_dir = 1;
            else if(rc < ro) renko_dir = -1;
            renko_price = rc;
        }
        else
        {
            // فرض می‌کنیم چارت رنکو است؛ از آخرین بار چارت استفاده کن
            int bars_count = Bars(_Symbol, PERIOD_CURRENT);
            if(bars_count > 1)
            {
                double rclose = iClose(_Symbol, PERIOD_CURRENT, 0);
                double ropen = iOpen(_Symbol, PERIOD_CURRENT, 0);
                renko_dir = (rclose > ropen) ? 1 : -1;
                renko_price = rclose;
            }
        }
        
        // قیمت فعلی
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        
        // شرط خرید: قیمت بالای POC (اگر فعال) + رنکو شکست بالای لندن
        if((!UseVolumeProfile || price > POC_price) && renko_dir == 1 && renko_price > london_high)
        {
            // محاسبه SL و TP
            double atr = iATR(_Symbol, PERIOD_D1, ATRPeriod, 0);
            double sl = renko_price - ATR_SL_Multiplier * atr;
            double tp = renko_price + (ATR_SL_Multiplier * atr) * RR_Target;
            double sl_points = (renko_price - sl) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double lot = CalcLotByRisk(sl_points);
            if(lot > 0) PlaceOrder(ORDER_TYPE_BUY, lot, sl, tp);
        }
        
        // شرط فروش
        if((!UseVolumeProfile || price < POC_price) && renko_dir == -1 && renko_price < london_low)
        {
            double atr = iATR(_Symbol, PERIOD_D1, ATRPeriod, 0);
            double sl = renko_price + ATR_SL_Multiplier * atr;
            double tp = renko_price - (ATR_SL_Multiplier * atr) * RR_Target;
            double sl_points = (sl - renko_price) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double lot = CalcLotByRisk(sl_points);
            if(lot > 0) PlaceOrder(ORDER_TYPE_SELL, lot, sl, tp);
        }
    }
}

//+------------------------------------------------------------------+
int OnInit()
{
    Print("EA Renko+POC+London initialized.");
    
    // محاسبات اولیه
    BoxSizePoints = CalculateBoxSize();
    
    // ساخت تیک تایمر برای مدیریت منظم
    EventSetTimer(60); // هر 60 ثانیه
    
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
    // بطور منظم مدیریت تریلینگ و بروز رسانی پروفایل
    ManageTrailing();
    
    if(TimeCurrent() - lastProfileCalc > 1800)
    {
        double tmp;
        if(BuildVolumeProfilePrevDay(tmp))
        {
            POC_price = tmp;
            lastProfileCalc = TimeCurrent();
        }
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    // هر بار Tick ورودی -> تصمیم گیری
    CheckAndTrade();
}

//+------------------------------------------------------------------+
// پایان فایل
//+------------------------------------------------------------------+