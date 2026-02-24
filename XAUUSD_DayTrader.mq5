//+------------------------------------------------------------------+
//|                    XAUUSD Conservative Day Trader EA             |
//|                        MQL5 - MetaTrader 5                       |
//|   Strategy: EMA Trend Filter + RSI Entry + ATR-based SL/TP      |
//+------------------------------------------------------------------+
#property copyright "Sample EA - Use at your own risk"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input group "=== TRADE SETTINGS ==="
input double   InpLotSize        = 0.05;    // Fixed Lot Size (keep small for safety)
input double   InpRiskPercent    = 1.0;     // Risk % per trade (if using dynamic lots)
input bool     InpUseDynamicLot  = false;   // Use Dynamic Lot Sizing
input int      InpMaxPositions   = 1;       // Max simultaneous positions
input int      InpMagicNumber    = 202401;  // EA Magic Number

input group "=== INDICATORS ==="
input int      InpFastEMA        = 21;      // Fast EMA Period
input int      InpSlowEMA        = 50;      // Slow EMA Period
input int      InpTrendEMA       = 200;     // Trend EMA Period
input int      InpRSIPeriod      = 14;      // RSI Period
input double   InpRSIOverBought  = 65.0;    // RSI Overbought Level (conservative: 65)
input double   InpRSIOverSold    = 35.0;    // RSI Oversold Level  (conservative: 35)
input int      InpATRPeriod      = 14;      // ATR Period

input group "=== RISK MANAGEMENT ==="
input double   InpSLMultiplier   = 1.5;     // SL = ATR x Multiplier
input double   InpTPMultiplier   = 2.5;     // TP = ATR x Multiplier (RR ~1:1.67)
input double   InpBreakevenATR   = 1.0;     // Move SL to BE after price moves X * ATR
input bool     InpUseBreakeven   = true;    // Enable Breakeven
input double   InpTrailingATR    = 1.0;     // Trailing Stop: X * ATR (0 = disabled)
input bool     InpUseTrailing    = true;    // Enable Trailing Stop

input group "=== SESSION FILTER (Server Time) ==="
input int      InpSessionStart   = 8;       // Trading Session Start Hour (e.g. 8 = 08:00)
input int      InpSessionEnd     = 20;      // Trading Session End Hour   (e.g. 20 = 20:00)
input bool     InpNoTradeOnFriday= true;    // Avoid new trades on Friday afternoon
input int      InpFridayCutoff   = 16;      // Friday: no new trades after this hour

input group "=== EOD / OVERNIGHT PROTECTION ==="
input bool     InpCloseEOD       = true;    // Chiudi tutto a fine giornata (End of Day)
input int      InpCloseHour      = 21;      // Ora di chiusura forzata (ora server, es. 21:00)
input int      InpCloseMinute    = 0;       // Minuto di chiusura forzata
input bool     InpCloseFriday    = true;    // Chiudi tutto il venerdì pomeriggio
input int      InpFridayCloseHour= 20;      // Venerdì: chiudi a quest'ora
input int      InpFridayCloseMin = 0;       // Venerdì: minuto di chiusura

input group "=== FILTERS ==="
input int      InpMinBarsBetween = 5;       // Min bars between trades (avoid over-trading)
input double   InpMinSpreadPts   = 0;       // Skip trade if spread > X points (0=disabled)
input double   InpMaxSpreadPts   = 50;      // Max allowed spread in points

//--- Global Variables
CTrade         trade;
CPositionInfo  posInfo;

int    handleFastEMA, handleSlowEMA, handleTrendEMA, handleRSI, handleATR;
double fastEMA[], slowEMA[], trendEMA[], rsi[], atr[];

datetime lastTradeTime  = 0;
int      barsSinceTrade = 0;
bool     eodClosedToday = false;   // Flag: posizioni già chiuse oggi a EOD
datetime lastEODCheck   = 0;       // Ultima data in cui è stato fatto EOD close

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Validate symbol
   if(Symbol() != "XAUUSD" && Symbol() != "GOLD")
      Print("WARNING: EA designed for XAUUSD. Current symbol: ", Symbol());

   // Create indicator handles
   handleFastEMA  = iMA(_Symbol, PERIOD_H1, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, PERIOD_H1, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, PERIOD_H1, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, PERIOD_H1, InpATRPeriod);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleTrendEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE || handleATR == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(fastEMA,  true);
   ArraySetAsSeries(slowEMA,  true);
   ArraySetAsSeries(trendEMA, true);
   ArraySetAsSeries(rsi,      true);
   ArraySetAsSeries(atr,      true);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("XAUUSD Day Trader EA Initialized. MagicNumber=", InpMagicNumber);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleTrendEMA);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- EOD / OVERNIGHT PROTECTION (ogni tick) ---
   CheckEODClose();

   // Only process on new H1 bar (reduce CPU and avoid re-entries)
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBar == lastBar) 
     {
      // Still manage open positions on every tick
      ManagePositions();
      return;
     }
   lastBar = currentBar;
   barsSinceTrade++;

   // Reset flag EOD a inizio nuova giornata
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   MqlDateTime dtLast;
   TimeToStruct(lastEODCheck, dtLast);
   if(dtNow.day != dtLast.day)
      eodClosedToday = false;

   // Refresh indicator buffers
   if(!RefreshBuffers()) return;

   // Session & time filters
   if(!IsWithinSession()) return;

   // Spread filter
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(InpMaxSpreadPts > 0 && spread > InpMaxSpreadPts * _Point)
     {
      Print("Spread too high: ", DoubleToString(spread/_Point, 1), " pts. Skipping.");
      return;
     }

   // Bar filter
   if(barsSinceTrade < InpMinBarsBetween) return;

   // Count open EA positions
   if(CountPositions() >= InpMaxPositions) return;

   // Signal logic
   CheckForEntry();
  }

//+------------------------------------------------------------------+
//| Refresh all indicator buffers                                    |
//+------------------------------------------------------------------+
bool RefreshBuffers()
  {
   if(CopyBuffer(handleFastEMA,  0, 0, 3, fastEMA)  < 3) return false;
   if(CopyBuffer(handleSlowEMA,  0, 0, 3, slowEMA)  < 3) return false;
   if(CopyBuffer(handleTrendEMA, 0, 0, 3, trendEMA) < 3) return false;
   if(CopyBuffer(handleRSI,      0, 0, 3, rsi)      < 3) return false;
   if(CopyBuffer(handleATR,      0, 0, 2, atr)      < 2) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Check session hours                                              |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Day of week: 0=Sun, 5=Fri, 6=Sat
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false; // No weekend
   if(InpNoTradeOnFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCutoff) return false;

   if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Count positions opened by this EA                               |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void CheckForEntry()
  {
   double price   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atrVal  = atr[1]; // Use previous closed bar ATR

   // --- LONG CONDITION ---
   // 1. Price above 200 EMA (uptrend)
   // 2. Fast EMA crosses above Slow EMA (previous bar: fast <= slow, current: fast > slow)
   // 3. RSI between oversold and 55 (not overbought, fresh momentum)
   bool longSignal = (price > trendEMA[1])
                  && (fastEMA[1] > slowEMA[1])   // current bar: fast above slow
                  && (fastEMA[2] <= slowEMA[2])  // previous bar: fast was at or below slow
                  && (rsi[1] > InpRSIOverSold)
                  && (rsi[1] < 55.0);            // not overbought territory

   // --- SHORT CONDITION ---
   // 1. Price below 200 EMA (downtrend)
   // 2. Fast EMA crosses below Slow EMA
   // 3. RSI between overbought and 45
   bool shortSignal = (price < trendEMA[1])
                   && (fastEMA[1] < slowEMA[1])
                   && (fastEMA[2] >= slowEMA[2])
                   && (rsi[1] < InpRSIOverBought)
                   && (rsi[1] > 45.0);

   double sl, tp, lots;
   double slPoints = atrVal * InpSLMultiplier;
   double tpPoints = atrVal * InpTPMultiplier;

   if(longSignal)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl   = NormalizeDouble(ask - slPoints, _Digits);
      tp   = NormalizeDouble(ask + tpPoints, _Digits);
      lots = CalculateLots(slPoints);

      if(trade.Buy(lots, _Symbol, ask, sl, tp, "XAUUSD_Long"))
        {
         barsSinceTrade = 0;
         Print("LONG opened | Lots:", lots, " | SL:", sl, " | TP:", tp, " | ATR:", atrVal);
        }
     }
   else if(shortSignal)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl   = NormalizeDouble(bid + slPoints, _Digits);
      tp   = NormalizeDouble(bid - tpPoints, _Digits);
      lots = CalculateLots(slPoints);

      if(trade.Sell(lots, _Symbol, bid, sl, tp, "XAUUSD_Short"))
        {
         barsSinceTrade = 0;
         Print("SHORT opened | Lots:", lots, " | SL:", sl, " | TP:", tp, " | ATR:", atrVal);
        }
     }
  }

//+------------------------------------------------------------------+
//| Calculate lot size based on risk %                              |
//+------------------------------------------------------------------+
double CalculateLots(double slDistance)
  {
   if(!InpUseDynamicLot) return InpLotSize;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize == 0 || tickValue == 0) return InpLotSize;

   double lotSize = riskAmount / (slDistance / tickSize * tickValue);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   return NormalizeDouble(lotSize, 2);
  }

//+------------------------------------------------------------------+
//| Manage open positions: Breakeven + Trailing Stop               |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!RefreshBuffers()) return;
   double atrVal = atr[1];

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      double openPrice  = posInfo.PriceOpen();
      double currentSL  = posInfo.StopLoss();
      double currentTP  = posInfo.TakeProfit();
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ulong  ticket     = posInfo.Ticket();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double beLevel   = openPrice + atrVal * InpBreakevenATR;
         double trailStop = currentBid - atrVal * InpTrailingATR;
         double newSL     = currentSL;

         // Breakeven
         if(InpUseBreakeven && currentBid >= beLevel && currentSL < openPrice)
            newSL = NormalizeDouble(openPrice + _Point, _Digits);

         // Trailing Stop (only moves SL up, never down)
         if(InpUseTrailing && trailStop > newSL && trailStop > openPrice)
            newSL = NormalizeDouble(trailStop, _Digits);

         if(newSL > currentSL + _Point)
            trade.PositionModify(ticket, newSL, currentTP);
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double beLevel   = openPrice - atrVal * InpBreakevenATR;
         double trailStop = currentAsk + atrVal * InpTrailingATR;
         double newSL     = currentSL;

         // Breakeven
         if(InpUseBreakeven && currentAsk <= beLevel && (currentSL > openPrice || currentSL == 0))
            newSL = NormalizeDouble(openPrice - _Point, _Digits);

         // Trailing Stop (only moves SL down, never up)
         if(InpUseTrailing && (trailStop < newSL || newSL == 0) && trailStop < openPrice)
            newSL = NormalizeDouble(trailStop, _Digits);

         if(currentSL == 0 || newSL < currentSL - _Point)
            trade.PositionModify(ticket, newSL, currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| EOD / Overnight Protection: chiude tutto a fine giornata        |
//+------------------------------------------------------------------+
void CheckEODClose()
  {
   if(eodClosedToday) return;  // Già chiuso oggi, non fare nulla

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   bool shouldClose = false;
   string reason    = "";

   // --- Chiusura fine giornata (Lunedì-Giovedì) ---
   if(InpCloseEOD && dt.day_of_week >= 1 && dt.day_of_week <= 4)
     {
      if(dt.hour > InpCloseHour ||
        (dt.hour == InpCloseHour && dt.min >= InpCloseMinute))
        {
         shouldClose = true;
         reason = "EOD Close - Fine giornata ore " +
                  IntegerToString(InpCloseHour) + ":" +
                  IntegerToString(InpCloseMinute);
        }
     }

   // --- Chiusura venerdì pomeriggio ---
   if(InpCloseFriday && dt.day_of_week == 5)
     {
      if(dt.hour > InpFridayCloseHour ||
        (dt.hour == InpFridayCloseHour && dt.min >= InpFridayCloseMin))
        {
         shouldClose = true;
         reason = "Friday Close - Chiusura weekend ore " +
                  IntegerToString(InpFridayCloseHour) + ":" +
                  IntegerToString(InpFridayCloseMin);
        }
     }

   if(!shouldClose) return;

   // Conta le posizioni aperte dall'EA
   int posCount = CountPositions();
   if(posCount == 0)
     {
      eodClosedToday = true;
      lastEODCheck   = TimeCurrent();
      return;
     }

   // Chiudi tutte le posizioni dell'EA
   Print("=== ", reason, " | Chiusura ", posCount, " posizione/i aperte ===");

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      ulong  ticket = posInfo.Ticket();
      double profit = posInfo.Profit();

      if(trade.PositionClose(ticket, 20))
         Print("Posizione #", ticket, " chiusa. P&L: ", DoubleToString(profit, 2), "$");
      else
         Print("ERRORE chiusura posizione #", ticket, " | Errore: ", GetLastError());
     }

   eodClosedToday = true;
   lastEODCheck   = TimeCurrent();
  }

//+------------------------------------------------------------------+
