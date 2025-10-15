-- 02_seed_postgres.sql (corregido)
BEGIN;

-- =========================
-- PARÁMETROS
-- =========================
DO $$
DECLARE
  target_users int := 50;  -- <=== AJUSTA AQUÍ (50 recomendado)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'seed_params') THEN
    CREATE TEMP TABLE seed_params (target_users int);
  ELSE
    TRUNCATE seed_params;
  END IF;
  INSERT INTO seed_params(target_users) VALUES (target_users);
END$$;

-- =========================
-- CATÁLOGOS
-- =========================
INSERT INTO currencies(code,name,symbol) VALUES
  ('USD','US Dollar','$'),
  ('EUR','Euro','€'),
  ('GBP','Pound','£')
ON CONFLICT (code) DO NOTHING;

INSERT INTO exchange_rates(base_currency,quote_currency,rate,as_of)
SELECT * FROM (
  VALUES
    ('USD','EUR',0.92, now()),
    ('EUR','USD',1.09, now()),
    ('USD','GBP',0.78, now()),
    ('GBP','USD',1.28, now())
) AS v(base_currency,quote_currency,rate,as_of)
ON CONFLICT DO NOTHING;

INSERT INTO instruments(symbol,name,type,quote_currency,is_tradable) VALUES
  ('AAPL','Apple Inc.','equity','USD',true),
  ('SPY','SPDR S&P 500 ETF','etf','USD',true),
  ('BTC','Bitcoin','crypto','USD',true)
ON CONFLICT DO NOTHING;

INSERT INTO instrument_prices(instrument_id,price,as_of,source)
SELECT id,
       CASE symbol
         WHEN 'AAPL' THEN 195.10
         WHEN 'SPY'  THEN 560.25
         WHEN 'BTC'  THEN 65000.00
       END,
       now(),
       'seed'
FROM instruments
WHERE symbol IN ('AAPL','SPY','BTC')
ON CONFLICT DO NOTHING;

-- =========================
-- USUARIOS + PERFIL + CONSENT
-- =========================
WITH p AS (SELECT target_users FROM seed_params)
INSERT INTO users(email, phone, display_name, country_code, created_at, status)
SELECT
  ('user' || lpad(gs::text, 2, '0') || '@example.com')::varchar AS email,
  ('+1-202-555-' || lpad(gs::text, 4, '0'))::varchar          AS phone,
  ('User ' || lpad(gs::text, 2, '0'))::varchar                 AS display_name,
  (ARRAY['US','GB','DE','FR','ES','PE','BR','MX','AR','CL'])[1 + (random()*9)::int]::varchar(2) AS country_code,
  now() - ((random()*30)::int || ' days')::interval AS created_at,
  (ARRAY['active','active','active','suspended'])[1 + (random()*3)::int]::varchar(20) AS status
FROM generate_series(1,(SELECT target_users FROM p)) AS gs
ON CONFLICT (email) DO NOTHING;

INSERT INTO user_auth(user_id, provider, provider_uid, last_login_at, mfa_enabled)
SELECT u.id,
       (ARRAY['password','apple','google'])[1 + (random()*2)::int],
       encode(gen_random_bytes(8),'hex'),
       now() - ((random()*10)::int || ' days')::interval,
       (random() < 0.35)
FROM users u
LEFT JOIN user_auth ua ON ua.user_id = u.id
WHERE ua.user_id IS NULL;

INSERT INTO kyc_profiles(user_id, status, document_type, document_country, submitted_at, reviewed_at)
SELECT u.id,
       (ARRAY['approved','approved','pending','rejected','resubmission_required'])[1 + (random()*4)::int]::kyc_status,
       (ARRAY['id_card','passport','driver_license'])[1 + (random()*2)::int],
       COALESCE(u.country_code,'US'),
       u.created_at + ((random()*5)::int || ' days')::interval,
       CASE WHEN random() < 0.8 THEN now() - ((random()*5)::int || ' days')::interval END
FROM users u
LEFT JOIN kyc_profiles k ON k.user_id = u.id
WHERE k.user_id IS NULL;

INSERT INTO risk_assessments(user_id, level, questionnaire_version, score, assessed_at)
SELECT u.id,
       (ARRAY['low','medium','high','very_high'])[1 + (random()*3)::int]::risk_level,
       'v1',
       (50 + random()*50)::int,
       now() - ((random()*15)::int || ' days')::interval
FROM users u
LEFT JOIN risk_assessments r ON r.user_id = u.id
WHERE r.user_id IS NULL;

INSERT INTO regulatory_consents(user_id, consent_code, accepted, accepted_at, locale)
SELECT u.id,
       c.code,
       true,
       u.created_at,
       (CASE WHEN u.country_code IN ('ES','PE','MX','AR','CL','BR') THEN 'es-ES' ELSE 'en-US' END)
FROM users u
CROSS JOIN (VALUES ('tos'),('privacy'),('marketing')) AS c(code)
LEFT JOIN regulatory_consents rc ON rc.user_id = u.id AND rc.consent_code = c.code
WHERE rc.user_id IS NULL;

-- =========================
-- DISPOSITIVOS / TOKENS / SESIONES / EVENTOS
-- =========================
-- Helper para versiones como texto
WITH devs AS (
  SELECT u.id AS user_id,
         (ARRAY['ios','android'])[1 + (random()*1)::int]::device_platform AS platform,
         ((12 + floor(random()*4))::int)::text || '.' || ((10 + floor(random()*5))::int)::text AS os_version,
         ((2 + floor(random()*2))::int)::text  || '.' ||
         ((1 + floor(random()*9))::int)::text  || '.' ||
         ((1 + floor(random()*20))::int)::text AS app_version,
         (ARRAY['iPhone 14','iPhone 15','Pixel 7','Galaxy S23','Xiaomi 13'])[1 + (random()*4)::int] AS device_model,
         u.created_at + ((random()*2)::int || ' days')::interval AS installed_at,
         now() - ((random()*2)::int || ' days')::interval         AS last_seen_at
  FROM users u
)
INSERT INTO devices(user_id, platform, os_version, app_version, device_model, installed_at, last_seen_at)
SELECT * FROM devs
UNION ALL
SELECT u.id,
       (ARRAY['ios','android'])[1 + (random()*1)::int]::device_platform,
       ((12 + floor(random()*4))::int)::text || '.' || ((10 + floor(random()*5))::int)::text,
       ((2 + floor(random()*2))::int)::text  || '.' ||
       ((1 + floor(random()*9))::int)::text  || '.' ||
       ((1 + floor(random()*20))::int)::text,
       (ARRAY['iPhone 13','iPhone SE','Pixel 6','Galaxy S22','Moto G'])[1 + (random()*4)::int],
       u.created_at + ((random()*7)::int || ' days')::interval,
       now() - ((random()*6)::int || ' days')::interval
FROM users u
WHERE random() < 0.5;

INSERT INTO push_tokens(device_id, token, provider, valid, created_at)
SELECT d.id,
       encode(gen_random_bytes(24),'hex'),
       (CASE WHEN d.platform = 'ios' THEN 'apns' ELSE 'fcm' END),
       true,
       d.installed_at
FROM devices d
LEFT JOIN push_tokens pt ON pt.device_id = d.id
WHERE pt.device_id IS NULL;

-- Generar IP como texto y castear a inet
INSERT INTO app_sessions(user_id, device_id, started_at, ended_at, city, ip, is_foreground)
SELECT d.user_id, d.id,
       now() - ((1 + gs)::text || ' hours')::interval,
       now() - ((gs)::text || ' hours')::interval,
       (ARRAY['Lima','Madrid','London','Berlin','New York','São Paulo'])[1 + (random()*5)::int],
       (
         (
           '10.' ||
           (trunc(random()*256))::int || '.' ||
           (trunc(random()*256))::int || '.' ||
           (trunc(random()*256))::int
         )::inet
       ),
       true
FROM devices d
CROSS JOIN generate_series(1,3) gs
WHERE random() < 0.6;

INSERT INTO app_events(session_id, user_id, device_id, event_name, event_source, event_ts, screen, metadata)
SELECT s.id, s.user_id, s.device_id,
       e.event_name,
       e.event_source::event_source,
       s.started_at + (e.seq || ' minutes')::interval,
       e.screen,
       e.metadata::jsonb
FROM app_sessions s
JOIN LATERAL (
  SELECT 1 AS seq, 'AppOpen' AS event_name, 'app_ui' AS event_source, 'Home' AS screen, '{"from":"push"}' AS metadata
  UNION ALL
  SELECT 2, 'ViewInstrument','app_ui','Instrument','{"symbol":"AAPL"}'
  UNION ALL
  SELECT 3, 'PlaceOrder_Tap','app_ui','Order','{}'
  UNION ALL
  SELECT 4, 'Order_Submit','app_ui','Order','{}'
  UNION ALL
  SELECT 5, 'Feed_View','app_ui','Feed','{}'
) e ON true
WHERE random() < 0.8;

INSERT INTO notifications(user_id, channel, title, body, created_at, delivered_at, opened_at, deeplink)
SELECT DISTINCT s.user_id,
       (ARRAY['in_app','push'])[1 + (random()*1)::int]::notification_channel,
       'Alerta de precio',
       'BTC superó el umbral configurado',
       now() - interval '1 hour',
       now() - interval '55 minutes',
       CASE WHEN random() < 0.5 THEN now() - interval '50 minutes' END,
       'app://instrument/BTC'
FROM app_sessions s
WHERE random() < 0.2;

INSERT INTO attribution_installs(device_id, network, campaign, adgroup, click_ts, install_ts)
SELECT d.id,
       (ARRAY['Facebook Ads','Google Ads','Organic'])[1 + (random()*2)::int],
       'Acquisition Q4',
       'Generic',
       d.installed_at - interval '5 minutes',
       d.installed_at
FROM devices d
WHERE random() < 0.4;

-- =========================
-- CUENTAS / SALDOS / PAGOS / MOVIMIENTOS
-- =========================
INSERT INTO accounts(user_id, base_currency, opened_at, is_margin_enabled, status)
SELECT u.id,
       (ARRAY['USD','EUR','GBP'])[1 + (random()*2)::int],
       u.created_at,
       (random() < 0.2),
       (ARRAY['active','active','restricted'])[1 + (random()*2)::int]
FROM users u
LEFT JOIN accounts a ON a.user_id = u.id
WHERE a.user_id IS NULL;

INSERT INTO account_balances(account_id, currency, cash_available, cash_locked, updated_at)
SELECT a.id, a.base_currency,
       round((1000 + random()*9000)::numeric,2),
       0, now()
FROM accounts a
LEFT JOIN account_balances b ON b.account_id = a.id AND b.currency = a.base_currency
WHERE b.account_id IS NULL;

WITH uids AS (SELECT id AS user_id FROM users)
INSERT INTO payments(user_id, method, status, currency, amount, provider, created_at, settled_at)
SELECT u.user_id,
       (ARRAY['card','bank_transfer','ewallet'])[1 + (random()*2)::int]::payment_method,
       'settled'::payment_status,
       (ARRAY['USD','EUR','GBP'])[1 + (random()*2)::int],
       round((200 + random()*2000)::numeric,2),
       'seed_psp',
       now() - ((random()*15)::int || ' days')::interval,
       now() - ((random()*14)::int || ' days')::interval
FROM uids u
WHERE random() < 0.8;

INSERT INTO deposits(account_id, payment_id, amount, created_at)
SELECT a.id, p.id,
       p.amount,
       p.settled_at
FROM payments p
JOIN accounts a ON a.user_id = p.user_id
WHERE p.status = 'settled';

INSERT INTO ledger_entries(account_id, currency, amount, type, reference_id, created_at)
SELECT d.account_id, a.base_currency, d.amount, 'deposit', d.id, d.created_at
FROM deposits d
JOIN accounts a ON a.id = d.account_id;

INSERT INTO payments(user_id, method, status, currency, amount, provider, created_at, settled_at, failure_reason)
SELECT a.user_id,
       (ARRAY['bank_transfer','ewallet'])[1 + (random()*1)::int]::payment_method,
       (CASE WHEN random() < 0.9 THEN 'settled' ELSE 'failed' END)::payment_status,
       a.base_currency,
       round((50 + random()*500)::numeric,2),
       'seed_psp',
       now() - ((random()*7)::int || ' days')::interval,
       CASE WHEN random() < 0.9 THEN now() - ((random()*6)::int || ' days')::interval END,
       CASE WHEN random() >= 0.9 THEN 'insufficient_funds' END
FROM accounts a
WHERE random() < 0.3;

INSERT INTO withdrawals(account_id, payment_id, amount, fee, created_at)
SELECT a.id, p.id, p.amount, round((p.amount*0.005)::numeric,2), COALESCE(p.settled_at, p.created_at)
FROM payments p
JOIN accounts a ON a.user_id = p.user_id
WHERE p.status IN ('settled','reversed') AND p.created_at > now() - interval '8 days'
  AND NOT EXISTS (SELECT 1 FROM withdrawals w WHERE w.payment_id = p.id);

INSERT INTO ledger_entries(account_id, currency, amount, type, reference_id, created_at)
SELECT w.account_id, a.base_currency, -w.amount, 'withdrawal', w.id, w.created_at
FROM withdrawals w
JOIN accounts a ON a.id = w.account_id;

INSERT INTO ledger_entries(account_id, currency, amount, type, reference_id, created_at)
SELECT w.account_id, a.base_currency, -w.fee, 'fee', w.id, w.created_at
FROM withdrawals w
JOIN accounts a ON a.id = w.account_id
WHERE w.fee > 0;

-- =========================
-- ÓRDENES / FILLS / POSICIONES
-- =========================
INSERT INTO orders(account_id, instrument_id, side, type, tif, quantity, limit_price, stop_price, status, placed_at, placed_via)
SELECT a.id,
       (SELECT id FROM instruments ORDER BY random() LIMIT 1),
       (ARRAY['buy','sell'])[1 + (random()*1)::int]::order_side,
       (ARRAY['market','limit'])[1 + (random()*1)::int]::order_type,
       'gtc'::time_in_force,
       round((1 + random()*5)::numeric,4),
       CASE WHEN random() < 0.5 THEN round((10 + random()*100)::numeric,4) END,
       NULL,
       (ARRAY['placed','filled','filled','filled','partial_filled'])[1 + (random()*4)::int]::order_status,
       now() - ((random()*10)::int || ' days')::interval,
       'mobile'
FROM accounts a
CROSS JOIN LATERAL generate_series(1, (2 + (random()*3)::int)) g;

INSERT INTO order_fills(order_id, fill_ts, quantity, price, fee)
SELECT o.id,
       o.placed_at + interval '5 minutes',
       o.quantity,
       COALESCE(o.limit_price,
         CASE (SELECT symbol FROM instruments i WHERE i.id = o.instrument_id)
           WHEN 'AAPL' THEN 195.00 + (random()*3)
           WHEN 'SPY'  THEN 560.00 + (random()*2)
           WHEN 'BTC'  THEN 65000.00 + (random()*500)
           ELSE 100 + (random()*50)
         END
       ),
       round((o.quantity * 0.01)::numeric, 4)
FROM orders o
WHERE o.status IN ('filled','partial_filled')
  AND NOT EXISTS (SELECT 1 FROM order_fills f WHERE f.order_id = o.id);

WITH buy_qty AS (
  SELECT o.account_id, o.instrument_id,
         SUM(CASE WHEN o.side='buy' THEN o.quantity ELSE -o.quantity END) AS net_qty,
         AVG((SELECT price FROM order_fills f WHERE f.order_id = o.id LIMIT 1)) AS avg_px
  FROM orders o
  GROUP BY o.account_id, o.instrument_id
)
INSERT INTO positions(account_id, instrument_id, status, quantity, avg_price, opened_at)
SELECT b.account_id, b.instrument_id,
       CASE WHEN b.net_qty > 0 THEN 'open' ELSE 'closed' END::position_status,
       GREATEST(b.net_qty,0.0001),
       COALESCE(b.avg_px, 100),
       now() - interval '1 day'
FROM buy_qty b
WHERE b.net_qty <> 0
  AND NOT EXISTS (
    SELECT 1 FROM positions p
    WHERE p.account_id = b.account_id AND p.instrument_id = b.instrument_id
  );

INSERT INTO portfolios(user_id, name, type)
SELECT u.id, 'Main', 'user'
FROM users u
LEFT JOIN portfolios p ON p.user_id = u.id
WHERE p.user_id IS NULL;

INSERT INTO portfolio_positions(portfolio_id, position_id, weight)
SELECT p.id, pos.id, round((0.2 + random()*0.6)::numeric,4)
FROM portfolios p
JOIN positions pos ON pos.account_id IN (
  SELECT a.id FROM accounts a WHERE a.user_id = p.user_id
)
WHERE random() < 0.5;

INSERT INTO watchlists(user_id, name)
SELECT u.id, 'Default Watchlist'
FROM users u
WHERE random() < 0.8
  AND NOT EXISTS (SELECT 1 FROM watchlists w WHERE w.user_id = u.id);

INSERT INTO watchlist_items(watchlist_id, instrument_id)
SELECT w.id, i.id
FROM watchlists w
CROSS JOIN LATERAL (
  SELECT id FROM instruments ORDER BY random() LIMIT 2
) i;

INSERT INTO social_posts(user_id, content, instrument_id)
SELECT u.id,
       'Interesante movimiento hoy',
       (SELECT id FROM instruments ORDER BY random() LIMIT 1)
FROM users u
WHERE random() < 0.15;

INSERT INTO social_comments(post_id, user_id, content)
SELECT p.id, u.id, 'De acuerdo'
FROM social_posts p
JOIN LATERAL (SELECT id FROM users ORDER BY random() LIMIT 1) u ON true
WHERE random() < 0.5;

INSERT INTO social_likes(post_id, user_id)
SELECT p.id, u.id
FROM social_posts p
JOIN LATERAL (SELECT id FROM users ORDER BY random() LIMIT 1) u ON true
WHERE random() < 0.6;

INSERT INTO follows(follower_user_id, followed_user_id)
SELECT u1.id, u2.id
FROM (SELECT id FROM users ORDER BY random() LIMIT 30) u1,
     (SELECT id FROM users ORDER BY random() LIMIT 30) u2
WHERE u1.id <> u2.id
AND random() < 0.2;

COMMIT;
