-- (Q4) Concentration risk (Herfindahl-Hirschman Index) on open exposure
-- Goal: Feature that measures how concentrated a user’s open positions are.
-- hhi_open_positions ≈ sum of squared weights (0–1).
-- Near 1 → highly concentrated (single bet).
-- Lower values → diversified.
-- Add margin_enabled to capture leverage risk appetite.

WITH latest_fx AS (
  SELECT c.code AS currency,
         COALESCE((
           SELECT er.rate FROM exchange_rates er
           WHERE er.base_currency = c.code AND er.quote_currency = 'USD'
           ORDER BY er.as_of DESC LIMIT 1
         ), 1.0)::numeric AS to_usd
  FROM currencies c
),
latest_price AS (
  SELECT DISTINCT ON (ip.instrument_id)
         ip.instrument_id, ip.price
  FROM instrument_prices ip
  ORDER BY ip.instrument_id, ip.as_of DESC
),
open_value AS (
  SELECT a.user_id, p.instrument_id,
         (COALESCE(lp.price,0)*p.quantity * COALESCE(fx.to_usd,1.0)) AS position_value_usd
  FROM positions p
  JOIN accounts a ON a.id = p.account_id
  LEFT JOIN instruments i ON i.id = p.instrument_id
  LEFT JOIN latest_price lp ON lp.instrument_id = p.instrument_id
  LEFT JOIN latest_fx fx ON fx.currency = i.quote_currency
  WHERE p.status = 'open'
),
weights AS (
  SELECT user_id,
         instrument_id,
         position_value_usd,
         position_value_usd / NULLIF(SUM(position_value_usd) OVER (PARTITION BY user_id),0) AS w
  FROM open_value
)
SELECT u.id AS user_id,
       COALESCE(SUM(w.w*w.w) FILTER (WHERE w.user_id=u.id), 0) AS hhi_open_positions, -- actually sum(w^2)
       COUNT(DISTINCT w.instrument_id) FILTER (WHERE w.user_id=u.id) AS distinct_instruments_open,
       EXISTS (SELECT 1 FROM accounts a WHERE a.user_id=u.id AND a.is_margin_enabled) AS margin_enabled
FROM users u
LEFT JOIN weights w ON w.user_id = u.id
GROUP BY u.id;
