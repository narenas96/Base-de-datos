-- 01_schema_postgres.sql
-- PostgreSQL 13+ recomendado

-- Utilidades para UUID y aleatoriedad
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================
-- ENUMS
-- =========================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'device_platform') THEN
    CREATE TYPE device_platform AS ENUM ('ios','android');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_side') THEN
    CREATE TYPE order_side AS ENUM ('buy','sell');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_type') THEN
    CREATE TYPE order_type AS ENUM ('market','limit','stop','stop_limit');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'time_in_force') THEN
    CREATE TYPE time_in_force AS ENUM ('day','gtc','ioc','fok');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_status') THEN
    CREATE TYPE order_status AS ENUM ('pending','placed','partial_filled','filled','canceled','rejected');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'position_status') THEN
    CREATE TYPE position_status AS ENUM ('open','closed');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'kyc_status') THEN
    CREATE TYPE kyc_status AS ENUM ('pending','approved','rejected','resubmission_required');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'risk_level') THEN
    CREATE TYPE risk_level AS ENUM ('low','medium','high','very_high');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_method') THEN
    CREATE TYPE payment_method AS ENUM ('card','bank_transfer','ewallet','crypto');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN
    CREATE TYPE payment_status AS ENUM ('initiated','settled','failed','reversed');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_channel') THEN
    CREATE TYPE notification_channel AS ENUM ('in_app','push');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'event_source') THEN
    CREATE TYPE event_source AS ENUM ('app_ui','background','push_open','deep_link','sdk');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'instrument_type') THEN
    CREATE TYPE instrument_type AS ENUM ('equity','etf','crypto','forex','commodity','index');
  END IF;
END$$;

-- =========================
-- TABLAS
-- =========================

CREATE TABLE IF NOT EXISTS users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email          varchar NOT NULL UNIQUE,
  phone          varchar,
  display_name   varchar,
  country_code   varchar(2),
  created_at     timestamptz NOT NULL DEFAULT now(),
  status         varchar(20)  -- active, suspended, closed
);

CREATE TABLE IF NOT EXISTS user_auth (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider       varchar(50),           -- password, apple, google, etc.
  provider_uid   varchar(200),
  last_login_at  timestamptz,
  mfa_enabled    boolean
);

CREATE TABLE IF NOT EXISTS kyc_profiles (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status           kyc_status NOT NULL DEFAULT 'pending',
  document_type    varchar(30),         -- id_card, passport, driver_license
  document_country varchar(2),
  submitted_at     timestamptz,
  reviewed_at      timestamptz
);

CREATE TABLE IF NOT EXISTS risk_assessments (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  level                  risk_level NOT NULL,
  questionnaire_version  varchar(20),
  score                  int,
  assessed_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS regulatory_consents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  consent_code  varchar(50),            -- tos, privacy, marketing, pds, etc.
  accepted      boolean NOT NULL DEFAULT true,
  accepted_at   timestamptz NOT NULL DEFAULT now(),
  locale        varchar(10)
);

CREATE TABLE IF NOT EXISTS currencies (
  code   varchar(3) PRIMARY KEY,        -- ISO
  name   varchar(30),
  symbol varchar(5)
);

CREATE TABLE IF NOT EXISTS exchange_rates (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  base_currency  varchar(3) NOT NULL REFERENCES currencies(code),
  quote_currency varchar(3) NOT NULL REFERENCES currencies(code),
  rate           numeric(18,8) NOT NULL,
  as_of          timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS accounts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  base_currency    varchar(3) NOT NULL REFERENCES currencies(code),
  opened_at        timestamptz NOT NULL DEFAULT now(),
  is_margin_enabled boolean DEFAULT false,
  status           varchar(20)         -- active, restricted, closed
);

CREATE TABLE IF NOT EXISTS account_balances (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  currency      varchar(3) NOT NULL REFERENCES currencies(code),
  cash_available numeric(20,2) NOT NULL DEFAULT 0,
  cash_locked    numeric(20,2) NOT NULL DEFAULT 0,
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger_entries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  currency      varchar(3) NOT NULL REFERENCES currencies(code),
  amount        numeric(20,2) NOT NULL,  -- +credit, -debit
  type          varchar(40),             -- trade_fill, deposit, withdrawal, fee, fx_conversion, interest
  reference_id  uuid,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  method        payment_method NOT NULL,
  status        payment_status NOT NULL,
  currency      varchar(3) NOT NULL REFERENCES currencies(code),
  amount        numeric(20,2) NOT NULL,
  provider      varchar(40),
  created_at    timestamptz NOT NULL DEFAULT now(),
  settled_at    timestamptz,
  failure_reason varchar(200)
);

CREATE TABLE IF NOT EXISTS deposits (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  payment_id    uuid NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
  amount        numeric(20,2) NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS withdrawals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  payment_id    uuid NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
  amount        numeric(20,2) NOT NULL,
  fee           numeric(20,2) DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS instruments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol         varchar(30) NOT NULL,       -- e.g., AAPL, BTC
  name           varchar(120),
  type           instrument_type NOT NULL,
  quote_currency varchar(3) REFERENCES currencies(code), -- e.g., USD
  is_tradable    boolean DEFAULT true
);

CREATE TABLE IF NOT EXISTS instrument_prices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
  price         numeric(20,8) NOT NULL,
  as_of         timestamptz NOT NULL,
  source        varchar(40)
);

CREATE TABLE IF NOT EXISTS orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  instrument_id uuid NOT NULL REFERENCES instruments(id),
  side          order_side NOT NULL,
  type          order_type NOT NULL,
  tif           time_in_force NOT NULL DEFAULT 'gtc',
  quantity      numeric(28,10) NOT NULL,
  limit_price   numeric(20,8),
  stop_price    numeric(20,8),
  status        order_status NOT NULL DEFAULT 'pending',
  placed_at     timestamptz NOT NULL DEFAULT now(),
  placed_via    varchar(20)                 -- mobile, web, api
);

CREATE TABLE IF NOT EXISTS order_fills (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id   uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  fill_ts    timestamptz NOT NULL DEFAULT now(),
  quantity   numeric(28,10) NOT NULL,
  price      numeric(20,8) NOT NULL,
  fee        numeric(20,8) DEFAULT 0
);

CREATE TABLE IF NOT EXISTS positions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  instrument_id uuid NOT NULL REFERENCES instruments(id),
  status        position_status NOT NULL DEFAULT 'open',
  quantity      numeric(28,10) NOT NULL,
  avg_price     numeric(20,8) NOT NULL,
  opened_at     timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz
);

CREATE TABLE IF NOT EXISTS portfolios (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        varchar(80),
  created_at  timestamptz NOT NULL DEFAULT now(),
  type        varchar(20)                 -- user, smart
);

CREATE TABLE IF NOT EXISTS portfolio_positions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  portfolio_id  uuid NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
  position_id   uuid NOT NULL REFERENCES positions(id) ON DELETE CASCADE,
  weight        numeric(9,6)
);

CREATE TABLE IF NOT EXISTS smart_portfolios (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           varchar(120) NOT NULL,
  description    text,
  base_currency  varchar(3) NOT NULL REFERENCES currencies(code),
  rebal_freq     varchar(20),            -- monthly, quarterly
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS smart_portfolio_allocations (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  smart_portfolio_id  uuid NOT NULL REFERENCES smart_portfolios(id) ON DELETE CASCADE,
  instrument_id       uuid NOT NULL REFERENCES instruments(id),
  target_weight       numeric(9,6) NOT NULL
);

CREATE TABLE IF NOT EXISTS copy_trading_links (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  leader_user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id        uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  allocation_pct    numeric(6,3) NOT NULL,       -- % del capital
  started_at        timestamptz NOT NULL DEFAULT now(),
  stopped_at        timestamptz
);

CREATE TABLE IF NOT EXISTS watchlists (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        varchar(60),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS watchlist_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  watchlist_id  uuid NOT NULL REFERENCES watchlists(id) ON DELETE CASCADE,
  instrument_id uuid NOT NULL REFERENCES instruments(id),
  added_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS social_posts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT now(),
  content       text,
  instrument_id uuid REFERENCES instruments(id)
);

CREATE TABLE IF NOT EXISTS social_comments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id     uuid NOT NULL REFERENCES social_posts(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  content     text
);

CREATE TABLE IF NOT EXISTS social_likes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id     uuid NOT NULL REFERENCES social_posts(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS follows (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  followed_user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform      device_platform NOT NULL,
  os_version    varchar(40),
  app_version   varchar(20),
  device_model  varchar(80),
  installed_at  timestamptz,
  last_seen_at  timestamptz
);

CREATE TABLE IF NOT EXISTS push_tokens (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id      uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  token          varchar(300) NOT NULL,
  provider       varchar(20),   -- apns, fcm
  valid          boolean DEFAULT true,
  created_at     timestamptz,
  invalidated_at timestamptz
);

CREATE TABLE IF NOT EXISTS app_sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id     uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  started_at    timestamptz NOT NULL DEFAULT now(),
  ended_at      timestamptz,
  city          varchar(100),
  ip            inet,
  is_foreground boolean
);

CREATE TABLE IF NOT EXISTS app_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  uuid NOT NULL REFERENCES app_sessions(id) ON DELETE CASCADE,
  user_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  device_id   uuid REFERENCES devices(id) ON DELETE SET NULL,
  event_name  varchar(100) NOT NULL,
  event_source event_source NOT NULL DEFAULT 'app_ui',
  event_ts    timestamptz NOT NULL DEFAULT now(),
  screen      varchar(100),
  metadata    jsonb
);

CREATE TABLE IF NOT EXISTS notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel     notification_channel NOT NULL,
  title       varchar(140),
  body        text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  opened_at    timestamptz,
  deeplink     varchar(300)
);

CREATE TABLE IF NOT EXISTS attribution_installs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  network     varchar(60),        -- p.ej. Facebook Ads, Google Ads
  campaign    varchar(120),
  adgroup     varchar(120),
  click_ts    timestamptz,
  install_ts  timestamptz
);

-- Índices útiles (muestra)
CREATE INDEX IF NOT EXISTS idx_orders_account ON orders(account_id);
CREATE INDEX IF NOT EXISTS idx_orders_instrument ON orders(instrument_id);
CREATE INDEX IF NOT EXISTS idx_fills_order ON order_fills(order_id);
CREATE INDEX IF NOT EXISTS idx_positions_account ON positions(account_id);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON app_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_events_session ON app_events(session_id);
