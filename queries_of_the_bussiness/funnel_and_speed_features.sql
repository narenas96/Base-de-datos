-- (Q1) Onboarding funnel & speed features
-- Goal: How fast do users move from install → KYC → first deposit → first trade?
-- Speeds (in hours) are strong predictors of activation and revenue.
-- Flags deposited, traded become labels/targets for propensity models.

WITH first_install AS (
  SELECT d.user_id, MIN(d.installed_at) AS installed_at
  FROM devices d
  GROUP BY d.user_id
),
first_kyc AS (
  SELECT k.user_id, MIN(k.submitted_at) AS kyc_submitted_at,
         MIN(NULLIF(k.reviewed_at, NULL)) AS kyc_reviewed_at
  FROM kyc_profiles k
  GROUP BY k.user_id
),
first_deposit AS (
  SELECT a.user_id, MIN(d.created_at) AS first_deposit_at
  FROM deposits d
  JOIN accounts a ON a.id = d.account_id
  GROUP BY a.user_id
),
first_trade AS (
  SELECT a.user_id, MIN(o.placed_at) AS first_trade_at
  FROM orders o
  JOIN accounts a ON a.id = o.account_id
  GROUP BY a.user_id
)
SELECT u.id AS user_id,
       fi.installed_at,
       fk.kyc_submitted_at,
       fk.kyc_reviewed_at,
       fd.first_deposit_at,
       ft.first_trade_at,
       -- durations in hours (use days if you prefer)
       EXTRACT(EPOCH FROM (fk.kyc_submitted_at - fi.installed_at))/3600 AS hrs_install_to_kyc_submit,
       EXTRACT(EPOCH FROM (fk.kyc_reviewed_at - fk.kyc_submitted_at))/3600 AS hrs_kyc_submit_to_review,
       EXTRACT(EPOCH FROM (fd.first_deposit_at - fk.kyc_reviewed_at))/3600 AS hrs_review_to_deposit,
       EXTRACT(EPOCH FROM (ft.first_trade_at - fd.first_deposit_at))/3600 AS hrs_deposit_to_trade,
       -- funnel flags
       (fd.first_deposit_at IS NOT NULL) AS deposited,
       (ft.first_trade_at IS NOT NULL) AS traded
FROM users u
LEFT JOIN first_install fi  ON fi.user_id = u.id
LEFT JOIN first_kyc fk      ON fk.user_id = u.id
LEFT JOIN first_deposit fd  ON fd.user_id = u.id
LEFT JOIN first_trade ft    ON ft.user_id = u.id;
