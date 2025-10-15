-- Schema (optional)
CREATE SCHEMA IF NOT EXISTS feat;

-- 1) Core financial features (equity, net deposits, money won, label)
CREATE TABLE IF NOT EXISTS feat.user_features_core (
  user_id       uuid        NOT NULL,
  as_of_date    date        NOT NULL,
  equity_usd    numeric,
  net_dep_usd   numeric,
  money_won_usd numeric,
  status_label  text,                 -- 'winning' | 'losing' | 'even'
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, as_of_date)
);

-- 2) Onboarding funnel & speed
CREATE TABLE IF NOT EXISTS feat.user_features_onboarding (
  user_id                     uuid NOT NULL,
  as_of_date                  date NOT NULL,
  installed_at                timestamptz,
  kyc_submitted_at            timestamptz,
  kyc_reviewed_at             timestamptz,
  first_deposit_at            timestamptz,
  first_trade_at              timestamptz,
  hrs_install_to_kyc_submit   numeric,
  hrs_kyc_submit_to_review    numeric,
  hrs_review_to_deposit       numeric,
  hrs_deposit_to_trade        numeric,
  deposited                   boolean,
  traded                      boolean,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, as_of_date)
);

-- 3) 30-day engagement
CREATE TABLE IF NOT EXISTS feat.user_features_engagement_30d (
  user_id             uuid NOT NULL,
  as_of_date          date NOT NULL,
  sessions_30d        integer,
  active_days_30d     integer,
  events_30d          integer,
  pushes_sent_30d     integer,
  pushes_opened_30d   integer,
  push_open_rate_30d  numeric,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, as_of_date)
);

-- 4) 90-day trading behavior & performance
CREATE TABLE IF NOT EXISTS feat.user_features_trading_90d (
  user_id                     uuid NOT NULL,
  as_of_date                  date NOT NULL,
  trade_count_90d             integer,
  win_rate_90d                numeric,
  avg_trade_notional_usd_90d  numeric,
  realized_pnl_usd_90d        numeric,
  instruments_traded_90d      integer,
  currencies_traded_90d       integer,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, as_of_date)
);

-- 5) Concentration risk on open positions
CREATE TABLE IF NOT EXISTS feat.user_features_concentration_open (
  user_id                      uuid NOT NULL,
  as_of_date                   date NOT NULL,
  hhi_open_positions           numeric, -- sum(w^2) of open exposure weights
  distinct_instruments_open    integer,
  margin_enabled               boolean,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, as_of_date)
);

-- 6) Social & copy-trading influence
CREATE TABLE IF NOT EXISTS feat.user_features_social (
  user_id                  uuid NOT NULL,
  as_of_date               date NOT NULL,
  posts_total              integer,
  comments_total           integer,
  likes_given_total        integer,
  likes_received_total     integer,
  comments_received_total  integer,
  followers_count          integer,
  copiers_count            integer,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, as_of_date)
);
