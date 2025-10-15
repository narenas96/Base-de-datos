-- (Q3) 90-day trading behavior & performance features
-- Goal: Capture a trader’s style and skill for copy-trading recommendations.
-- win_rate_90d, realized_pnl_usd_90d → performance;
-- avg_trade_notional_usd_90d → size;
-- instruments_traded_90d & currencies_traded_90d → diversification / style

WITH time_frame AS ( -- Renamed from 'window' to avoid the reserved keyword error
  SELECT now()::timestamptz AS as_of, (now() - interval '90 days')::timestamptz AS since
),
latest_fx AS (
  SELECT c.code AS currency,
           COALESCE((
             SELECT er.rate FROM exchange_rates er
             WHERE er.base_currency = c.code AND er.quote_currency = 'USD'
             ORDER BY er.as_of DESC LIMIT 1
           ), 1.0)::numeric AS to_usd
  FROM currencies c
),
fills AS (
  SELECT o.account_id, a.user_id, o.side, f.quantity, f.price, i.quote_currency, f.fill_ts, i.symbol, i.id AS instrument_id
  FROM orders o
  JOIN order_fills f ON f.order_id = o.id
  JOIN accounts a ON a.id = o.account_id
  JOIN instruments i ON i.id = o.instrument_id
  , time_frame w -- Reference updated
  WHERE f.fill_ts >= w.since
),
per_user AS (
  SELECT f.user_id,
           COUNT(*) AS trade_count_90d,
           -- This logic for winning trades is based on the filled price and quantity,
           -- assuming 'profit' means the trade was a 'sell' (generating cash) or a 'buy' (consuming cash)
           -- where the resulting cash flow is positive. This seems highly specific/custom.
           -- I've left the original logic, assuming it's what you intended for profit/loss calculation.
           COUNT(*) FILTER (WHERE (CASE WHEN f.side='sell' THEN f.quantity*f.price
                                         ELSE -f.quantity*f.price END) > 0) AS winning_trades_90d,
           AVG(ABS(f.quantity*f.price)*COALESCE(fx.to_usd,1.0)) AS avg_trade_notional_usd_90d,
           COUNT(DISTINCT f.quote_currency) AS currencies_traded_90d
  FROM fills f
  LEFT JOIN latest_fx fx ON fx.currency = f.quote_currency
  GROUP BY f.user_id
),
realized AS (
  SELECT f.user_id,
           SUM(
             (CASE WHEN f.side='sell' THEN f.quantity*f.price
                   ELSE -f.quantity*f.price END)
             * COALESCE(fx.to_usd,1.0)
           ) AS realized_pnl_usd_90d,
           -- FIX: Join on i.id to correctly count instruments based on the fills table
           COUNT(DISTINCT f.symbol) AS instruments_traded_90d
  FROM fills f
  -- Removed the JOIN on 'instruments i ON i.quote_currency = f.quote_currency' 
  -- because 'fills' already contains the instrument data (i.symbol) via the original joins.
  LEFT JOIN latest_fx fx ON fx.currency = f.quote_currency
  GROUP BY f.user_id
)
SELECT u.id AS user_id,
        COALESCE(p.trade_count_90d,0) AS trade_count_90d,
        CASE WHEN COALESCE(p.trade_count_90d,0)=0 THEN 0.0
             ELSE p.winning_trades_90d::numeric / p.trade_count_90d::numeric
        END AS win_rate_90d,
        COALESCE(p.avg_trade_notional_usd_90d,0) AS avg_trade_notional_usd_90d,
        COALESCE(r.realized_pnl_usd_90d,0) AS realized_pnl_usd_90d,
        COALESCE(r.instruments_traded_90d,0) AS instruments_traded_90d,
        COALESCE(p.currencies_traded_90d,0) AS currencies_traded_90d
FROM users u
LEFT JOIN per_user p ON p.user_id = u.id
LEFT JOIN realized r ON r.user_id = u.id;