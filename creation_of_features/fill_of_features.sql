BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '5min';
SET LOCAL idle_in_transaction_session_timeout = '10min';
SET LOCAL transaction_isolation = 'read committed';

-- ========== 1) CORE: equity, net deposits, money won, label ==========
WITH params AS (
  SELECT CURRENT_DATE::date AS as_of_date
),
latest_fx AS (
  SELECT c.code AS currency,
         COALESCE((
           SELECT er.rate
           FROM exchange_rates er
           WHERE er.base_currency = c.code AND er.quote_currency = 'USD'
           ORDER BY er.as_of DESC LIMIT 1
         ), 1.0)::numeric AS to_usd
  FROM currencies c
),
latest_price AS (
  SELECT DISTINCT ON (ip.instrument_id) ip.instrument_id, ip.price
  FROM instrument_prices ip
  ORDER BY ip.instrument_id, ip.as_of DESC
),
cash_usd AS (
  SELECT a.user_id,
         COALESCE(SUM(ab.cash_available * COALESCE(fx.to_usd,1.0)), 0) AS cash_usd
  FROM accounts a
  JOIN account_balances ab ON ab.account_id = a.id
  LEFT JOIN latest_fx fx   ON fx.currency = ab.currency
  GROUP BY a.user_id
),
unrealized_usd AS (
  SELECT a.user_id,
         COALESCE(SUM((COALESCE(lp.price,0) - COALESCE(p.avg_price,0)) * p.quantity
                      * COALESCE(fx_q.to_usd,1.0)), 0) AS upl_usd
  FROM positions p
  JOIN accounts a         ON a.id = p.account_id
  JOIN instruments i      ON i.id = p.instrument_id
  LEFT JOIN latest_price lp ON lp.instrument_id = i.id
  LEFT JOIN latest_fx fx_q  ON fx_q.currency = i.quote_currency
  WHERE p.status = 'open'
  GROUP BY a.user_id
),
deposits_usd AS (
  SELECT a.user_id,
         COALESCE(SUM(d.amount * COALESCE(fx.to_usd,1.0)), 0) AS dep_usd
  FROM deposits d
  JOIN accounts a    ON a.id = d.account_id
  LEFT JOIN latest_fx fx ON fx.currency = a.base_currency
  GROUP BY a.user_id
),
withdrawals_usd AS (
  SELECT a.user_id,
         COALESCE(SUM(w.amount * COALESCE(fx.to_usd,1.0)), 0) AS wdr_usd,
         COALESCE(SUM(w.fee    * COALESCE(fx.to_usd,1.0)), 0) AS fee_usd
  FROM withdrawals w
  JOIN accounts a    ON a.id = w.account_id
  LEFT JOIN latest_fx fx ON fx.currency = a.base_currency
  GROUP BY a.user_id
),
core_final AS (
  SELECT u.id AS user_id,
         (cu.cash_usd + COALESCE(upl.upl_usd,0)) AS equity_usd,
         (COALESCE(d.dep_usd,0) - (COALESCE(w.wdr_usd,0) + COALESCE(w.fee_usd,0))) AS net_dep_usd
  FROM users u
  LEFT JOIN cash_usd       cu  ON cu.user_id  = u.id
  LEFT JOIN unrealized_usd upl ON upl.user_id = u.id
  LEFT JOIN deposits_usd   d   ON d.user_id   = u.id
  LEFT JOIN withdrawals_usd w  ON w.user_id   = u.id
)
INSERT INTO feat.user_features_core
  (user_id, as_of_date, equity_usd, net_dep_usd, money_won_usd, status_label, created_at, updated_at)
SELECT c.user_id,
       p.as_of_date,
       c.equity_usd,
       c.net_dep_usd,
       (c.equity_usd - c.net_dep_usd)                                  AS money_won_usd,
       CASE WHEN (c.equity_usd - c.net_dep_usd) > 0 THEN 'winning'
            WHEN (c.equity_usd - c.net_dep_usd) < 0 THEN 'losing'
            ELSE 'even'
       END                                                              AS status_label,
       now(), now()
FROM core_final c
CROSS JOIN params p
ON CONFLICT (user_id, as_of_date) DO UPDATE
SET equity_usd    = EXCLUDED.equity_usd,
    net_dep_usd   = EXCLUDED.net_dep_usd,
    money_won_usd = EXCLUDED.money_won_usd,
    status_label  = EXCLUDED.status_label,
    updated_at    = now();

-- ========== 2) ONBOARDING: funnel timestamps + speeds ==========
WITH params AS (
  SELECT CURRENT_DATE::date AS as_of_date
),
first_install AS (
  SELECT d.user_id, MIN(d.installed_at) AS installed_at
  FROM devices d GROUP BY d.user_id
),
first_kyc AS (
  SELECT k.user_id, MIN(k.submitted_at) AS kyc_submitted_at,
         MIN(k.reviewed_at) AS kyc_reviewed_at
  FROM kyc_profiles k GROUP BY k.user_id
),
first_deposit AS (
  SELECT a.user_id, MIN(d.created_at) AS first_deposit_at
  FROM deposits d JOIN accounts a ON a.id = d.account_id
  GROUP BY a.user_id
),
first_trade AS (
  SELECT a.user_id, MIN(o.placed_at) AS first_trade_at
  FROM orders o JOIN accounts a ON a.id = o.account_id
  GROUP BY a.user_id
)
INSERT INTO feat.user_features_onboarding
(user_id, as_of_date, installed_at, kyc_submitted_at, kyc_reviewed_at, first_deposit_at, first_trade_at,
 hrs_install_to_kyc_submit, hrs_kyc_submit_to_review, hrs_review_to_deposit, hrs_deposit_to_trade,
 deposited, traded, created_at, updated_at)
SELECT u.id,
       p.as_of_date,
       fi.installed_at,
       fk.kyc_submitted_at,
       fk.kyc_reviewed_at,
       fd.first_deposit_at,
       ft.first_trade_at,
       EXTRACT(EPOCH FROM (fk.kyc_submitted_at - fi.installed_at))/3600,
       EXTRACT(EPOCH FROM (fk.kyc_reviewed_at   - fk.kyc_submitted_at))/3600,
       EXTRACT(EPOCH FROM (fd.first_deposit_at  - fk.kyc_reviewed_at))/3600,
       EXTRACT(EPOCH FROM (ft.first_trade_at    - fd.first_deposit_at))/3600,
       (fd.first_deposit_at IS NOT NULL),
       (ft.first_trade_at   IS NOT NULL),
       now(), now()
FROM users u
CROSS JOIN params p
LEFT JOIN first_install fi ON fi.user_id = u.id
LEFT JOIN first_kyc fk     ON fk.user_id = u.id
LEFT JOIN first_deposit fd ON fd.user_id = u.id
LEFT JOIN first_trade ft   ON ft.user_id = u.id
ON CONFLICT (user_id, as_of_date) DO UPDATE
SET installed_at               = EXCLUDED.installed_at,
    kyc_submitted_at           = EXCLUDED.kyc_submitted_at,
    kyc_reviewed_at            = EXCLUDED.kyc_reviewed_at,
    first_deposit_at           = EXCLUDED.first_deposit_at,
    first_trade_at             = EXCLUDED.first_trade_at,
    hrs_install_to_kyc_submit  = EXCLUDED.hrs_install_to_kyc_submit,
    hrs_kyc_submit_to_review   = EXCLUDED.hrs_kyc_submit_to_review,
    hrs_review_to_deposit      = EXCLUDED.hrs_review_to_deposit,
    hrs_deposit_to_trade       = EXCLUDED.hrs_deposit_to_trade,
    deposited                  = EXCLUDED.deposited,
    traded                     = EXCLUDED.traded,
    updated_at                 = now();

-- ========== 3) ENGAGEMENT 30d ==========
WITH params AS (
  SELECT CURRENT_DATE::date AS as_of_date,
         (now() - interval '30 days')::timestamptz AS since
),
sessions AS (
  SELECT s.user_id,
         COUNT(*) AS sessions_30d,
         COUNT(DISTINCT date_trunc('day', s.started_at)) AS active_days_30d
  FROM app_sessions s, params p
  WHERE s.started_at >= p.since
  GROUP BY s.user_id
),
events AS (
  SELECT e.user_id, COUNT(*) AS events_30d
  FROM app_events e, params p
  WHERE e.event_ts >= p.since
  GROUP BY e.user_id
),
pushes AS (
  SELECT n.user_id,
         COUNT(*) FILTER (WHERE n.channel='push') AS pushes_sent_30d,
         COUNT(*) FILTER (WHERE n.channel='push' AND n.opened_at IS NOT NULL) AS pushes_opened_30d
  FROM notifications n, params p
  WHERE n.created_at >= p.since
  GROUP BY n.user_id
)
INSERT INTO feat.user_features_engagement_30d
(user_id, as_of_date, sessions_30d, active_days_30d, events_30d, pushes_sent_30d, pushes_opened_30d, push_open_rate_30d, created_at, updated_at)
SELECT u.id,
       p.as_of_date,
       COALESCE(s.sessions_30d,0),
       COALESCE(s.active_days_30d,0),
       COALESCE(e.events_30d,0),
       COALESCE(ps.pushes_sent_30d,0),
       COALESCE(ps.pushes_opened_30d,0),
       CASE WHEN COALESCE(ps.pushes_sent_30d,0)=0 THEN 0.0
            ELSE ps.pushes_opened_30d::numeric / ps.pushes_sent_30d::numeric
       END,
       now(), now()
FROM users u
CROSS JOIN params p
LEFT JOIN sessions s ON s.user_id = u.id
LEFT JOIN events   e ON e.user_id = u.id
LEFT JOIN pushes  ps ON ps.user_id = u.id
ON CONFLICT (user_id, as_of_date) DO UPDATE
SET sessions_30d       = EXCLUDED.sessions_30d,
    active_days_30d    = EXCLUDED.active_days_30d,
    events_30d         = EXCLUDED.events_30d,
    pushes_sent_30d    = EXCLUDED.pushes_sent_30d,
    pushes_opened_30d  = EXCLUDED.pushes_opened_30d,
    push_open_rate_30d = EXCLUDED.push_open_rate_30d,
    updated_at         = now();

-- ========== 4) TRADING 90d ==========
WITH params AS (
  SELECT CURRENT_DATE::date AS as_of_date,
         (now() - interval '90 days')::timestamptz AS since
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
  SELECT o.account_id, a.user_id, o.side, f.quantity, f.price, i.quote_currency, f.fill_ts, i.id AS instrument_id
  FROM orders o
  JOIN order_fills f ON f.order_id = o.id
  JOIN accounts a ON a.id = o.account_id
  JOIN instruments i ON i.id = o.instrument_id, params p
  WHERE f.fill_ts >= p.since
),
per_user AS (
  SELECT f.user_id,
         COUNT(*) AS trade_count_90d,
         COUNT(*) FILTER (
           WHERE (CASE WHEN f.side='sell' THEN  f.quantity*f.price
                       ELSE -f.quantity*f.price END) > 0
         ) AS winning_trades_90d,
         AVG(ABS(f.quantity*f.price)*COALESCE(fx.to_usd,1.0)) AS avg_trade_notional_usd_90d,
         COUNT(DISTINCT f.quote_currency) AS currencies_traded_90d
  FROM fills f
  LEFT JOIN latest_fx fx ON fx.currency = f.quote_currency
  GROUP BY f.user_id
),
realized AS (
  SELECT f.user_id,
         SUM( (CASE WHEN f.side='sell' THEN  f.quantity*f.price
                    ELSE -f.quantity*f.price END) * COALESCE(fx.to_usd,1.0) ) AS realized_pnl_usd_90d,
         COUNT(DISTINCT f.instrument_id) AS instruments_traded_90d
  FROM fills f
  LEFT JOIN latest_fx fx ON fx.currency = f.quote_currency
  GROUP BY f.user_id
)
INSERT INTO feat.user_features_trading_90d
(user_id, as_of_date, trade_count_90d, win_rate_90d, avg_trade_notional_usd_90d, realized_pnl_usd_90d, instruments_traded_90d, currencies_traded_90d, created_at, updated_at)
SELECT u.id,
       p.as_of_date,
       COALESCE(pu.trade_count_90d,0),
       CASE WHEN COALESCE(pu.trade_count_90d,0)=0 THEN 0.0
            ELSE pu.winning_trades_90d::numeric / pu.trade_count_90d::numeric
       END AS win_rate_90d,
       COALESCE(pu.avg_trade_notional_usd_90d,0),
       COALESCE(r.realized_pnl_usd_90d,0),
       COALESCE(r.instruments_traded_90d,0),
       COALESCE(pu.currencies_traded_90d,0),
       now(), now()
FROM users u
CROSS JOIN params p
LEFT JOIN per_user pu ON pu.user_id = u.id
LEFT JOIN realized  r  ON r.user_id  = u.id
ON CONFLICT (user_id, as_of_date) DO UPDATE
SET trade_count_90d            = EXCLUDED.trade_count_90d,
    win_rate_90d               = EXCLUDED.win_rate_90d,
    avg_trade_notional_usd_90d = EXCLUDED.avg_trade_notional_usd_90d,
    realized_pnl_usd_90d       = EXCLUDED.realized_pnl_usd_90d,
    instruments_traded_90d     = EXCLUDED.instruments_traded_90d,
    currencies_traded_90d      = EXCLUDED.currencies_traded_90d,
    updated_at                 = now();

-- ========== 5) CONCENTRATION on open positions ==========
WITH params AS (
  SELECT CURRENT_DATE::date AS as_of_date
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
latest_price AS (
  SELECT DISTINCT ON (ip.instrument_id) ip.instrument_id, ip.price
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
  SELECT user_id, instrument_id, position_value_usd,
         position_value_usd / NULLIF(SUM(position_value_usd) OVER (PARTITION BY user_id),0) AS w
  FROM open_value
),
conc AS (
  SELECT u.id AS user_id,
         COALESCE(SUM(w.w*w.w) FILTER (WHERE w.user_id=u.id), 0) AS hhi_open_positions,
         COUNT(DISTINCT w.instrument_id) FILTER (WHERE w.user_id=u.id) AS distinct_instruments_open,
         EXISTS (SELECT 1 FROM accounts a WHERE a.user_id=u.id AND a.is_margin_enabled) AS margin_enabled
  FROM users u
  LEFT JOIN weights w ON w.user_id = u.id
  GROUP BY u.id
)
INSERT INTO feat.user_features_concentration_open
(user_id, as_of_date, hhi_open_positions, distinct_instruments_open, margin_enabled, created_at, updated_at)
SELECT c.user_id, p.as_of_date, c.hhi_open_positions, c.distinct_instruments_open, c.margin_enabled, now(), now()
FROM conc c
CROSS JOIN params p
ON CONFLICT (user_id, as_of_date) DO UPDATE
SET hhi_open_positions        = EXCLUDED.hhi_open_positions,
    distinct_instruments_open = EXCLUDED.distinct_instruments_open,
    margin_enabled            = EXCLUDED.margin_enabled,
    updated_at                = now();

-- ========== 6) SOCIAL / influence ==========
WITH params AS (
  SELECT CURRENT_DATE::date AS as_of_date
),
social AS (
  SELECT u.id AS user_id,
         COUNT(sp.id) AS posts_total,
         COUNT(sc.id) AS comments_total,
         COUNT(sl.id) AS likes_given_total
  FROM users u
  LEFT JOIN social_posts sp    ON sp.user_id = u.id
  LEFT JOIN social_comments sc ON sc.user_id = u.id
  LEFT JOIN social_likes sl    ON sl.user_id = u.id
  GROUP BY u.id
),
engagement_received AS (
  SELECT sp.user_id,
         COUNT(sl.id) AS likes_received_total,
         COUNT(sc.id) AS comments_received_total
  FROM social_posts sp
  LEFT JOIN social_likes sl    ON sl.post_id = sp.id
  LEFT JOIN social_comments sc ON sc.post_id = sp.id
  GROUP BY sp.user_id
),
followers AS (
  SELECT f.followed_user_id AS user_id, COUNT(*) AS followers_count
  FROM follows f GROUP BY f.followed_user_id
),
copiers AS (
  SELECT ctl.leader_user_id AS user_id, COUNT(*) AS copiers_count
  FROM copy_trading_links ctl
  WHERE ctl.stopped_at IS NULL
  GROUP BY ctl.leader_user_id
)
INSERT INTO feat.user_features_social
(user_id, as_of_date, posts_total, comments_total, likes_given_total, likes_received_total, comments_received_total, followers_count, copiers_count, created_at, updated_at)
SELECT u.id,
       p.as_of_date,
       COALESCE(s.posts_total,0),
       COALESCE(s.comments_total,0),
       COALESCE(s.likes_given_total,0),
       COALESCE(er.likes_received_total,0),
       COALESCE(er.comments_received_total,0),
       COALESCE(f.followers_count,0),
       COALESCE(c.copiers_count,0),
       now(), now()
FROM users u
CROSS JOIN params p
LEFT JOIN social s  ON s.user_id = u.id
LEFT JOIN engagement_received er ON er.user_id = u.id
LEFT JOIN followers f ON f.user_id = u.id
LEFT JOIN copiers   c ON c.user_id = u.id
ON CONFLICT (user_id, as_of_date) DO UPDATE
SET posts_total             = EXCLUDED.posts_total,
    comments_total          = EXCLUDED.comments_total,
    likes_given_total       = EXCLUDED.likes_given_total,
    likes_received_total    = EXCLUDED.likes_received_total,
    comments_received_total = EXCLUDED.comments_received_total,
    followers_count         = EXCLUDED.followers_count,
    copiers_count           = EXCLUDED.copiers_count,
    updated_at              = now();

COMMIT;

