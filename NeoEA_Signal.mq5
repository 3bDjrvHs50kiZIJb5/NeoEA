//+------------------------------------------------------------------+
//|                                              NeoEA_Signal.mq5    |
//|                         NeoEA 系 · 多品种机会信号面板             |
//+------------------------------------------------------------------+
#define Version "1.23"
#define EAName  "NeoEA_Signal"

#property copyright "NeoEA_Signal"
#property version   Version
#property strict

input int             FilterPairsNum = 1;   // 同品种持仓数>=此值时也隐藏(与持仓货币过滤叠加)
input ENUM_TIMEFRAMES TMVIEW         = PERIOD_W1;
input ENUM_TIMEFRAMES TMEXE          = PERIOD_H4;
input bool            InpOpenNewTab  = true;  // 品种按钮: 新标签页打开(否则切换当前图表)

int    n  = 1;
string EA;
string g_blockedCurrencies[];

// 图表对象名前缀(避免与其它 EA 冲突)
const string OBJ_BTN_LOT  = "NeoEA_Signal_LOT";
const string OBJ_BTN_BUY  = "NeoEA_Signal_BUY";
const string OBJ_BTN_SELL = "NeoEA_Signal_SELL";
const string OBJ_BTN_CLR  = "NeoEA_Signal_CLR";
const string OBJ_BG       = "NeoEA_Signal_BG";
const string OBJ_TITLE    = "NeoEA_Signal_Title";
const string OBJ_POS_PREF = "NeoEA_Pos_";

string g_cacheKey[];
int    g_cacheHandle[];

//+------------------------------------------------------------------+
void ReleaseIndicatorCache()
  {
   for(int i = 0; i < ArraySize(g_cacheHandle); i++)
     {
      if(g_cacheHandle[i] != INVALID_HANDLE)
         IndicatorRelease(g_cacheHandle[i]);
     }
   ArrayResize(g_cacheKey, 0);
   ArrayResize(g_cacheHandle, 0);
  }

//+------------------------------------------------------------------+
int FindCacheIndex(const string key)
  {
   for(int i = 0; i < ArraySize(g_cacheKey); i++)
     {
      if(g_cacheKey[i] == key)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
int GetCachedHandle(const string key, const bool isRsi,
                    const string symbol, const ENUM_TIMEFRAMES tf, const int period)
  {
   int idx = FindCacheIndex(key);

   if(idx >= 0 && g_cacheHandle[idx] != INVALID_HANDLE)
      return g_cacheHandle[idx];

   int handle = INVALID_HANDLE;
   if(isRsi)
      handle = iRSI(symbol, tf, period, PRICE_CLOSE);
   else
      handle = iMA(symbol, tf, period, 0, MODE_SMMA, PRICE_CLOSE);

   if(handle == INVALID_HANDLE)
      return INVALID_HANDLE;

   if(idx < 0)
     {
      int n = ArraySize(g_cacheKey);
      ArrayResize(g_cacheKey, n + 1);
      ArrayResize(g_cacheHandle, n + 1);
      g_cacheKey[n]     = key;
      g_cacheHandle[n]  = handle;
     }
   else
      g_cacheHandle[idx] = handle;

   return handle;
  }

//+------------------------------------------------------------------+
bool EnsureSymbolReady(const string symbol, const ENUM_TIMEFRAMES tf, const int minBars)
  {
   if(!SymbolInfoInteger(symbol, SYMBOL_EXIST))
      return false;

   SymbolSelect(symbol, true);

   if(SeriesInfoInteger(symbol, tf, SERIES_SYNCHRONIZED) == 0)
      return false;

   return (Bars(symbol, tf) >= minBars);
  }

//+------------------------------------------------------------------+
double GetStartLot()
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double earn      = (MathAbs(0.00230) / tickSize) * tickValue;
   double re        = AccountInfoDouble(ACCOUNT_BALANCE) / 500.0 / earn - 0.002;

   if(StringFind(_Symbol, "GBP") != -1 || StringFind(_Symbol, "XAU") != -1)
      re = 0.03;
   if(StringFind(_Symbol, "JPY") != -1)
      re = 0.01;

   return re;
  }

//+------------------------------------------------------------------+
string GetPeriodName()
  {
   switch(_Period)
     {
      case PERIOD_H4: return "H4";
      case PERIOD_W1: return "W";
      default:        return EnumToString(_Period);
     }
  }

//+------------------------------------------------------------------+
// 统计该品种全部持仓(不限 magic，含手动单与其它 EA)
int GetPositionExistNum(const string symbol)
  {
   string target = ResolveChartSymbol(symbol);
   int    count  = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(ResolveChartSymbol(PositionGetString(POSITION_SYMBOL)) != target)
         continue;
      count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
bool GetPairCurrencies(const string symbol, string &baseCcy, string &quoteCcy)
  {
   string sym = ResolveChartSymbol(symbol);
   if(StringLen(sym) < 6)
      return false;

   baseCcy  = StringSubstr(sym, 0, 3);
   quoteCcy = StringSubstr(sym, 3, 3);
   return true;
  }

//+------------------------------------------------------------------+
void AddBlockedCurrency(const string ccy)
  {
   for(int i = 0; i < ArraySize(g_blockedCurrencies); i++)
     {
      if(g_blockedCurrencies[i] == ccy)
         return;
     }

   int n = ArraySize(g_blockedCurrencies);
   ArrayResize(g_blockedCurrencies, n + 1);
   g_blockedCurrencies[n] = ccy;
  }

//+------------------------------------------------------------------+
// 从全部持仓提取涉及货币(如 AUDCAD -> AUD、CAD)
void RefreshBlockedCurrencies()
  {
   ArrayResize(g_blockedCurrencies, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string baseCcy, quoteCcy;
      if(!GetPairCurrencies(PositionGetString(POSITION_SYMBOL), baseCcy, quoteCcy))
         continue;

      AddBlockedCurrency(baseCcy);
      AddBlockedCurrency(quoteCcy);
     }
  }

//+------------------------------------------------------------------+
bool IsPairBlockedByHeldCurrencies(const string symbol)
  {
   string baseCcy, quoteCcy;
   if(!GetPairCurrencies(symbol, baseCcy, quoteCcy))
      return false;

   for(int i = 0; i < ArraySize(g_blockedCurrencies); i++)
     {
      if(g_blockedCurrencies[i] == baseCcy || g_blockedCurrencies[i] == quoteCcy)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
void ClearPositionPanelRows()
  {
   int total = ObjectsTotal(0, 0, -1);

   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, OBJ_POS_PREF) == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
double GetRSI(const string symbol, ENUM_TIMEFRAMES tf, int period, int shift = 0)
  {
   if(!EnsureSymbolReady(symbol, tf, period + 10))
      return 50.0;

   string key = symbol + "|RSI|" + IntegerToString((int)tf) + "|" + IntegerToString(period);
   int    handle = GetCachedHandle(key, true, symbol, tf, period);

   if(handle == INVALID_HANDLE)
      return 50.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
      return 50.0;

   return buf[0];
  }

//+------------------------------------------------------------------+
double GetMA(const string symbol, ENUM_TIMEFRAMES tf, int period, int shift = 0)
  {
   if(!EnsureSymbolReady(symbol, tf, period + 10))
      return 0.0;

   string key = symbol + "|MA|" + IntegerToString((int)tf) + "|" + IntegerToString(period);
   int    handle = GetCachedHandle(key, false, symbol, tf, period);

   if(handle == INVALID_HANDLE)
      return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
      return 0.0;

   return buf[0];
  }

//+------------------------------------------------------------------+
bool IsControlButton(const string name)
  {
   return (name == OBJ_BTN_LOT || name == OBJ_BTN_BUY ||
           name == OBJ_BTN_SELL || name == OBJ_BTN_CLR);
  }

//+------------------------------------------------------------------+
string ResolveChartSymbol(const string rawName)
  {
   string base = rawName;
   int    len  = StringLen(base);

   if(len > 0 && StringGetCharacter(base, len - 1) == '.')
      base = StringSubstr(base, 0, len - 1);

   if(SymbolInfoInteger(base, SYMBOL_EXIST))
     {
      SymbolSelect(base, true);
      return base;
     }

   for(int pass = 0; pass < 2; pass++)
     {
      bool selectedOnly = (pass == 0);
      int  total        = SymbolsTotal(selectedOnly);

      for(int i = 0; i < total; i++)
        {
         string sym = SymbolName(i, selectedOnly);
         if(StringFind(sym, base) == 0)
           {
            SymbolSelect(sym, true);
            return sym;
           }
        }
     }

   return base;
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
long FindChartBySymbolPeriod(const string symbol, const ENUM_TIMEFRAMES period)
  {
   long chartId = ChartFirst();

   while(chartId >= 0)
     {
      if(ChartSymbol(chartId) == symbol && (ENUM_TIMEFRAMES)ChartPeriod(chartId) == period)
         return chartId;
      chartId = ChartNext(chartId);
     }

   return -1;
  }

//+------------------------------------------------------------------+
void OpenSymbolPeriodChart(const string rawName, const ENUM_TIMEFRAMES period,
                           const bool openNewTab)
  {
   string sym = ResolveChartSymbol(rawName);

   if(!SymbolInfoInteger(sym, SYMBOL_EXIST))
     {
      Print("无法找到品种: ", rawName);
      return;
     }

   if(openNewTab)
     {
      long existing = FindChartBySymbolPeriod(sym, period);
      if(existing >= 0)
        {
         ChartSetInteger(existing, CHART_BRING_TO_TOP, true);
         Print("已激活已有图表: ", sym, " ", EnumToString(period));
         return;
        }

      long chartId = ChartOpen(sym, period);
      if(chartId == 0)
         Print("打开新标签页失败: ", sym, " ", EnumToString(period), " 错误=", GetLastError());
      else
         Print("新标签页: ", sym, " ", EnumToString(period));
      return;
     }

   if(!ChartSetSymbolPeriod(0, sym, period))
      Print("切换失败: ", sym, " ", EnumToString(period), " 错误=", GetLastError());
   else
     {
      ChartRedraw(0);
      Print("切换到: ", sym, " ", EnumToString(period));
     }
  }

//+------------------------------------------------------------------+
bool ParseTfTooltip(const string tooltip, string &symbol, ENUM_TIMEFRAMES &tf)
  {
   if(StringFind(tooltip, "TF|") != 0)
      return false;

   string parts[];
   if(StringSplit(tooltip, '|', parts) < 3)
      return false;

   symbol = parts[1];
   tf     = (ENUM_TIMEFRAMES)StringToInteger(parts[2]);
   return true;
  }

//+------------------------------------------------------------------+
void HighlightCurrentSymbolButtons()
  {
   int total = ObjectsTotal(0, 0, OBJ_BUTTON);

   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, OBJ_BUTTON);
      if(IsControlButton(name))
         continue;

      string sym = ObjectGetString(0, name, OBJPROP_TOOLTIP);
      if(sym == _Symbol)
         ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrGreenYellow);
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BG();

   ObjectCreate(0, OBJ_BTN_LOT, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, OBJ_BTN_LOT, OBJPROP_XDISTANCE, 500 + 180);
   ObjectSetInteger(0, OBJ_BTN_LOT, OBJPROP_YDISTANCE, 20);
   ObjectSetString(0, OBJ_BTN_LOT, OBJPROP_TEXT, "Lots:" + DoubleToString(GetStartLot(), 2));
   ObjectSetInteger(0, OBJ_BTN_LOT, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, OBJ_BTN_LOT, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, OBJ_BTN_LOT, OBJPROP_XSIZE, 70);

   ObjectCreate(0, OBJ_BTN_BUY, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_XDISTANCE, 500);
   ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_XSIZE, 70);

   double swapLong = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_LONG);
   if(swapLong > 0)
     {
      ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_BGCOLOR, clrChartreuse);
      ObjectSetString(0, OBJ_BTN_BUY, OBJPROP_TEXT, "BUY +" + DoubleToString(swapLong, 1));
     }
   else
     {
      ObjectSetInteger(0, OBJ_BTN_BUY, OBJPROP_BGCOLOR, clrLightSalmon);
      ObjectSetString(0, OBJ_BTN_BUY, OBJPROP_TEXT, "BUY " + DoubleToString(swapLong, 1));
     }

   ObjectCreate(0, OBJ_BTN_SELL, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_XDISTANCE, 500 + 90);
   ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_XSIZE, 70);

   double swapShort = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_SHORT);
   if(swapShort > 0)
     {
      ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_BGCOLOR, clrChartreuse);
      ObjectSetString(0, OBJ_BTN_SELL, OBJPROP_TEXT, "SELL +" + DoubleToString(swapShort, 1));
     }
   else
     {
      ObjectSetInteger(0, OBJ_BTN_SELL, OBJPROP_BGCOLOR, clrLightSalmon);
      ObjectSetString(0, OBJ_BTN_SELL, OBJPROP_TEXT, "SELL " + DoubleToString(swapShort, 1));
     }

   ObjectCreate(0, OBJ_BTN_CLR, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, OBJ_BTN_CLR, OBJPROP_XDISTANCE, 500 + 270);
   ObjectSetInteger(0, OBJ_BTN_CLR, OBJPROP_YDISTANCE, 20);
   ObjectSetString(0, OBJ_BTN_CLR, OBJPROP_TEXT, "CLR");
   ObjectSetInteger(0, OBJ_BTN_CLR, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, OBJ_BTN_CLR, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, OBJ_BTN_CLR, OBJPROP_XSIZE, 70);

   EA = EAName + " v" + Version + " " + _Symbol + " " + GetPeriodName();
   label(OBJ_TITLE, EA, 50, 10, 5);

   PreloadOpportunitySymbols();

   EventSetTimer(1);
   UpdatePanel();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ReleaseIndicatorCache();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
// 机会面板全部品种(预加载与列表维护用)
//+------------------------------------------------------------------+
void GetOpportunitySymbols(string &syms[])
  {
   string all[] =
     {
      // 美元直盘
      "EURUSD", "GBPUSD", "AUDUSD", "NZDUSD", "USDCAD", "USDCHF", "USDJPY",
      // 欧元交叉
      "EURAUD", "EURCAD", "EURCHF", "EURGBP", "EURJPY", "EURNZD",
      // 英镑交叉
      "GBPAUD", "GBPCAD", "GBPCHF", "GBPJPY", "GBPNZD",
      // 澳元 / 纽元
      "AUDCAD", "AUDNZD", "AUDCHF", "AUDJPY",
      "NZDCAD", "NZDCHF", "NZDJPY",
      // 其它交叉
      "CADCHF", "CADJPY", "CHFJPY"
     };
   ArrayResize(syms, ArraySize(all));
   ArrayCopy(syms, all);
  }

//+------------------------------------------------------------------+
void PreloadOpportunitySymbols()
  {
   string syms[];
   GetOpportunitySymbols(syms);
   for(int i = 0; i < ArraySize(syms); i++)
      SymbolSelect(ResolveChartSymbol(syms[i]), true);
  }

//+------------------------------------------------------------------+
void ShowOpportunityPairs()
  {
   Symb("txtNeoEA_Signal · 机会货币兑");

   Symb("txt— 美元直盘 —");
   Symb("EURUSD");
   Symb("GBPUSD");
   Symb("AUDUSD");
   Symb("NZDUSD");
   Symb("USDCAD");
   Symb("USDCHF");
   Symb("USDJPY");
   Symb("==");

   Symb("txt— 欧元交叉 —");
   Symb("EURAUD");
   Symb("EURCAD");
   Symb("EURCHF");
   Symb("EURGBP");
   Symb("EURJPY");
   Symb("EURNZD");
   Symb("==");

   Symb("txt— 英镑交叉 —");
   Symb("GBPAUD");
   Symb("GBPCAD");
   Symb("GBPCHF");
   Symb("GBPJPY");
   Symb("GBPNZD");
   Symb("==");

   Symb("txt— 澳元 / 纽元 —");
   Symb("AUDCAD");
   Symb("AUDNZD");
   Symb("AUDCHF");
   Symb("AUDJPY");
   Symb("NZDCAD");
   Symb("NZDCHF");
   Symb("NZDJPY");
   Symb("==");

   Symb("txt— 其它交叉 —");
   Symb("CADCHF");
   Symb("CADJPY");
   Symb("CHFJPY");
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   RefreshBlockedCurrencies();
   ShowOpportunityPairs();

   if(n <= 2)
     {
      label("hint", "暂无机会品种：持仓涉及货币(如AUDCAD含AUD/CAD)的相关兑均隐藏；请启用报价品种",
            50, 30, 35);
     }
   else if(!EnsureSymbolReady(ResolveChartSymbol("EURUSD"), PERIOD_H4, 710))
     {
      label("hint", "历史数据同步中，请稍候…", 50, 30, 35);
     }
   else
      ObjectDelete(0, "hint");

   aorders();

   HighlightCurrentSymbolButtons();

   n = 1;
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void aorders()
  {
   ClearPositionPanelRows();

   string seen[];
   int    seenCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string resolved = ResolveChartSymbol(PositionGetString(POSITION_SYMBOL));

      bool already = false;
      for(int j = 0; j < seenCount; j++)
        {
         if(seen[j] == resolved)
           {
            already = true;
            break;
           }
        }
      if(already)
         continue;

      ArrayResize(seen, seenCount + 1);
      seen[seenCount] = resolved;
      seenCount++;
     }

   if(seenCount == 0)
      return;

   Symb("==");
   Symb("txt— 现有仓位 —");

   for(int i = 0; i < seenCount; i++)
      Symb2(seen[i]);
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      long objType = ObjectGetInteger(0, sparam, OBJPROP_TYPE);

      if(objType == OBJ_LABEL)
        {
         string tooltip = ObjectGetString(0, sparam, OBJPROP_TOOLTIP);
         string sym;
         ENUM_TIMEFRAMES tf;

         if(ParseTfTooltip(tooltip, sym, tf))
           {
            OpenSymbolPeriodChart(sym, tf, false);
            return;
           }
        }

      if(objType != OBJ_BUTTON || !ObjectGetInteger(0, sparam, OBJPROP_STATE))
         return;

      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

      if(sparam == OBJ_BTN_CLR)
        {
         ObjectsDeleteAll(0);
         OnInit();
         UpdatePanel();
         return;
        }

      if(IsControlButton(sparam))
         return;

      string sy = ObjectGetString(0, sparam, OBJPROP_TOOLTIP);
      if(sy == "")
         sy = sparam;

      // 品种按钮: 已在 W1 则切 H4, 否则切 W1
      ENUM_TIMEFRAMES period = TMVIEW;
      string resolved = ResolveChartSymbol(sy);
      if(_Symbol == resolved && _Period == TMVIEW)
         period = TMEXE;

      OpenSymbolPeriodChart(sy, period, InpOpenNewTab);
      ObjectSetInteger(0, sparam, OBJPROP_BGCOLOR, clrGreenYellow);
     }

   if(id == CHARTEVENT_KEYDOWN && getExistChart() == 0)
     {
      if((int)lparam == 39)
         ChartOpen(_Symbol, TMEXE);
     }
  }

//+------------------------------------------------------------------+
int getExistChart()
  {
   long currChart, prevChart = ChartFirst();
   int i = 0, limit = 100;

   while(i < limit)
     {
      currChart = ChartNext(prevChart);
      if(currChart < 0)
         break;
      if(ChartSymbol(currChart) == _Symbol)
         return 1;
      prevChart = currChart;
      i++;
     }

   return 0;
  }

//+------------------------------------------------------------------+
void btn(const string objName, const string symbol, int x, int y)
  {
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, objName, OBJPROP_TEXT, symbol);
   ObjectSetString(0, objName, OBJPROP_TOOLTIP, symbol);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, 80);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, 20);

   string sym1 = StringSubstr(_Symbol, 0, 3);
   string sym2 = StringSubstr(_Symbol, 3, 3);
   if(StringFind(symbol, sym1) != -1 || StringFind(symbol, sym2) != -1)
      ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, clrPaleTurquoise);
  }

//+------------------------------------------------------------------+
void label(const string name, const string value, double rsi, int x, int y)
  {
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   color cc = clrWhite;
   if(rsi > 60)
      cc = clrRed;
   if(rsi < 40)
      cc = clrBlue;

   int fontSize = 10;
   if(name == OBJ_TITLE || StringFind(name, "NeoEA_Signal") == 0)
      fontSize = 12;
   if(StringFind(name, "txt") != -1)
      fontSize = 8;

   ObjectSetString(0, name, OBJPROP_TEXT, value);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Calibri");
   ObjectSetInteger(0, name, OBJPROP_COLOR, cc);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, name);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
void tfLabel(const string name, const string symbol, ENUM_TIMEFRAMES tf,
             const string value, double rsi, int x, int y)
  {
   label(name, value, rsi, x, y);
   ObjectSetString(0, name, OBJPROP_TOOLTIP,
                   "TF|" + symbol + "|" + IntegerToString((int)tf));
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
  }

//+------------------------------------------------------------------+
void Symb(string sy)
  {
   int m    = 25;
   int btop = 10;

   if(sy == "==")
     {
      label(sy + "==", "", 50, 0, btop + m * n);
      n++;
      return;
     }

   if(StringFind(sy, "txt") != -1)
     {
      StringReplace(sy, "txt", "");
      label("txt" + IntegerToString(n), sy, 50, 30, btop + m * n);
      n++;
      return;
     }

   string resolved = ResolveChartSymbol(sy);

   if(IsPairBlockedByHeldCurrencies(resolved))
      return;

   int pnum = GetPositionExistNum(resolved);
   if(pnum >= FilterPairsNum)
      return;

   if(!SymbolInfoInteger(resolved, SYMBOL_EXIST))
     {
      label(sy + "err", sy + " 无此品种", 50, 30, btop + m * n);
      n++;
      return;
     }

   double b = SymbolInfoDouble(resolved, SYMBOL_BID);

   double rsi15 = GetRSI(resolved, PERIOD_M15, 8);
   tfLabel(sy + "M15", resolved, PERIOD_M15, "M15", rsi15, 30, btop + m * n);
   double rsi30 = GetRSI(resolved, PERIOD_M30, 8);
   tfLabel(sy + "M30", resolved, PERIOD_M30, "M30", rsi30, 80, btop + m * n);
   double rsi4h = GetRSI(resolved, PERIOD_H4, 8);
   tfLabel(sy + "H4", resolved, PERIOD_H4, "H4", rsi4h, 130, btop + m * n);
   double rsid1 = GetRSI(resolved, PERIOD_D1, 8);
   tfLabel(sy + "D1", resolved, PERIOD_D1, "D1", rsid1, 180, btop + m * n);

   double cc          = 50;
   double ma          = GetMA(resolved, PERIOD_H4, 700);
   double point       = SymbolInfoDouble(resolved, SYMBOL_POINT);
   double Ma_Bid_Diff = MathAbs(ma - b) / point;

   if(Ma_Bid_Diff > 1500 && b > ma)
      cc = 100;
   if(Ma_Bid_Diff > 1500 && b < ma)
      cc = 0;

   label(sy + "MA", "MA", cc, 230, btop + m * n);
   label(sy + "pnum", DoubleToString(pnum, 0), 50, 280, btop + m * n);

   btn(sy, resolved, 320, btop + m * n);
   n++;
  }

//+------------------------------------------------------------------+
void Symb2(const string sy)
  {
   string resolved = ResolveChartSymbol(sy);
   string prefix   = OBJ_POS_PREF + resolved + "_";
   int    pnum     = GetPositionExistNum(resolved);
   double b        = SymbolInfoDouble(resolved, SYMBOL_BID);
   int    m        = 25;
   int    btop     = 10;

   double rsi15 = GetRSI(resolved, PERIOD_M15, 8);
   tfLabel(prefix + "M15", resolved, PERIOD_M15, "M15", rsi15, 30, btop + m * n);
   double rsi30 = GetRSI(resolved, PERIOD_M30, 8);
   tfLabel(prefix + "M30", resolved, PERIOD_M30, "M30", rsi30, 80, btop + m * n);
   double rsi4h = GetRSI(resolved, PERIOD_H4, 8);
   tfLabel(prefix + "H4", resolved, PERIOD_H4, "H4", rsi4h, 130, btop + m * n);
   double rsid1 = GetRSI(resolved, PERIOD_D1, 8);
   tfLabel(prefix + "D1", resolved, PERIOD_D1, "D1", rsid1, 180, btop + m * n);

   double cc          = 50;
   double ma          = GetMA(resolved, PERIOD_H4, 700);
   double point       = SymbolInfoDouble(resolved, SYMBOL_POINT);
   double Ma_Bid_Diff = MathAbs(ma - b) / point;

   if(Ma_Bid_Diff > 1500 && b > ma)
      cc = 100;
   if(Ma_Bid_Diff > 1500 && b < ma)
      cc = 0;

   label(prefix + "MA", "MA", cc, 230, btop + m * n);
   label(prefix + "pnum", DoubleToString(pnum, 0), 50, 280, btop + m * n);

   btn(prefix + "btn", resolved, 320, btop + m * n);
   n++;
  }

//+------------------------------------------------------------------+
void BG()
  {
   ObjectDelete(0, OBJ_BG);
   ObjectCreate(0, OBJ_BG, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, OBJ_BG, OBJPROP_TEXT, "g");
   ObjectSetInteger(0, OBJ_BG, OBJPROP_FONTSIZE, 950);
   ObjectSetString(0, OBJ_BG, OBJPROP_FONT, "Webdings");
   ObjectSetInteger(0, OBJ_BG, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, OBJ_BG, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, OBJ_BG, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, OBJ_BG, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, OBJ_BG, OBJPROP_XDISTANCE, -780);
   ObjectSetInteger(0, OBJ_BG, OBJPROP_YDISTANCE, 0);
  }
//+------------------------------------------------------------------+
