
//+------------------------------------------------------------------+
//|                                            NeoEA_XU.mq5           |
//|            双向马丁网格(Tick驱动版) — 黄金(XAU)专用参数预设       |
//|            双向马丁网格(Tick驱动版 Bidirectional Martingale)      |
//|                                                                  |
//|  策略思路(双向马丁):                                             |
//|   1. 同时维护"多头篮子"和"空头篮子"两套马丁,互相独立。           |
//|   2. 任一方向没有持仓时,满足条件即开首单(每个 tick 检测)。       |
//|   3. 每个 tick 用实时 Bid/Ask 判断是否触发网格加仓(马丁);       |
//|      网格间距随 ATR 动态调整(波动大则间距放大)。                 |
//|   4. 某方向篮子合计盈利达到目标后,只平这一方向(另一方向不动)。   |
//|      可选跟踪止盈: 达激活距离后跟随最优价, 回撤指定点数平仓。    |
//|   5. 加仓层数、总手数、浮亏都有硬性上限,防止无限加仓爆仓。       |
//|                                                                  |
//|  Tick 驱动说明:                                                  |
//|   - 每个 tick 执行决策, 与图表挂载周期无关                        |
//|   - 多头用 Bid 判断(平仓/加仓/触发), 空头用 Ask 判断             |
//|   - 止盈优先于加仓(同一 tick 内先检查止盈)                       |
//|   - 回测需使用"每个 tick"模式以获得准确结果                      |
//|                                                                  |
//|  账户要求: 必须是 MT5 对冲账户(Hedging),否则双向无法并存。      |
//+------------------------------------------------------------------+
#property copyright "NeoEA_XU"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//==================================================================
// 输入参数
//==================================================================

input group "===== 基础设置 ====="
input long   InpMagic          = 20260601001;    // 魔术号(XU黄金版,区分本EA订单)
input int    InpSlippagePoints = 60;             // 允许滑点(point,黄金点差/滑点更大)
input string InpComment        = "NeoEA_XU";   // 订单备注

input group "===== 手动交易(手工挂单触发首单) ====="
// 开启后: 不再自动开首单, 改用图表上的"买入/卖出"按钮挂一整套网格预设。
//   点击买入: 当前价下方 N 点生成"首单触发射线(锚线)", 锚线可拖动平移、拖右端点调斜率;
//             再按马丁网格间距向下排列 InpMaxAddLevels 条水平加仓预览线;
//             止盈/止损线可单独拖动(橙色), 线上标注预估盈/亏; 止盈线仅显示, 止损线触价全平。
//   点击卖出: 方向相反(线在上方)。
//     - 该方向空仓时: 显示加仓预览线, 每个 tick 随锚线"当前价"更新位置;
//                     Bid/Ask 触及锚线当前价 -> 开首单, 成功后删除全部挂单触发线(防重复触发)。
//     - 该方向已有持仓或挂单时: 自动删除手动触发线, 不再重复触发。
//     - 该方向有持仓时: 止盈/止损预览线仍随篮子更新; 加仓按马丁自动进行。
//   平仓后需再次点击买入/卖出按钮才能重新挂触发线。
input bool   InpManualTrade         = true; // 启用手动交易(用按钮挂网格预设开首单)
input int    InpTriggerOffsetPoints = 550;   // 首单触发线距当前价的点数(point,约$5.5@2位报价)
input int    InpAnchorTrendBars     = 48;    // 锚线(向右射线)默认横跨的K线数(黄金H1趋势常用)

input group "===== 手数(马丁) ====="
input double InpFirstLot       = 0.01;   // 首单手数
input double InpLotMultiplier  = 1.45;  // 每加一层的手数倍率(黄金略保守)
input double InpMaxLot         = 0.15;   // 单笔最大手数上限

input group "===== 网格加仓 ====="
input int    InpGridStepPoints = 150;    // 固定网格间距(point,约$3.2): 关闭ATR动态时使用
input int    InpMaxAddLevels   = 5;      // 单方向最大持仓笔数(含首单,黄金少层防深套)
input bool   InpUseDynamicStep = true;   // 启用ATR动态网格(波动大则间距放大)
input ENUM_TIMEFRAMES InpAtrTimeframe = PERIOD_CURRENT; // ATR K线周期(当前=随图表周期;可改H1等)
input int    InpAtrPeriod      = 1;     // ATR周期
input double InpAtrMult        = 0.5;    // 网格间距系数
input int    InpAtrMinPoints   = 150;    // ATR动态间距下限(point,约$2, 0=不限)
input int    InpAtrMaxPoints   = 3000;    // ATR动态间距上限(point,约$9, 0=不限)

input group "===== 篮子止盈(每个方向独立) ====="
input int    InpTpPoints       = 200;    // 止盈激活距离(均价±此点数,约$1.8@2位报价)
input bool   InpUseTrailingTp  = true;  // 启用跟踪止盈(达激活距离后跟随最优价)
input int    InpTrailPoints    = 50;    // 跟踪回撤点数(黄金波动大,回撤略放宽)

input group "===== 全局风控 ====="
input double InpMaxFloatingLoss = 200.0; // 总浮亏(双向合计)超过此金额($)全平(0=关闭,黄金波动大)
input bool   InpBlockSharedCurrency = true; // 开首单:账户其它品种与当前品种共用基/报价货币则不开(如持AUDUSD不开USDJPY)

input group "===== 禁止交易时段(黄金低流动性/点差扩大,服务器时间) ====="
// 黄金: 凌晨0~1点亚洲尾段流动性差; 22~23点常遇换日点差扩大
// 只禁止"新开首单", 已有篮子的止盈/加仓不受影响
input bool   InpUseNoTradeHours = true;   // 是否启用禁止交易时段
input string InpNoTradeHours     = "0,1"; // 禁止开首单的小时(逗号分隔,0-23)

//==================================================================
// 全局变量
//==================================================================
CTrade        g_trade;
CPositionInfo g_posInfo;

double g_point  = 0.0;
int    g_digits = 5;

// 禁止交易的小时表(下标 0-23, true 表示该小时禁止开首单)
bool   g_noTradeHour[24];

// 跟踪止盈状态(每个方向独立)
bool   g_trailActiveBuy  = false;
bool   g_trailActiveSell = false;
double g_trailBestBuy    = 0.0;  // 多头激活后记录的最高 Bid
double g_trailBestSell   = 0.0;  // 空头激活后记录的最低 Ask

// 手动交易用的图表对象名(按钮 + 网格触发线)
string g_buyBtnName    = "NeoEA_XU_BtnBuy";     // 买入按钮
string g_sellBtnName   = "NeoEA_XU_BtnSell";    // 卖出按钮
string g_clearBtnName  = "NeoEA_XU_BtnClear";   // 清空挂单线按钮
// 网格线名前缀, 实际对象名为 前缀+层号(0=首单触发线/锚线, 1..=各层加仓预览线)
string g_buyGridPrefix  = "NeoEA_XU_BuyGrid_";  // 买入网格线前缀
string g_sellGridPrefix = "NeoEA_XU_SellGrid_"; // 卖出网格线前缀
string g_infoPrefix     = "NeoEA_XU_Info_";     // 顶部信息面板标签前缀
string g_infoBgName     = "NeoEA_XU_InfoBg";    // 信息面板背景
const int  g_infoLineCount  = 12;               // 信息面板行数(含分隔空行)
const int  g_infoFontSize   = 12;               // 信息面板字体大小
const int  g_infoLineHeight = 22;               // 信息面板行高(像素)
const int  g_infoBgWidth    = 520;              // 背景宽度(像素)
int    g_atrHandle = INVALID_HANDLE; // ATR 指标句柄(动态网格用)

// 止损/止盈线是否已由用户手动拖动定位(为 true 时不再自动平移价格)
bool   g_slLineUserSetBuy  = false;
bool   g_slLineUserSetSell = false;
bool   g_tpLineUserSetBuy  = false;
bool   g_tpLineUserSetSell = false;

// 单方向篮子(同方向所有持仓)的汇总信息
struct BasketInfo
{
   int    count;        // 持仓笔数
   double totalLot;     // 总手数
   double avgPrice;     // 持仓均价
   double profit;       // 合计浮动盈亏($,含手续费/库存费)
   double lastEntry;    // 最近一笔的开仓价(用于判断是否到下一格)
};

//==================================================================
// 初始化
//==================================================================
int OnInit()
{
   g_point  = _Point;
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // 双向并存必须是对冲账户
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("警告: 双向马丁需要 MT5 对冲账户(Hedging),当前账户不是对冲模式,多空无法并存,策略将无法正常工作。");
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ParseNoTradeHours();

   if(InpUseDynamicStep)
   {
      ENUM_TIMEFRAMES tf = AtrTimeframe();
      g_atrHandle = iATR(_Symbol, tf, InpAtrPeriod);
      if(g_atrHandle == INVALID_HANDLE)
      {
         Print("ATR 指标创建失败, Symbol=", _Symbol, " TF=", EnumToString(tf),
               " Period=", InpAtrPeriod);
         return INIT_FAILED;
      }
   }

   // 手动交易模式: 在图表上创建"买入/卖出"按钮面板
   if(InpManualTrade)
      CreatePanel();
   CreateInfoPanel();

   PrintFormat("NeoEA_XU 双向马丁网格(Tick,黄金预设) 初始化完成。Symbol=%s 图表周期=%s Digits=%d 手动交易=%s",
               _Symbol, EnumToString(Period()), g_digits, InpManualTrade ? "开" : "关");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }

   // 清理手动交易创建的所有图表对象
   ObjectDelete(0, g_buyBtnName);
   ObjectDelete(0, g_sellBtnName);
   ObjectDelete(0, g_clearBtnName);
   DeleteGrid(POSITION_TYPE_BUY);
   DeleteGrid(POSITION_TYPE_SELL);
   DeleteInfoPanel();
   ChartRedraw();
}

//==================================================================
// 主循环 — 每个 tick 执行决策
//==================================================================
void OnTick()
{
   // 总浮亏触顶则全平并跳过后续逻辑(本 tick 不再开/加仓)
   if(CheckGlobalRisk())
      return;

   // 手动模式: 维护网格预览线, 并在价格触及触发线时开首单
   if(InpManualTrade)
   {
      // 该方向已有持仓则删掉对应手动触发线, 避免重复触发
      ClearTriggerLinesIfDirectionBusy(POSITION_TYPE_BUY);
      ClearTriggerLinesIfDirectionBusy(POSITION_TYPE_SELL);
      // 按锚价/层数刷新加仓预览线与 SL/TP 线
      UpdateGrid(POSITION_TYPE_BUY);
      UpdateGrid(POSITION_TYPE_SELL);
      CheckManualTriggers();
   }

   // 多空各自独立: 止盈 -> 加仓 -> (自动模式下)无仓开首单
   ManageDirection(POSITION_TYPE_BUY);
   ManageDirection(POSITION_TYPE_SELL);

   // 刷新顶部信息面板(盈亏、隔夜费预估、网格状态等)
   UpdateInfoPanel();
}

//==================================================================
// 管理某一个方向的篮子:止盈 -> 加仓 -> (无仓时)开首单
//==================================================================
void ManageDirection(ENUM_POSITION_TYPE dir)
{
   BasketInfo basket;
   GatherBasket(dir, basket);

   // 已有该方向持仓: 先看止盈(优先),再看加仓
   if(basket.count > 0)
   {
      UpdateBasketTrailing(dir, basket);

      if(IsBasketTakeProfit(dir, basket))
      {
         CloseDirection(dir, InpUseTrailingTp ? "篮子跟踪止盈触发,平掉该方向"
                                              : "篮子止盈达标,平掉该方向");
         ResetBasketTrailing(dir);
         return;
      }

      TryAddPosition(dir, basket);
      return;
   }

   ResetBasketTrailing(dir);

   // 没有该方向持仓 —— 以下是"自动开首单"逻辑

   // 手动交易模式: 首单只能由手动触发线开, 这里不自动开
   if(InpManualTrade)
      return;

   // 禁止交易时段不开新首单(已有篮子的止盈/加仓不受影响)
   if(InpUseNoTradeHours && IsNoTradeHour())
      return;

   OpenFirstOrder(dir);
}

//==================================================================
// 汇总本 EA 在当前品种、指定方向上的篮子信息
//==================================================================
void GatherBasket(ENUM_POSITION_TYPE dir, BasketInfo &b)
{
   b.count     = 0;
   b.totalLot  = 0.0;
   b.avgPrice  = 0.0;
   b.profit    = 0.0;
   b.lastEntry = 0.0;

   double weightedPrice = 0.0; // 手数加权的开仓价之和
   datetime lastTime    = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Magic() != InpMagic) continue;
      if(g_posInfo.Symbol() != _Symbol) continue;
      if(g_posInfo.PositionType() != dir) continue;

      double lot   = g_posInfo.Volume();
      double price = g_posInfo.PriceOpen();

      b.count++;
      b.totalLot    += lot;
      weightedPrice += price * lot;
      b.profit      += g_posInfo.Profit() + g_posInfo.Swap() + g_posInfo.Commission();

      // 记录时间最新的一笔开仓价
      if(g_posInfo.Time() >= lastTime)
      {
         lastTime    = g_posInfo.Time();
         b.lastEntry = price;
      }
   }

   if(b.totalLot > 0)
      b.avgPrice = weightedPrice / b.totalLot;
}

//==================================================================
// 该方向是否已有本 EA 的持仓或挂单(限价/停损等)
//==================================================================
bool HasDirectionOrdersOrPositions(ENUM_POSITION_TYPE dir)
  {
   BasketInfo basket;
   GatherBasket(dir, basket);
   if(basket.count > 0)
      return true;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(dir == POSITION_TYPE_BUY)
        {
         if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP
            || orderType == ORDER_TYPE_BUY_STOP_LIMIT)
            return true;
        }
      else
        {
         if(orderType == ORDER_TYPE_SELL_LIMIT || orderType == ORDER_TYPE_SELL_STOP
            || orderType == ORDER_TYPE_SELL_STOP_LIMIT)
            return true;
        }
     }

   return false;
  }

//==================================================================
// 跟踪止盈: 重置某方向状态
//==================================================================
void ResetBasketTrailing(ENUM_POSITION_TYPE dir)
{
   if(dir == POSITION_TYPE_BUY)
   {
      g_trailActiveBuy = false;
      g_trailBestBuy   = 0.0;
   }
   else
   {
      g_trailActiveSell = false;
      g_trailBestSell   = 0.0;
   }
}

//==================================================================
// 跟踪止盈: 每个 tick 更新激活状态与最优价
//   多头: Bid 达 avg+InpTpPoints 后激活, 记录最高 Bid
//   空头: Ask 达 avg-InpTpPoints 后激活, 记录最低 Ask
//==================================================================
void UpdateBasketTrailing(ENUM_POSITION_TYPE dir, const BasketInfo &b)
{
   if(!InpUseTrailingTp || b.count <= 0)
      return;

   double tpDist = InpTpPoints * g_point;
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(dir == POSITION_TYPE_BUY)
   {
      if(!g_trailActiveBuy)
      {
         if(bid >= b.avgPrice + tpDist)
         {
            g_trailActiveBuy = true;
            g_trailBestBuy   = bid;
         }
      }
      else if(bid > g_trailBestBuy)
      {
         g_trailBestBuy = bid;
      }
   }
   else
   {
      if(!g_trailActiveSell)
      {
         if(ask <= b.avgPrice - tpDist)
         {
            g_trailActiveSell = true;
            g_trailBestSell   = ask;
         }
      }
      else if(ask < g_trailBestSell)
      {
         g_trailBestSell = ask;
      }
   }
}

//==================================================================
// 篮子当前有效止盈价(固定或跟踪回撤线)
//==================================================================
double GetEffectiveTpPrice(ENUM_POSITION_TYPE dir, const BasketInfo &b)
{
   double tpDist    = InpTpPoints * g_point;
   double trailDist = InpTrailPoints * g_point;

   if(dir == POSITION_TYPE_BUY)
   {
      if(!InpUseTrailingTp || !g_trailActiveBuy)
         return b.avgPrice + tpDist;
      return g_trailBestBuy - trailDist;
   }

   if(!InpUseTrailingTp || !g_trailActiveSell)
      return b.avgPrice - tpDist;
   return g_trailBestSell + trailDist;
}

//==================================================================
// 该方向篮子是否达到止盈(用实时 Bid/Ask 判断)
//==================================================================
bool IsBasketTakeProfit(ENUM_POSITION_TYPE dir, const BasketInfo &b)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(!InpUseTrailingTp)
   {
      double tpDist = InpTpPoints * g_point;
      if(dir == POSITION_TYPE_BUY)
         return (bid >= b.avgPrice + tpDist);
      return (ask <= b.avgPrice - tpDist);
   }

   // 跟踪止盈: 未激活时不平仓, 激活后价格回撤至跟踪线平仓
   if(dir == POSITION_TYPE_BUY)
   {
      if(!g_trailActiveBuy)
         return false;
      return (bid <= GetEffectiveTpPrice(dir, b));
   }

   if(!g_trailActiveSell)
      return false;
   return (ask >= GetEffectiveTpPrice(dir, b));
}

//==================================================================
// 判断该方向是否需要加仓(马丁),用实时 Bid/Ask 判断
//   规则: 价格相对最近一笔逆向走够"当前层间距"才加仓
//   同一 tick 内可连续触发多档(循环直到未穿透或达上限)
//==================================================================
void TryAddPosition(ENUM_POSITION_TYPE dir, BasketInfo &b)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   while(b.count < InpMaxAddLevels)
   {
      double stepPts = GetStepPointsForLevel(b.count);
      double step    = stepPts * g_point;

      bool needAdd = false;
      if(dir == POSITION_TYPE_BUY)
      {
         if(bid <= b.lastEntry - step)
            needAdd = true;
      }
      else
      {
         if(ask >= b.lastEntry + step)
            needAdd = true;
      }

      if(!needAdd)
         break;

      int countBefore = b.count;
      double lot = GetLotForLevel(b.count);
      bool ok;
      if(dir == POSITION_TYPE_BUY)
         ok = g_trade.Buy(lot, _Symbol, 0, 0, 0, InpComment);
      else
         ok = g_trade.Sell(lot, _Symbol, 0, 0, 0, InpComment);

      GatherBasket(dir, b);
      if(!ok || b.count <= countBefore)
      {
         PrintFormat("加仓失败(%s): 第%d层 手数%.2f | %s",
                     dir == POSITION_TYPE_BUY ? "买入" : "卖出",
                     countBefore + 1, lot,
                     g_trade.ResultRetcodeDescription());
         break;
      }

      ResetBasketTrailing(dir); // 加仓后均价变化, 重置跟踪止盈
   }
}

//==================================================================
// 读取品种的基货币与报价(盈亏)货币
//==================================================================
bool GetSymbolCurrencies(const string symbol, string &baseCur, string &quoteCur)
{
   baseCur  = "";
   quoteCur = "";
   if(symbol == "")
      return false;

   if(!SymbolInfoInteger(symbol, SYMBOL_EXIST))
      SymbolSelect(symbol, true);

   baseCur  = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   quoteCur = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   return (StringLen(baseCur) > 0 && StringLen(quoteCur) > 0);
}

// 两品种是否共用任一货币(如 AUDUSD 与 USDJPY 共用 USD)
bool SymbolCurrenciesOverlap(const string base1, const string quote1,
                             const string base2, const string quote2)
{
   return (base1 == base2 || base1 == quote2 || quote1 == base2 || quote1 == quote2);
}

// 返回两字符串中第一个相同项(无则空串)
string FirstSharedCurrency(const string a1, const string a2, const string b1, const string b2)
{
   if(a1 == b1 || a1 == b2) return a1;
   if(a2 == b1 || a2 == b2) return a2;
   return "";
}

//==================================================================
// 开首单前: 账户其它品种持仓是否与 symbol 共用货币(同品种不计)
//==================================================================
bool FindSharedCurrencyWithOtherPositions(const string symbol,
                                          string &conflictSymbol,
                                          string &sharedCurrency)
{
   conflictSymbol  = "";
   sharedCurrency  = "";

   string symBase, symQuote;
   if(!GetSymbolCurrencies(symbol, symBase, symQuote))
      return false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i))
         continue;

      string posSym = g_posInfo.Symbol();
      if(posSym == symbol)
         continue;

      string posBase, posQuote;
      if(!GetSymbolCurrencies(posSym, posBase, posQuote))
         continue;

      string shared = FirstSharedCurrency(symBase, symQuote, posBase, posQuote);
      if(shared == "")
         continue;

      conflictSymbol = posSym;
      sharedCurrency = shared;
      return true;
   }
   return false;
}

//==================================================================
// 开某方向首单
//==================================================================
bool OpenFirstOrder(ENUM_POSITION_TYPE dir)
{
   if(InpBlockSharedCurrency)
   {
      string conflictSym = "";
      string sharedCur   = "";
      if(FindSharedCurrencyWithOtherPositions(_Symbol, conflictSym, sharedCur))
      {
         PrintFormat("开首单跳过(%s): %s 与持仓 %s 共用货币 %s",
                     dir == POSITION_TYPE_BUY ? "买入" : "卖出",
                     _Symbol, conflictSym, sharedCur);
         return false;
      }
   }

   double lot = NormalizeLot(GetFirstLot());
   bool   ok;

   if(dir == POSITION_TYPE_BUY)
      ok = g_trade.Buy(lot, _Symbol, 0, 0, 0, InpComment);
   else
      ok = g_trade.Sell(lot, _Symbol, 0, 0, 0, InpComment);

   if(!ok)
      PrintFormat("开首单失败(%s): %s", dir == POSITION_TYPE_BUY ? "买入" : "卖出",
                  g_trade.ResultRetcodeDescription());

   return ok;
}

//==================================================================
// 首单手数:固定手数
//==================================================================
double GetFirstLot()
{
   return InpFirstLot;
}

//==================================================================
// ATR: 读取当前 ATR 值(点数)
//==================================================================
ENUM_TIMEFRAMES AtrTimeframe()
{
   return (InpAtrTimeframe == PERIOD_CURRENT) ? Period() : InpAtrTimeframe;
}

double GetAtrPoints()
{
   if(g_atrHandle == INVALID_HANDLE)
      return (double)InpGridStepPoints;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0)
      return (double)InpGridStepPoints;

   return buf[0] / g_point;
}

//==================================================================
// ATR 动态网格间距(点): ATR × 倍数, 再限制在 [Min, Max]
//==================================================================
double GetAtrStepPoints()
{
   double step = GetAtrPoints() * InpAtrMult;

   if(InpAtrMinPoints > 0 && step < InpAtrMinPoints)
      step = InpAtrMinPoints;
   if(InpAtrMaxPoints > 0 && step > InpAtrMaxPoints)
      step = InpAtrMaxPoints;

   return step;
}

//==================================================================
// 第 level 层应使用的网格间距(level 从 0 开始,0 表示首单到第二单)
//==================================================================
double GetStepPointsForLevel(int level)
{
   return InpUseDynamicStep ? GetAtrStepPoints() : (double)InpGridStepPoints;
}

//==================================================================
// ATR 动态网格: 限幅区间说明(用于面板)
//==================================================================
string FormatAtrLimitRange()
{
   if(InpAtrMinPoints <= 0 && InpAtrMaxPoints <= 0)
      return "不限幅";

   if(InpAtrMinPoints > 0 && InpAtrMaxPoints > 0)
      return StringFormat("限%.0f~%.0f点", (double)InpAtrMinPoints, (double)InpAtrMaxPoints);

   if(InpAtrMinPoints > 0)
      return StringFormat("下限%.0f点", (double)InpAtrMinPoints);

   return StringFormat("上限%.0f点", (double)InpAtrMaxPoints);
}

//==================================================================
// ATR 动态网格: 面板两行文案
//==================================================================
void FormatAtrGridPanel(string &line1, string &line2)
{
   double atrPts  = GetAtrPoints();
   double rawStep = atrPts * InpAtrMult;
   double stepPts = GetAtrStepPoints();
   double stepPx  = stepPts * g_point;

   string tfLabel = (InpAtrTimeframe == PERIOD_CURRENT)
                    ? StringFormat("当前%s", EnumToString(AtrTimeframe()))
                    : EnumToString(AtrTimeframe());

   line1 = StringFormat("动态网格 | %s 周期%d | ATR %.0f点",
                        tfLabel, InpAtrPeriod, atrPts);

   string clampNote = "";
   if(InpAtrMinPoints > 0 && rawStep < InpAtrMinPoints)
      clampNote = " [触下限]";
   else if(InpAtrMaxPoints > 0 && rawStep > InpAtrMaxPoints)
      clampNote = " [触上限]";

   line2 = StringFormat("格距 %.0f×%.2f→%.0f点 (%.*f) | %s%s",
                        atrPts, InpAtrMult, stepPts, g_digits, stepPx,
                        FormatAtrLimitRange(), clampNote);
}

//==================================================================
// 第 level 层应使用的手数(level 从 0 开始: 0=首单,1=第一次加仓...)
//==================================================================
double GetLotForLevel(int level)
{
   double lot = GetFirstLot() * MathPow(InpLotMultiplier, level);
   return NormalizeLot(lot);
}

//==================================================================
// 手数规整到品种允许的范围与步长
//==================================================================
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(lot > InpMaxLot) lot = InpMaxLot;
   return lot;
}

//==================================================================
// 全局风控: 总浮亏止损(双向合计)
//   返回 true 表示已触发并全平
//==================================================================
bool CheckGlobalRisk()
{
   // 总浮亏超限(多空合计)
   if(InpMaxFloatingLoss > 0)
   {
      double floating = GetTotalFloatingProfit();
      if(floating <= -InpMaxFloatingLoss)
      {
         CloseAllPositions("全局风控:总浮亏超限,强制全平");
         return true;
      }
   }

   return false;
}

double GetTotalFloatingProfit()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Magic() != InpMagic) continue;
      if(g_posInfo.Symbol() != _Symbol) continue;
      total += g_posInfo.Profit() + g_posInfo.Swap() + g_posInfo.Commission();
   }
   return total;
}

//==================================================================
// 库存费换算用的 Tick 价值(优先用盈亏货币下的精确值)
//==================================================================
double SwapTickValueForDir(ENUM_POSITION_TYPE dir)
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tvProfit = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   double tvLoss   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);

   if(dir == POSITION_TYPE_BUY && tvProfit > 0.0)
      return tvProfit;
   if(dir == POSITION_TYPE_SELL && tvLoss > 0.0)
      return tvLoss;
   if(tvProfit > 0.0)
      return tvProfit;
   return tv;
}

//==================================================================
// 按品种规格估算「持仓 1 天」的库存费(账户货币, 非已发生库存费统计)
//   POINTS: 库存费点数 × 手数 × (TickValue×Point/TickSize), 不可除以 TickSize  alone
//==================================================================
double CalcDailySwapMoney(ENUM_POSITION_TYPE dir, double lots)
{
   if(lots <= 0.0)
      return 0.0;

   ENUM_SYMBOL_SWAP_MODE mode =
      (ENUM_SYMBOL_SWAP_MODE)SymbolInfoInteger(_Symbol, SYMBOL_SWAP_MODE);
   if(mode == SYMBOL_SWAP_MODE_DISABLED)
      return 0.0;

   double swapRate = (dir == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_SWAP_LONG)
                     : SymbolInfoDouble(_Symbol, SYMBOL_SWAP_SHORT);

   double point        = g_point;
   double tickValue    = SwapTickValueForDir(dir);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double bid          = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double money        = 0.0;

   double pointValue = 0.0;
   if(tickSize > 0.0 && tickValue > 0.0)
      pointValue = tickValue * point / tickSize * lots;

   switch(mode)
   {
      case SYMBOL_SWAP_MODE_POINTS:
         money = swapRate * pointValue;
         break;

      case SYMBOL_SWAP_MODE_CURRENCY_SYMBOL:
      case SYMBOL_SWAP_MODE_CURRENCY_MARGIN:
      case SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT:
         money = swapRate * lots;
         break;

      case SYMBOL_SWAP_MODE_INTEREST_CURRENT:
      case SYMBOL_SWAP_MODE_INTEREST_OPEN:
         money = swapRate / 100.0 / 360.0 * bid * contractSize * lots;
         break;

      case SYMBOL_SWAP_MODE_REOPEN_CURRENT:
      case SYMBOL_SWAP_MODE_REOPEN_BID:
         money = swapRate * pointValue;
         break;

      default:
         money = swapRate * lots;
         break;
   }

   return money;
}

string FormatSwapMoney(double v)
{
   double a = MathAbs(v);
   if(a >= 1.0)
      return StringFormat("$%+.2f", v);
   if(a >= 0.01)
      return StringFormat("$%+.3f", v);
   return StringFormat("$%+.4f", v);
}

//==================================================================
// 平掉本 EA 在当前品种、指定方向的所有持仓
//==================================================================
void CloseDirection(ENUM_POSITION_TYPE dir, string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Magic() != InpMagic) continue;
      if(g_posInfo.Symbol() != _Symbol) continue;
      if(g_posInfo.PositionType() != dir) continue;
      g_trade.PositionClose(g_posInfo.Ticket());
   }
   ResetBasketTrailing(dir);
   if(InpManualTrade)
      DeleteGrid(dir);
   if(reason != "")
      Print(reason, dir == POSITION_TYPE_BUY ? " [多头]" : " [空头]");
}

//==================================================================
// 平掉本 EA 在当前品种的所有持仓(多空全平)
//==================================================================
void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Magic() != InpMagic) continue;
      if(g_posInfo.Symbol() != _Symbol) continue;
      g_trade.PositionClose(g_posInfo.Ticket());
   }
   ResetBasketTrailing(POSITION_TYPE_BUY);
   ResetBasketTrailing(POSITION_TYPE_SELL);
   if(InpManualTrade)
     {
      DeleteGrid(POSITION_TYPE_BUY);
      DeleteGrid(POSITION_TYPE_SELL);
     }
   if(reason != "")
      Print(reason);
}

//==================================================================
// 手动交易: 图表事件处理
//   - 点击买入/卖出按钮: 生成整套网格预设(首单触发射线 + 各层加仓预览)
//   - 拖动首单触发线(锚线): 下方各层加仓线跟着整体平移
//==================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!InpManualTrade)
      return;

   // 点击按钮 -> 创建网格
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == g_buyBtnName)
      {
         CreateGrid(POSITION_TYPE_BUY);
         ObjectSetInteger(0, g_buyBtnName, OBJPROP_STATE, false); // 复位按钮
         ChartRedraw();
      }
      else if(sparam == g_sellBtnName)
      {
         CreateGrid(POSITION_TYPE_SELL);
         ObjectSetInteger(0, g_sellBtnName, OBJPROP_STATE, false);
         ChartRedraw();
      }
      else if(sparam == g_clearBtnName)
      {
         ClearAllGrids();
         ObjectSetInteger(0, g_clearBtnName, OBJPROP_STATE, false);
         ChartRedraw();
      }
      return;
   }

   if(id == CHARTEVENT_OBJECT_DRAG)
   {
      // 拖动锚线(向右射线) -> 立刻按当前价重排该方向的加仓预览线
      if(sparam == GridLineName(POSITION_TYPE_BUY, 0))
      {
         UpdateGrid(POSITION_TYPE_BUY);
         ChartRedraw();
      }
      else if(sparam == GridLineName(POSITION_TYPE_SELL, 0))
      {
         UpdateGrid(POSITION_TYPE_SELL);
         ChartRedraw();
      }
      else if(sparam == GridMaxLossLineName(POSITION_TYPE_BUY))
      {
         g_slLineUserSetBuy = true;
         RefreshSlLineDisplay(POSITION_TYPE_BUY);
         ChartRedraw();
      }
      else if(sparam == GridMaxLossLineName(POSITION_TYPE_SELL))
      {
         g_slLineUserSetSell = true;
         RefreshSlLineDisplay(POSITION_TYPE_SELL);
         ChartRedraw();
      }
      else if(sparam == GridTpLineName(POSITION_TYPE_BUY))
      {
         g_tpLineUserSetBuy = true;
         RefreshTpLineDisplay(POSITION_TYPE_BUY);
         ChartRedraw();
      }
      else if(sparam == GridTpLineName(POSITION_TYPE_SELL))
      {
         g_tpLineUserSetSell = true;
         RefreshTpLineDisplay(POSITION_TYPE_SELL);
         ChartRedraw();
      }
   }
}

//==================================================================
// 手动交易: 创建图表按钮面板(买入 / 卖出)
//==================================================================
void CreatePanel()
{
   CreateButton(g_buyBtnName,  "买入",   20,  30, clrWhite, clrSeaGreen);
   CreateButton(g_sellBtnName, "卖出",  130,  30, clrWhite, clrFireBrick);
   CreateButton(g_clearBtnName, "清空线", 240,  30, clrWhite, clrDimGray);
   ChartRedraw();
}

//==================================================================
// 手动交易: 创建一个按钮对象
//==================================================================
void CreateButton(string name, string text, int x, int y, color txtColor, color bgColor)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,     100);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,     34);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  12);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     txtColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,   bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_STATE,     false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
}

//==================================================================
// 手动交易: 某方向网格中第 k 条线的对象名(0=首单触发线/锚线)
//==================================================================
string GridLineName(ENUM_POSITION_TYPE dir, int k)
{
   string prefix = (dir == POSITION_TYPE_BUY) ? g_buyGridPrefix : g_sellGridPrefix;
   return prefix + IntegerToString(k);
}

// 手动交易: 某方向止盈线对象名
string GridTpLineName(ENUM_POSITION_TYPE dir)
{
   string prefix = (dir == POSITION_TYPE_BUY) ? g_buyGridPrefix : g_sellGridPrefix;
   return prefix + "TP";
}

// 手动交易: 止盈线上的文字标注对象名
string GridTpLabelName(ENUM_POSITION_TYPE dir)
{
   string prefix = (dir == POSITION_TYPE_BUY) ? g_buyGridPrefix : g_sellGridPrefix;
   return prefix + "TPLbl";
}

bool IsTpLineUserSet(ENUM_POSITION_TYPE dir)
{
   return (dir == POSITION_TYPE_BUY) ? g_tpLineUserSetBuy : g_tpLineUserSetSell;
}

void SetTpLineUserSet(ENUM_POSITION_TYPE dir, bool userSet)
{
   if(dir == POSITION_TYPE_BUY)
      g_tpLineUserSetBuy = userSet;
   else
      g_tpLineUserSetSell = userSet;
}

// 手动交易: 某方向止损线对象名
string GridMaxLossLineName(ENUM_POSITION_TYPE dir)
{
   string prefix = (dir == POSITION_TYPE_BUY) ? g_buyGridPrefix : g_sellGridPrefix;
   return prefix + "MaxLoss";
}

// 手动交易: 止损线上的文字标注对象名
string GridMaxLossLabelName(ENUM_POSITION_TYPE dir)
{
   string prefix = (dir == POSITION_TYPE_BUY) ? g_buyGridPrefix : g_sellGridPrefix;
   return prefix + "MaxLossLbl";
}

bool IsSlLineUserSet(ENUM_POSITION_TYPE dir)
{
   return (dir == POSITION_TYPE_BUY) ? g_slLineUserSetBuy : g_slLineUserSetSell;
}

void SetSlLineUserSet(ENUM_POSITION_TYPE dir, bool userSet)
{
   if(dir == POSITION_TYPE_BUY)
      g_slLineUserSetBuy = userSet;
   else
      g_slLineUserSetSell = userSet;
}

//==================================================================
// 手动交易: 第 k 层入场线相对锚线"当前价"的价格距离(累计网格间距)
//   k=0 返回 0; k>=1 为前 k 段 GetStepPointsForLevel 间距之和
//==================================================================
double GridOffsetToLevel(int k)
{
   double off = 0.0;
   for(int i = 1; i <= k; i++)
      off += GetStepPointsForLevel(i) * g_point;
   return off;
}

//==================================================================
// 手动交易: 读取锚线(向右射线)在指定时间对应的价格; 锚线不存在返回 0
//==================================================================
double AnchorPriceAtTime(ENUM_POSITION_TYPE dir, datetime t)
{
   string anchor = GridLineName(dir, 0);
   if(ObjectFind(0, anchor) < 0)
      return 0.0;
   return ObjectGetValueByTime(0, anchor, t);
}

// 兼容: 取当前时刻锚线价格(用于图表预览线更新)
double AnchorCurrentPrice(ENUM_POSITION_TYPE dir)
{
   return AnchorPriceAtTime(dir, TimeCurrent());
}

// 读取射线(趋势线)在指定时刻的价格
double RayLinePriceAtTime(string name, datetime t)
{
   if(ObjectFind(0, name) < 0)
      return 0.0;
   return ObjectGetValueByTime(0, name, t);
}

double RayLineCurrentPrice(string name)
{
   return RayLinePriceAtTime(name, TimeCurrent());
}

// 将水平射线平移到指定价格(保持两端点时间不变)
void SetRayLinePrice(string name, double price)
{
   if(ObjectFind(0, name) < 0)
      return;
   datetime t1 = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 0);
   datetime t2 = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 1);
   price = NormalizeDouble(price, g_digits);
   ObjectMove(0, name, 0, t1, price);
   ObjectMove(0, name, 1, t2, price);
}

// 创建水平射线(左右双向延伸)
void CreateHorizontalRay(string name, double price, color lineColor, int width, bool selectable,
                         const ENUM_LINE_STYLE style = STYLE_SOLID)
{
   datetime t1 = TimeCurrent();
   datetime t2 = t1 + (datetime)(PeriodSeconds() * InpAnchorTrendBars);

   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      lineColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  true);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, selectable);
   ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
}

//==================================================================
// 手动交易: 创建整套网格预设
//   锚线(首单触发线)是一条向右延伸的射线(趋势线), 可拖右端点调斜率;
//   各层加仓预览线是水平射线, 每个 tick 随锚线"当前价"更新位置。
//==================================================================
void CreateGrid(ENUM_POSITION_TYPE dir)
{
   DeleteGrid(dir); // 先清掉旧的

   double offset = InpTriggerOffsetPoints * g_point;
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double anchor = (dir == POSITION_TYPE_BUY)
                   ? NormalizeDouble(ask - offset, g_digits)
                   : NormalizeDouble(bid + offset, g_digits);

   int levels = InpMaxAddLevels;
   if(levels < 1) levels = 1;

   color col = (dir == POSITION_TYPE_BUY) ? clrSeaGreen : clrFireBrick;

   // 锚线: 向右射线(初始水平, 拖右端点可调斜率)
   MakeAnchorLine(GridLineName(dir, 0), anchor, col, dir);

   // 各层加仓预览线: 水平线, 位置 = 锚线当前价 ∓ 累计网格间距
   for(int k = 1; k < levels; k++)
   {
      double price = (dir == POSITION_TYPE_BUY) ? anchor - GridOffsetToLevel(k)
                                                : anchor + GridOffsetToLevel(k);
      price = NormalizeDouble(price, g_digits);
      MakeGridLine(GridLineName(dir, k), price, col, k, dir);
   }

   // 篮子止盈预览线(空仓时随锚线移动)
   SetSlLineUserSet(dir, false);
   SetTpLineUserSet(dir, false);

   MakeTpLine(GridTpLineName(dir), anchor, dir);
   MakeMaxLossLine(GridMaxLossLineName(dir), anchor, dir);
   UpdateGrid(dir);
   PrintMaxLossPreviewHint(dir, anchor);

   if(HasDirectionOrdersOrPositions(dir))
     {
      DeleteTriggerGridLines(dir);
      PrintFormat("手动挂单: %s方向已有持仓或挂单, 已自动删除触发线(保留止盈/止损预览线)",
                  dir == POSITION_TYPE_BUY ? "买入" : "卖出");
     }

   ChartRedraw();
}

//==================================================================
// 手动交易: 维护加仓预览线 / 止盈止损预览线
//   - 有持仓且无锚线: 只更新止盈/止损线(触发后已删挂单线)
//   - 有持仓且有锚线: 隐藏加仓预览线
//   - 空仓有锚线:     显示并更新加仓预览线
//==================================================================
void UpdateGrid(ENUM_POSITION_TYPE dir)
{
   BasketInfo basket;
   GatherBasket(dir, basket);
   bool hasPosition = (basket.count > 0);

   // 锚线(k=0)当前价: 手动挂网/拖线后的基准, 空仓时各层预览线相对它偏移
   double anchor = AnchorCurrentPrice(dir);

   // 锚线已删(如首单触发后): 无仓则无需维护; 有仓则只跟止盈/最大亏损预览线
   if(anchor <= 0.0)
     {
      if(!hasPosition)
         return;

      UpdateBasketTrailing(dir, basket);
      UpdateTpLine(dir, 0.0, true, basket);
      UpdateMaxLossLine(dir, 0.0, true, basket);
      return;
     }

   int levels = InpMaxAddLevels;
   if(levels < 1) levels = 1;

   // 有仓时更新跟踪止盈状态, 供下方 TP 预览线使用
   if(hasPosition)
      UpdateBasketTrailing(dir, basket);

   // k=1..levels-1 为各层加仓价预览线(非锚线、非 TP/SL 线)
   for(int k = 1; k < levels; k++)
   {
      string nm = GridLineName(dir, k);
      if(ObjectFind(0, nm) < 0)
         continue;

      if(hasPosition)
      {
         // 已开仓: 实际加仓由 ManageDirection 按市价触发, 预览线不再显示
         ObjectSetInteger(0, nm, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      }
      else
      {
         // 仅挂网未开仓: 预览线随锚价移动(多向下、空向上, 间距见 GridOffsetToLevel)
         ObjectSetInteger(0, nm, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
         double price = (dir == POSITION_TYPE_BUY) ? anchor - GridOffsetToLevel(k)
                                                   : anchor + GridOffsetToLevel(k);
         price = NormalizeDouble(price, g_digits);
         SetRayLinePrice(nm, price);
      }
   }

   // 止盈线、打满层最大亏损线: 空仓跟锚价, 有仓跟篮子均价/层数
   UpdateTpLine(dir, anchor, hasPosition, basket);
   UpdateMaxLossLine(dir, anchor, hasPosition, basket);
}

//==================================================================
// 手动交易: 清空买入/卖出两个方向的全部挂单预览线
//==================================================================
void ClearAllGrids()
{
   DeleteGrid(POSITION_TYPE_BUY);
   DeleteGrid(POSITION_TYPE_SELL);
   Print("已清空全部挂单预览线(买入/卖出)。");
}

//==================================================================
// 手动交易: 删除某方向的全部网格线(锚线 + 各层加仓预览线 + 止盈线)
//==================================================================
void DeleteGrid(ENUM_POSITION_TYPE dir)
{
   DeleteTriggerGridLines(dir);
   ObjectDelete(0, GridTpLineName(dir));
   ObjectDelete(0, GridTpLabelName(dir));
   ObjectDelete(0, GridMaxLossLineName(dir));
   ObjectDelete(0, GridMaxLossLabelName(dir));
   SetSlLineUserSet(dir, false);
   SetTpLineUserSet(dir, false);
}

//==================================================================
// 手动交易: 仅删除首单触发线(锚线)与各层加仓预览线
//==================================================================
void DeleteTriggerGridLines(ENUM_POSITION_TYPE dir)
{
   int levels = InpMaxAddLevels;
   if(levels < 1) levels = 1;

   for(int k = 0; k < levels; k++)
      ObjectDelete(0, GridLineName(dir, k));
}

//==================================================================
// 有持仓/挂单时清除该方向手动触发线(锚线+加仓预览), 防重复触发
//==================================================================
void ClearTriggerLinesIfDirectionBusy(ENUM_POSITION_TYPE dir)
  {
   if(!HasDirectionOrdersOrPositions(dir))
      return;

   if(AnchorCurrentPrice(dir) <= 0.0)
      return;

   DeleteTriggerGridLines(dir);
  }

//==================================================================
// 手动交易: 创建锚线(首单触发线) —— 向右延伸的射线(趋势线)
//   左端点为锚点, 右端点初始同价(水平); 仅向右延伸, 未来时刻可取价;
//   用户拖动整条线平移、或拖右端点改变斜率。
//==================================================================
void MakeAnchorLine(string name, double price, color lineColor, ENUM_POSITION_TYPE dir)
{
   datetime t1 = TimeCurrent();
   datetime t2 = t1 + (datetime)(PeriodSeconds() * InpAnchorTrendBars);

   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      lineColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      2);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  true);   // 向右延伸
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);  // 不向左延伸
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);   // 可选中拖动(平移/调斜率)
   ObjectSetInteger(0, name, OBJPROP_SELECTED,   true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);

   string side = (dir == POSITION_TYPE_BUY) ? "买入" : "卖出";
   string tip  = side + " 首单触发射线(拖动整体平移/拖右端点调斜率)";
   ObjectSetString(0, name, OBJPROP_TEXT,    tip);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
}

//==================================================================
// 手动交易: 创建一条加仓预览线(水平射线, 不可单独拖动)
//==================================================================
void MakeGridLine(string name, double price, color lineColor, int k, ENUM_POSITION_TYPE dir)
{
   CreateHorizontalRay(name, price, lineColor, 1, false, STYLE_DASH);

   string side = (dir == POSITION_TYPE_BUY) ? "买入" : "卖出";
   string tip  = StringFormat("%s 第%d层加仓预览", side, k + 1);
   ObjectSetString(0, name, OBJPROP_TEXT,    tip);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
}

//==================================================================
// 手动交易: 按计划网格推算均价与总手数(打满各层)
//==================================================================
bool GetPlannedBasket(ENUM_POSITION_TYPE dir, double anchor, double &avgPrice, double &totalLot,
                      int &levels)
{
   if(anchor <= 0.0)
      return false;

   levels = InpMaxAddLevels;
   if(levels < 1)
      levels = 1;

   double weightedPrice = 0.0;
   totalLot = 0.0;

   for(int k = 0; k < levels; k++)
   {
      double entryPrice = (dir == POSITION_TYPE_BUY) ? anchor - GridOffsetToLevel(k)
                                                     : anchor + GridOffsetToLevel(k);
      double lot = GetLotForLevel(k);
      weightedPrice += entryPrice * lot;
      totalLot += lot;
   }

   if(totalLot <= 0.0)
      return false;

   avgPrice = weightedPrice / totalLot;
   return true;
}

//==================================================================
// 自动止盈线价格: 空仓按计划网格均价+点数, 有仓用有效止盈价(含跟踪)
//==================================================================
bool CalcAutoTpPrice(ENUM_POSITION_TYPE dir, double anchor, bool hasPosition,
                     const BasketInfo &basket, double &tpPrice)
{
   if(hasPosition && basket.count > 0)
   {
      tpPrice = GetEffectiveTpPrice(dir, basket);
      return (tpPrice > 0.0);
   }

   double avgPrice, totalLot;
   int levels;
   if(!GetPlannedBasket(dir, anchor, avgPrice, totalLot, levels))
      return false;

   double tpDist = InpTpPoints * g_point;
   tpPrice = (dir == POSITION_TYPE_BUY) ? avgPrice + tpDist : avgPrice - tpDist;
   tpPrice = NormalizeDouble(tpPrice, g_digits);
   return (tpPrice > 0.0);
}

//==================================================================
// 手动交易: 创建止盈线(水平射线, 可单独拖动, 样式与止损线一致)
//==================================================================
void MakeTpLine(string name, double anchorPrice, ENUM_POSITION_TYPE dir)
{
   BasketInfo basket;
   GatherBasket(dir, basket);
   bool hasPosition = (basket.count > 0);

   double tpPrice;
   if(!CalcAutoTpPrice(dir, anchorPrice, hasPosition, basket, tpPrice))
   {
      double tpDist = InpTpPoints * g_point;
      tpPrice = (dir == POSITION_TYPE_BUY) ? anchorPrice + tpDist : anchorPrice - tpDist;
      tpPrice = NormalizeDouble(tpPrice, g_digits);
   }

   ObjectDelete(0, name);
   ObjectDelete(0, GridTpLabelName(dir));
   CreateHorizontalRay(name, tpPrice, clrOrange, 2, true);

   RefreshTpLineDisplay(dir);
}

//==================================================================
// 手动交易: 更新止盈线
//   未手动拖动: 空仓按计划网格, 有仓随有效止盈价(含跟踪)移动
//   已手动拖动: 只更新线上预估盈利标注
//==================================================================
void UpdateTpLine(ENUM_POSITION_TYPE dir, double anchor, bool hasPosition, const BasketInfo &basket)
{
   string name = GridTpLineName(dir);
   if(ObjectFind(0, name) < 0)
      return;

   double tpPrice;
   if(!CalcAutoTpPrice(dir, anchor, hasPosition, basket, tpPrice))
   {
      ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      if(ObjectFind(0, GridTpLabelName(dir)) >= 0)
         ObjectSetInteger(0, GridTpLabelName(dir), OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      return;
   }

   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

   if(!IsTpLineUserSet(dir))
      SetRayLinePrice(name, tpPrice);

   RefreshTpLineDisplay(dir);
}

//==================================================================
// 按止盈线价格粗算该方向篮子预估盈利($)
//==================================================================
double EstimateProfitAtTpPrice(ENUM_POSITION_TYPE dir, double tpPrice, bool hasPosition,
                               const BasketInfo &basket, double anchor)
{
   double avgPrice = 0.0;
   double totalLot = 0.0;

   if(hasPosition)
   {
      avgPrice = basket.avgPrice;
      totalLot = basket.totalLot;
   }
   else
   {
      int levels;
      if(!GetPlannedBasket(dir, anchor, avgPrice, totalLot, levels))
         return 0.0;
   }

   if(avgPrice <= 0.0 || totalLot <= 0.0 || tpPrice <= 0.0)
      return 0.0;

   double moneyPerPoint = MoneyPerPointPerLot();
   if(moneyPerPoint <= 0.0)
      return 0.0;

   double points = (dir == POSITION_TYPE_BUY) ? (tpPrice - avgPrice) / g_point
                                                : (avgPrice - tpPrice) / g_point;
   if(points < 0.0)
      points = 0.0;

   return points * moneyPerPoint * totalLot;
}

//==================================================================
// 刷新止盈线及线上文字标注(预估盈利金额)
//==================================================================
void RefreshTpLineDisplay(ENUM_POSITION_TYPE dir)
{
   string lineName = GridTpLineName(dir);
   if(ObjectFind(0, lineName) < 0)
      return;

   double tpPrice = RayLineCurrentPrice(lineName);
   if(tpPrice <= 0.0)
      return;

   double anchor = AnchorCurrentPrice(dir);
   BasketInfo basket;
   GatherBasket(dir, basket);
   bool hasPosition = (basket.count > 0);

   double estProfit = EstimateProfitAtTpPrice(dir, tpPrice, hasPosition, basket, anchor);
   string side      = (dir == POSITION_TYPE_BUY) ? "买入" : "卖出";
   string profitStr = StringFormat("预估盈 $%.2f", estProfit);
   string tip       = StringFormat("%s 止盈线(可拖动, 仅显示): %s, 价=%.*f",
                                   side, profitStr, g_digits, tpPrice);

   ObjectSetString(0, lineName, OBJPROP_TEXT,    profitStr);
   ObjectSetString(0, lineName, OBJPROP_TOOLTIP, tip);

   string lblName = GridTpLabelName(dir);
   datetime t     = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t <= 0)
      t = TimeCurrent();

   if(ObjectFind(0, lblName) < 0)
   {
      ObjectCreate(0, lblName, OBJ_TEXT, 0, t, tpPrice);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR,      clrOrange);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE,   9);
      ObjectSetString (0, lblName, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, lblName, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lblName, OBJPROP_HIDDEN,     true);
   }

   ObjectMove(0, lblName, 0, t, tpPrice);
   ObjectSetString(0, lblName, OBJPROP_TEXT, StringFormat("%s %s", side, profitStr));
   ObjectSetInteger(0, lblName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
}

//==================================================================
// 手动交易: 创建止损线(水平射线, 可单独拖动, 不随锚线移动)
//==================================================================
void MakeMaxLossLine(string name, double anchorPrice, ENUM_POSITION_TYPE dir)
{
   double riskPrice;
   double avgPrice;
   double totalLot;
   double lossPoints;
   int levels;

   if(!CalculatePlannedMaxLossPrice(dir, anchorPrice, riskPrice, avgPrice, totalLot, lossPoints, levels))
      return;

   ObjectDelete(0, name);
   ObjectDelete(0, GridMaxLossLabelName(dir));
   CreateHorizontalRay(name, riskPrice, clrOrange, 2, true);

   RefreshSlLineDisplay(dir);
}

//==================================================================
// 手动交易: 更新止损线
//   未手动拖动: 空仓按锚线计划网格推算, 有仓按当前篮子推算位置
//   已手动拖动: 只更新线上预估亏损标注, 不改价格
//==================================================================
void UpdateMaxLossLine(ENUM_POSITION_TYPE dir, double anchor, bool hasPosition, const BasketInfo &basket)
{
   string name = GridMaxLossLineName(dir);

   if(InpMaxFloatingLoss <= 0)
   {
      if(ObjectFind(0, name) >= 0)
         ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      if(ObjectFind(0, GridMaxLossLabelName(dir)) >= 0)
         ObjectSetInteger(0, GridMaxLossLabelName(dir), OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      return;
   }

   if(ObjectFind(0, name) < 0)
      MakeMaxLossLine(name, anchor, dir);

   if(ObjectFind(0, name) < 0)
      return;

   double riskPrice;
   double avgPrice;
   double totalLot;
   double lossPoints;
   int levels;
   bool ok;

   if(hasPosition)
   {
      levels = basket.count;
      ok = CalculateMaxLossPriceFromBasket(dir, basket.avgPrice, basket.totalLot,
                                           riskPrice, lossPoints);
      avgPrice = basket.avgPrice;
      totalLot = basket.totalLot;
   }
   else
   {
      ok = CalculatePlannedMaxLossPrice(dir, anchor, riskPrice, avgPrice, totalLot,
                                        lossPoints, levels);
   }

   if(!ok)
   {
      ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      if(ObjectFind(0, GridMaxLossLabelName(dir)) >= 0)
         ObjectSetInteger(0, GridMaxLossLabelName(dir), OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      return;
   }

   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

   if(!IsSlLineUserSet(dir))
      SetRayLinePrice(name, riskPrice);

   RefreshSlLineDisplay(dir);
}

//==================================================================
// 按止损线价格粗算该方向篮子预估亏损($)
//==================================================================
double EstimateLossAtSlPrice(ENUM_POSITION_TYPE dir, double slPrice, bool hasPosition,
                             const BasketInfo &basket, double anchor)
{
   double avgPrice = 0.0;
   double totalLot = 0.0;

   if(hasPosition)
   {
      avgPrice = basket.avgPrice;
      totalLot = basket.totalLot;
   }
   else
   {
      int levels;
      if(!GetPlannedBasket(dir, anchor, avgPrice, totalLot, levels))
         return 0.0;
   }

   if(avgPrice <= 0.0 || totalLot <= 0.0 || slPrice <= 0.0)
      return 0.0;

   double moneyPerPoint = MoneyPerPointPerLot();
   if(moneyPerPoint <= 0.0)
      return 0.0;

   double points = (dir == POSITION_TYPE_BUY) ? (avgPrice - slPrice) / g_point
                                                : (slPrice - avgPrice) / g_point;
   if(points < 0.0)
      points = 0.0;

   return points * moneyPerPoint * totalLot;
}

//==================================================================
// 刷新止损线及线上文字标注(预估亏损金额)
//==================================================================
void RefreshSlLineDisplay(ENUM_POSITION_TYPE dir)
{
   string lineName = GridMaxLossLineName(dir);
   if(ObjectFind(0, lineName) < 0)
      return;

   double slPrice = RayLineCurrentPrice(lineName);
   if(slPrice <= 0.0)
      return;

   double anchor = AnchorCurrentPrice(dir);
   BasketInfo basket;
   GatherBasket(dir, basket);
   bool hasPosition = (basket.count > 0);

   double estLoss = EstimateLossAtSlPrice(dir, slPrice, hasPosition, basket, anchor);
   string side    = (dir == POSITION_TYPE_BUY) ? "买入" : "卖出";
   string lossStr = StringFormat("预估亏 $%.2f", estLoss);
   string tip     = StringFormat("%s 止损线(可拖动): %s, 价=%.*f, 触价全平",
                                 side, lossStr, g_digits, slPrice);

   ObjectSetString(0, lineName, OBJPROP_TEXT,    lossStr);
   ObjectSetString(0, lineName, OBJPROP_TOOLTIP, tip);

   string lblName = GridMaxLossLabelName(dir);
   datetime t     = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t <= 0)
      t = TimeCurrent();

   if(ObjectFind(0, lblName) < 0)
   {
      ObjectCreate(0, lblName, OBJ_TEXT, 0, t, slPrice);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR,      clrOrange);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE,   9);
      ObjectSetString (0, lblName, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, lblName, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lblName, OBJPROP_HIDDEN,     true);
   }

   ObjectMove(0, lblName, 0, t, slPrice);
   ObjectSetString(0, lblName, OBJPROP_TEXT, StringFormat("%s %s", side, lossStr));
   ObjectSetInteger(0, lblName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
}

//==================================================================
// 手动交易: 按计划网格推算最大浮亏线
//==================================================================
bool CalculatePlannedMaxLossPrice(ENUM_POSITION_TYPE dir, double anchor, double &riskPrice,
                                  double &avgPrice, double &totalLot, double &lossPoints,
                                  int &levels)
{
   if(InpMaxFloatingLoss <= 0 || anchor <= 0.0)
      return false;

   if(!GetPlannedBasket(dir, anchor, avgPrice, totalLot, levels))
      return false;

   return CalculateMaxLossPriceFromBasket(dir, avgPrice, totalLot, riskPrice, lossPoints);
}

//==================================================================
// 最大浮亏线: 用每点价值粗算价格位置
//==================================================================
bool CalculateMaxLossPriceFromBasket(ENUM_POSITION_TYPE dir, double avgPrice, double totalLot,
                                     double &riskPrice, double &lossPoints)
{
   if(InpMaxFloatingLoss <= 0 || avgPrice <= 0.0 || totalLot <= 0.0)
      return false;

   double moneyPerPoint = MoneyPerPointPerLot();
   if(moneyPerPoint <= 0.0)
      return false;

   lossPoints = InpMaxFloatingLoss / (moneyPerPoint * totalLot);
   if(lossPoints <= 0.0)
      return false;

   riskPrice = (dir == POSITION_TYPE_BUY) ? avgPrice - lossPoints * g_point
                                          : avgPrice + lossPoints * g_point;
   riskPrice = NormalizeDouble(riskPrice, g_digits);

   return (riskPrice > 0.0);
}

//==================================================================
// 每 1 手每 1 point 的账户货币价值(近似值)
//==================================================================
double MoneyPerPointPerLot()
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);

   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0 || g_point <= 0.0)
      return 0.0;

   return tickValue * g_point / tickSize;
}

string BuildMaxLossTip(ENUM_POSITION_TYPE dir, string basis, double riskPrice,
                       double avgPrice, double totalLot, double lossPoints, int levels)
{
   string side = (dir == POSITION_TYPE_BUY) ? "买入" : "卖出";
   return StringFormat("%s 最大浮亏预估线(%s): InpMaxFloatingLoss=%.2f, 预估价=%.*f, 均价=%.*f, 总手数=%.2f, 笔数=%d, 距均价约%.0f点",
                       side, basis, InpMaxFloatingLoss,
                       g_digits, riskPrice, g_digits, avgPrice,
                       totalLot, levels, lossPoints);
}

void PrintMaxLossPreviewHint(ENUM_POSITION_TYPE dir, double anchor)
{
   double riskPrice;
   double avgPrice;
   double totalLot;
   double lossPoints;
   int levels;

   if(!CalculatePlannedMaxLossPrice(dir, anchor, riskPrice, avgPrice, totalLot, lossPoints, levels))
   {
      PrintFormat("手动挂单提示: %s 最大浮亏预估线未生成, 请检查 InpMaxFloatingLoss 或品种 tick value。",
                  dir == POSITION_TYPE_BUY ? "买入" : "卖出");
      return;
   }

   PrintFormat("手动挂单提示: %s 预估最大浮亏线=%.*f, 按计划%d笔/总手数%.2f/均价%.*f 粗算, 约亏损 %.2f (距均价 %.0f 点)。实际全局风控仍以实时总浮亏为准。",
               dir == POSITION_TYPE_BUY ? "买入" : "卖出",
               g_digits, riskPrice, levels, totalLot, g_digits, avgPrice,
               InpMaxFloatingLoss, lossPoints);
}

//==================================================================
// 手动交易: 每个 tick 检查首单触发线是否被实时价格穿越
//==================================================================
void CheckManualTriggers()
{
   CheckEntryTrigger(POSITION_TYPE_BUY);
   CheckEntryTrigger(POSITION_TYPE_SELL);
   CheckStopLossLineTouch();
}

//==================================================================
// 手动交易: 价格触达止损线 -> 全平(与全局浮亏止损一致)
//==================================================================
void CheckStopLossLineTouch()
{
   if(InpMaxFloatingLoss <= 0)
      return;

   if(CheckStopLossLineForDir(POSITION_TYPE_BUY))
      return;
   CheckStopLossLineForDir(POSITION_TYPE_SELL);
}

bool CheckStopLossLineForDir(ENUM_POSITION_TYPE dir)
{
   string name = GridMaxLossLineName(dir);
   if(ObjectFind(0, name) < 0)
      return false;
   if(ObjectGetInteger(0, name, OBJPROP_TIMEFRAMES) == OBJ_NO_PERIODS)
      return false;

   double slPrice = RayLineCurrentPrice(name);
   if(slPrice <= 0.0)
      return false;

   // 至少有一笔本 EA 持仓才执行止损
   bool hasAnyPos = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Magic() != InpMagic) continue;
      if(g_posInfo.Symbol() != _Symbol) continue;
      hasAnyPos = true;
      break;
   }
   if(!hasAnyPos)
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool touched = (dir == POSITION_TYPE_BUY) ? (bid <= slPrice)
                                               : (ask >= slPrice);
   if(!touched)
      return false;

   string side = (dir == POSITION_TYPE_BUY) ? "买入" : "卖出";
   CloseAllPositions(StringFormat("止损线触达(%s, 价%.*f), 强制全平", side, g_digits, slPrice));
   return true;
}

//==================================================================
// 手动交易: 检查某方向首单触发线(用实时 Bid/Ask)
//==================================================================
void CheckEntryTrigger(ENUM_POSITION_TYPE dir)
{
   double linePrice = AnchorCurrentPrice(dir);
   if(linePrice <= 0.0)
      return;

   BasketInfo basket;
   GatherBasket(dir, basket);
   if(HasDirectionOrdersOrPositions(dir))
     {
      DeleteTriggerGridLines(dir);
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool triggered = (dir == POSITION_TYPE_BUY) ? (bid <= linePrice)
                                               : (ask >= linePrice);
   if(!triggered)
      return;

   if(!OpenFirstOrder(dir))
      return;

   DeleteTriggerGridLines(dir);
   ChartRedraw();
   PrintFormat("手动触发(Tick): %s 首单已开(触发价 %.*f, Bid=%.*f Ask=%.*f), 挂单触发线已删除",
               dir == POSITION_TYPE_BUY ? "买入" : "卖出",
               g_digits, linePrice, g_digits, bid, g_digits, ask);
}

//==================================================================
// 顶部信息面板
//==================================================================
int InfoPanelStartY()
{
   return InpManualTrade ? 72 : 20;
}

string InfoLineName(int index)
{
   return g_infoPrefix + IntegerToString(index);
}

void CreateInfoPanelBg(int y0)
{
   int padTop = 4;
   int padBot = 6;
   int bgH    = g_infoLineCount * g_infoLineHeight + padTop + padBot;

   ObjectDelete(0, g_infoBgName);
   ObjectCreate(0, g_infoBgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_XDISTANCE,  6);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_YDISTANCE,  y0 - padTop);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_XSIZE,      g_infoBgWidth);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_YSIZE,      bgH);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_BGCOLOR,    ColorToARGB(C'22,26,34', 215));
   ObjectSetInteger(0, g_infoBgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_COLOR,      clrDimGray);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_infoBgName, OBJPROP_HIDDEN,     true);
}

void CreateInfoPanel()
{
   int y0 = InfoPanelStartY();
   CreateInfoPanelBg(y0);

   for(int i = 0; i < g_infoLineCount; i++)
   {
      string nm = InfoLineName(i);
      ObjectDelete(0, nm);
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE,   14);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE,   y0 + i * g_infoLineHeight);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,    g_infoFontSize);
      ObjectSetString (0, nm, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_COLOR,     clrWhite);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,    true);
      ObjectSetString (0, nm, OBJPROP_TEXT,      "");
   }
   UpdateInfoPanel();
}

void DeleteInfoPanel()
{
   ObjectDelete(0, g_infoBgName);
   for(int i = 0; i < g_infoLineCount; i++)
      ObjectDelete(0, InfoLineName(i));
}

void SetInfoLine(int index, string text, color clr)
{
   if(index < 0 || index >= g_infoLineCount)
      return;
   string nm = InfoLineName(index);
   if(ObjectFind(0, nm) < 0)
      return;
   ObjectSetString (0, nm, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
}

void FormatDirectionInfo(ENUM_POSITION_TYPE dir, string &line1, string &line2)
{
   string side = (dir == POSITION_TYPE_BUY) ? "多" : "空";
   BasketInfo b;
   GatherBasket(dir, b);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double px  = (dir == POSITION_TYPE_BUY) ? bid : ask;

   if(b.count > 0)
   {
      line1 = StringFormat("%s %d/%d | 均%.*f | %.2f手 | $%+.2f",
                           side, b.count, InpMaxAddLevels,
                           g_digits, b.avgPrice, b.totalLot, b.profit);

      if(b.count >= InpMaxAddLevels)
      {
         line2 = "加仓: 已满层";
      }
      else
      {
         double stepPts = GetStepPointsForLevel(b.count);
         double trigger = (dir == POSITION_TYPE_BUY)
                          ? b.lastEntry - stepPts * g_point
                          : b.lastEntry + stepPts * g_point;
         double distPts = (dir == POSITION_TYPE_BUY)
                          ? (px - trigger) / g_point
                          : (trigger - px) / g_point;
         double nextLot = GetLotForLevel(b.count);
         line2 = StringFormat("下档%.*f 差%.0f点 手%.2f",
                              g_digits, trigger, distPts, nextLot);
      }

      bool trailOn = (dir == POSITION_TYPE_BUY) ? g_trailActiveBuy : g_trailActiveSell;
      double tpPrice = GetEffectiveTpPrice(dir, b);
      string tpPart = trailOn
                      ? StringFormat(" | 跟踪TP %.*f", g_digits, tpPrice)
                      : StringFormat(" | TP %.*f", g_digits, tpPrice);
      line2 += tpPart;
      return;
   }

   double anchor = AnchorCurrentPrice(dir);
   if(anchor > 0.0)
   {
      double distTrigger = (dir == POSITION_TYPE_BUY)
                           ? (px - anchor) / g_point
                           : (anchor - px) / g_point;

      double riskPrice, avgPrice, totalLot, lossPoints;
      int    levels;
      string planStr = "计划: --";
      if(CalculatePlannedMaxLossPrice(dir, anchor, riskPrice, avgPrice, totalLot, lossPoints, levels))
         planStr = StringFormat("打满%.2f手 亏线%.*f", totalLot, g_digits, riskPrice);

      double tpDist = InpTpPoints * g_point;
      double tpPrev = (dir == POSITION_TYPE_BUY) ? anchor + tpDist : anchor - tpDist;

      line1 = StringFormat("%s 挂网 | 锚%.*f 距触发%.0f点", side, g_digits, anchor, distTrigger);
      line2 = StringFormat("%s | 止盈预览%.*f", planStr, g_digits, tpPrev);
      return;
   }

   line1 = StringFormat("%s 空仓 | 未挂网格", side);
   line2 = InpManualTrade ? "点「买入/卖出」挂网格预设" : "等待自动首单条件";
}

void UpdateInfoPanel()
{
   if(ObjectFind(0, InfoLineName(0)) < 0)
      return;

   double totalFloat = GetTotalFloatingProfit();
   string floatStr;
   if(InpMaxFloatingLoss > 0)
      floatStr = StringFormat("$%+.0f / 限$%.0f", totalFloat, -InpMaxFloatingLoss);
   else
      floatStr = StringFormat("$%+.2f", totalFloat);

   double swapLot     = InpFirstLot;
   double swapBuyDay  = CalcDailySwapMoney(POSITION_TYPE_BUY,  swapLot);
   double swapSellDay = CalcDailySwapMoney(POSITION_TYPE_SELL, swapLot);
   string swapDayStr = StringFormat("库存%.2f手/日 多%s 空%s",
                                    swapLot,
                                    FormatSwapMoney(swapBuyDay),
                                    FormatSwapMoney(swapSellDay));

   SetInfoLine(0, StringFormat("NeoEA_XU | 合计%s", floatStr), clrWhite);
   SetInfoLine(1, StringFormat("%s | 手动%s", swapDayStr, InpManualTrade ? "开" : "关"), clrSilver);

   int buyLine1  = 0;
   int buyLine2  = 0;
   int gapSell   = 0;
   int sellLine1 = 0;
   int sellLine2 = 0;
   int gapMeta   = 0;
   int metaLine  = 0;

   if(InpUseDynamicStep)
   {
      string grid1, grid2;
      FormatAtrGridPanel(grid1, grid2);
      SetInfoLine(2, grid1, clrGold);
      SetInfoLine(3, grid2, clrKhaki);
      SetInfoLine(4, " ", clrNONE);
      buyLine1  = 5;
      buyLine2  = 6;
      gapSell   = 7;
      sellLine1 = 8;
      sellLine2 = 9;
      gapMeta   = 10;
      metaLine  = 11;
   }
   else
   {
      double stepPts = GetStepPointsForLevel(0);
      double stepPx  = stepPts * g_point;
      SetInfoLine(2, StringFormat("固定网格 | 间距%.0f点 (%.*f)", stepPts, g_digits, stepPx), clrSilver);
      SetInfoLine(3, " ", clrNONE);
      buyLine1  = 4;
      buyLine2  = 5;
      gapSell   = 6;
      sellLine1 = 7;
      sellLine2 = 8;
      gapMeta   = 9;
      metaLine  = 10;
   }

   string buy1, buy2, sell1, sell2;
   FormatDirectionInfo(POSITION_TYPE_BUY,  buy1,  buy2);
   FormatDirectionInfo(POSITION_TYPE_SELL, sell1, sell2);

   SetInfoLine(buyLine1,  buy1,  clrSeaGreen);
   SetInfoLine(buyLine2,  buy2,  clrPaleGreen);
   SetInfoLine(gapSell,   " ",   clrNONE);
   SetInfoLine(sellLine1, sell1, clrFireBrick);
   SetInfoLine(sellLine2, sell2, clrLightPink);
   SetInfoLine(gapMeta,   " ",   clrNONE);

   string trailStr = InpUseTrailingTp
                     ? StringFormat("跟踪TP+%d 回撤%d", InpTpPoints, InpTrailPoints)
                     : StringFormat("TP+%d", InpTpPoints);
   SetInfoLine(metaLine, StringFormat("层%d 首%.2f×%.2f %s 风控$%.0f",
                                      InpMaxAddLevels, InpFirstLot, InpLotMultiplier,
                                      trailStr, InpMaxFloatingLoss), clrDarkGray);

   // 固定模式少一行网格, 底部补空行使面板高度与动态模式一致
   if(!InpUseDynamicStep)
      SetInfoLine(11, " ", clrNONE);
}

//==================================================================
// 解析禁止交易小时字符串(如 "1,2,12,13"), 填入 g_noTradeHour 表
//==================================================================
void ParseNoTradeHours()
{
   for(int i = 0; i < 24; i++)
      g_noTradeHour[i] = false;

   string parts[];
   int n = StringSplit(InpNoTradeHours, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s == "")
         continue;

      int hour = (int)StringToInteger(s);
      if(hour >= 0 && hour <= 23)
         g_noTradeHour[hour] = true;
   }
}

//==================================================================
// 当前小时是否处于禁止交易时段
//==================================================================
bool IsNoTradeHour()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return g_noTradeHour[t.hour];
}
//+------------------------------------------------------------------+