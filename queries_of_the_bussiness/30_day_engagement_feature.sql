-- (Q2) 30-day engagement features (sessions, events, days active, push open rate)
-- Goal: Build behavioral signals for churn/retention models.
-- sessions_30d, active_days_30d, events_30d, push_open_rate_30d → strong churn predictors.
-- Use as continuous features; optionally bucketize (low/med/high engagement).

WITH time_window AS ( -- Renamed from 'window' to avoid the reserved keyword error
  SELECT now()::timestamptz AS as_of, (now() - interval '30 days')::timestamptz AS since
),
sessions AS (
  SELECT s.user_id,
           COUNT(*) AS sessions_30d,
           COUNT(DISTINCT date_trunc('day', s.started_at)) AS active_days_30d
  FROM app_sessions s, time_window w -- Reference updated
  WHERE s.started_at >= w.since
  GROUP BY s.user_id
),
events AS (
  SELECT e.user_id,
           COUNT(*) AS events_30d
  FROM app_events e, time_window w -- Reference updated
  WHERE e.event_ts >= w.since
  GROUP BY e.user_id
),
pushes AS (
  SELECT n.user_id,
           COUNT(*) FILTER (WHERE n.channel = 'push') AS pushes_sent_30d,
           COUNT(*) FILTER (WHERE n.channel = 'push' AND n.opened_at IS NOT NULL) AS pushes_opened_30d
  FROM notifications n, time_window w -- Reference updated
  WHERE n.created_at >= w.since
  GROUP BY n.user_id
)
SELECT u.id AS user_id,
        COALESCE(s.sessions_30d,0) AS sessions_30d,
        COALESCE(s.active_days_30d,0) AS active_days_30d,
        COALESCE(e.events_30d,0) AS events_30d,
        COALESCE(p.pushes_sent_30d,0) AS pushes_sent_30d,
        COALESCE(p.pushes_opened_30d,0) AS pushes_opened_30d,
        CASE WHEN COALESCE(p.pushes_sent_30d,0) = 0 THEN 0.0
             ELSE p.pushes_opened_30d::numeric / p.pushes_sent_30d::numeric
        END AS push_open_rate_30d
FROM users u
LEFT JOIN sessions s ON s.user_id = u.id
LEFT JOIN events e   ON e.user_id = u.id
LEFT JOIN pushes p   ON p.user_id = u.id;