//+------------------------------------------------------------------+
//|                                              AI_Trader.mq5       |
//|                                    Copyright 2024, Aime AI      |
//|                                        https://www.aime.ai      |
//+------------------------------------------------------------------+
#property copyright "Aime AI"
#property version   "1.00"
#property description "AI Trading System with GPT Integration"

// شامل کردن کتابخانه‌های لازم
#include <Trade/Trade.mqh>
#include <JSON/JSON.mqh>

// پارامترهای ورودی
input string InpServerURL = "http://localhost:8000/signal";  // آدرس سرور
input int    InpRefreshSec = 900;                           // هر 15 دقیقه
input double InpRiskPerTrade = 1.0;                         // درصد ریسک
input int    InpATRPeriod = 14;                             // دوره ATR
input double InpMaxLot = 1.0;                               // حداکثر لات

// متغیرهای全局
CTrade Trade;
datetime LastCall = 0;
CJsonParser Parser;

//+------------------------------------------------------------------+
//| تابع مقداردهی اولیه                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("AI Trader EA Started");
    Print("Server URL: ", InpServerURL);
    
    // تنظیمات اولیه trade
    Trade.SetExpertMagicNumber(12345);
    Trade.SetDeviationInPoints(10);
    
    // تست اتصال به سرور
    if(!IsConnected())
    {
        Print("No internet connection!");
        return(INIT_FAILED);
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| تابع پایان کار                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("AI Trader EA Stopped");
}

//+------------------------------------------------------------------+
//| محاسبه ATR                                                       |
//+------------------------------------------------------------------+
double GetATR(int period = 14)
{
    return iATR(_Symbol, PERIOD_CURRENT, period, 0);
}

//+------------------------------------------------------------------+
//| ساخت JSON برای ارسال به سرور                                     |
//+------------------------------------------------------------------+
string BuildJSON()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double price = (bid + ask) / 2.0;
    
    double atr = GetATR(InpATRPeriod);
    double rsi = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE, 0);
    
    CJsonObject json;
    json.AddString("symbol", _Symbol);
    json.AddString("timeframe", EnumToString(PERIOD_CURRENT));
    json.AddDouble("price", price);
    
    // اضافه کردن اندیکاتورها
    CJsonObject indicators;
    indicators.AddDouble("ATR", atr);
    indicators.AddDouble("RSI", rsi);
    indicators.AddDouble("BID", bid);
    indicators.AddDouble("ASK", ask);
    json.AddObject("indicators", indicators);
    
    // اضافه کردن پوزیشن‌های باز
    CJsonArray positions;
    int total = PositionsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetInteger(POSITION_MAGIC) == 12345 && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            CJsonObject pos;
            pos.AddLong("ticket", (long)ticket);
            pos.AddString("type", PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
            pos.AddDouble("volume", PositionGetDouble(POSITION_VOLUME));
            pos.AddDouble("open_price", PositionGetDouble(POSITION_PRICE_OPEN));
            pos.AddDouble("profit", PositionGetDouble(POSITION_PROFIT));
            positions.AddObject(pos);
        }
    }
    json.AddArray("positions", positions);
    
    string result = json.ToString();
    Print("Sending JSON: ", result);
    return result;
}

//+------------------------------------------------------------------+
//| محاسبه لات بر اساس ریسک                                         |
//+------------------------------------------------------------------+
double CalcLot(double sl_points)
{
    if(sl_points <= 0) return 0.01;
    
    double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_amount = account_balance * (InpRiskPerTrade / 100.0);
    
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double point_value = tick_value * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    double lot = risk_amount / (sl_points * point_value);
    
    // نرمال‌سازی لات
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    lot = MathMax(lot, min_lot);
    lot = MathMin(lot, InpMaxLot);
    lot = MathRound(lot / step_lot) * step_lot;
    
    return lot;
}

//+------------------------------------------------------------------+
//| تماس با سرور AI و دریافت سیگنال                                 |
//+------------------------------------------------------------------+
void CallAI()
{
    string headers = "Content-Type: application/json\r\n";
    char data[];
    char result[];
    string response = "";
    
    string json_data = BuildJSON();
    StringToCharArray(json_data, data);
    
    ResetLastError();
    int res = WebRequest("POST", InpServerURL, headers, 5000, data, result, headers);
    
    if(res == -1)
    {
        int error = GetLastError();
        Print("WebRequest failed. Error: ", error, " - ", ErrorDescription(error));
        
        // برای خطای 4060 (Allow WebRequest not checked)
        if(error == 4060)
            Print("Please add URL in Tools->Options->Expert Advisors->Allow WebRequest");
        return;
    }
    
    response = CharArrayToString(result);
    Print("AI Response: ", response);
    
    // پارس کردن پاسخ JSON
    CJsonParser parser;
    CJsonObject* json = parser.Parse(response);
    
    if(json == NULL)
    {
        Print("Failed to parse JSON response");
        return;
    }
    
    string action = json.GetString("action");
    double lot_ai = json.GetDouble("lot");
    string reason = json.GetString("reason");
    
    Print("AI Decision - Action: ", action, ", Lot: ", DoubleToString(lot_ai, 2), ", Reason: ", reason);
    
    if(action == "HOLD" || lot_ai <= 0.0)
    {
        Print("No trading action required");
        delete json;
        return;
    }
    
    // محاسبه پارامترهای معامله
    double atr = GetATR(InpATRPeriod);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double sl_points = (1.5 * atr) / point;
    
    double volume = MathMin(lot_ai, CalcLot(sl_points));
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    double sl, tp;
    
    if(action == "BUY")
    {
        sl = bid - (1.5 * atr);
        tp = bid + (1.5 * atr);
        
        if(Trade.Buy(volume, _Symbol, 0, sl, tp, "AI BUY Signal"))
            Print("BUY order executed. Lot: ", volume, ", SL: ", sl, ", TP: ", tp);
        else
            Print("BUY order failed. Error: ", Trade.ResultRetcodeDescription());
    }
    else if(action == "SELL")
    {
        sl = ask + (1.5 * atr);
        tp = ask - (1.5 * atr);
        
        if(Trade.Sell(volume, _Symbol, 0, sl, tp, "AI SELL Signal"))
            Print("SELL order executed. Lot: ", volume, ", SL: ", sl, ", TP: ", tp);
        else
            Print("SELL order failed. Error: ", Trade.ResultRetcodeDescription());
    }
    
    delete json;
}

//+------------------------------------------------------------------+
//| تابع اصلی OnTick                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime current_time = TimeCurrent();
    
    // بررسی آیا زمان تماس بعدی رسیده است
    if(current_time - LastCall < InpRefreshSec)
        return;
    
    LastCall = current_time;
    Print("Calling AI Server at: ", TimeToString(current_time));
    
    CallAI();
}

//+------------------------------------------------------------------+
//| بررسی اتصال اینترنت                                              |
//+------------------------------------------------------------------+
bool IsConnected()
{
    return TerminalInfoInteger(TERMINAL_CONNECTED);
}