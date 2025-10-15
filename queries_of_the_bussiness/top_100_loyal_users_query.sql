WITH engagement_30d AS (
  -- Calcula las métricas de engagement de los últimos 30 días, incluyendo la nueva métrica
  SELECT
    u.id AS user_id,
    COALESCE(s.sessions_30d, 0) AS sessions_30d,
    COALESCE(s.active_days_30d, 0) AS active_days_30d,
    -- Calcula el ratio de apertura de pushes, manejando el caso de cero envíos
    CASE
      WHEN COALESCE(p.pushes_sent_30d, 0) = 0 THEN 0.0
      ELSE COALESCE(p.pushes_opened_30d, 0)::numeric / p.pushes_sent_30d::numeric
    END AS push_open_rate_30d,
    -- NUEVA MÉTRICA: Promedio de sesiones por día activo
    COALESCE(s.sessions_30d, 0)::numeric / NULLIF(COALESCE(s.active_days_30d, 0), 0) AS avg_sessions_per_active_day
  FROM users u
  LEFT JOIN (
    -- Subquery para sesiones y días activos
    SELECT
      user_id,
      COUNT(id) AS sessions_30d,
      COUNT(DISTINCT DATE_TRUNC('day', started_at)) AS active_days_30d
    FROM app_sessions
    WHERE started_at >= now() - interval '30 days'
    GROUP BY user_id
  ) s ON u.id = s.user_id
  LEFT JOIN (
    -- Subquery para notificaciones push
    SELECT
      user_id,
      COUNT(id) FILTER (WHERE channel = 'push') AS pushes_sent_30d,
      COUNT(id) FILTER (WHERE channel = 'push' AND opened_at IS NOT NULL) AS pushes_opened_30d
    FROM notifications
    WHERE created_at >= now() - interval '30 days'
    GROUP BY user_id
  ) p ON u.id = p.user_id
),
retention_90d AS (
  -- Identifica usuarios retenidos en los últimos 90 días (sin cambios)
  SELECT DISTINCT
    user_id,
    1 AS is_retained_90d
  FROM app_sessions
  WHERE started_at >= now() - interval '90 days'
),
user_metrics AS (
  -- Combina todas las métricas base por usuario
  SELECT
    e.user_id,
    e.sessions_30d,
    e.active_days_30d,
    e.push_open_rate_30d,
    COALESCE(e.avg_sessions_per_active_day, 0) AS avg_sessions_per_active_day,
    COALESCE(r.is_retained_90d, 0) AS is_retained_90d
  FROM engagement_30d e
  LEFT JOIN retention_90d r ON e.user_id = r.user_id
),
zscore_stats AS (
  -- Calcula promedio (avg) y desviación estándar (stddev) para la normalización Z-Score
  SELECT
    AVG(sessions_30d) AS avg_sessions,
    STDDEV_SAMP(sessions_30d) AS stddev_sessions,
    AVG(active_days_30d) AS avg_active_days,
    STDDEV_SAMP(active_days_30d) AS stddev_active_days,
    AVG(push_open_rate_30d) AS avg_push_rate,
    STDDEV_SAMP(push_open_rate_30d) AS stddev_push_rate,
    AVG(avg_sessions_per_active_day) AS avg_avg_sessions,
    STDDEV_SAMP(avg_sessions_per_active_day) AS stddev_avg_sessions
  FROM user_metrics
),
final_score AS (
  -- Calcula el score final usando Z-Scores y las nuevas ponderaciones
  SELECT
    m.user_id,
    m.sessions_30d,
    m.active_days_30d,
    m.push_open_rate_30d,
    m.avg_sessions_per_active_day,
    m.is_retained_90d,
    (
      -- Z-score de sessions_30d
      (CASE WHEN COALESCE(s.stddev_sessions, 0) = 0 THEN 0.0
            ELSE (m.sessions_30d - s.avg_sessions) / s.stddev_sessions
       END * 0.4) +
      -- Z-score de active_days_30d
      (CASE WHEN COALESCE(s.stddev_active_days, 0) = 0 THEN 0.0
            ELSE (m.active_days_30d - s.avg_active_days) / s.stddev_active_days
       END * 0.3) +
      -- Z-score de push_open_rate_30d
      (CASE WHEN COALESCE(s.stddev_push_rate, 0) = 0 THEN 0.0
            ELSE (m.push_open_rate_30d - s.avg_push_rate) / s.stddev_push_rate
       END * 0.2) +
      -- Z-score de avg_sessions_per_active_day
      (CASE WHEN COALESCE(s.stddev_avg_sessions, 0) = 0 THEN 0.0
            ELSE (m.avg_sessions_per_active_day - s.avg_avg_sessions) / s.stddev_avg_sessions
       END * 0.1)
    ) * (1 + 0.5 * m.is_retained_90d) AS engagement_retention_score
  FROM user_metrics m
  CROSS JOIN zscore_stats s
)
-- Selección final: Top 100 usuarios con su score y datos de perfil
SELECT
  fs.user_id,
  u.display_name,
  u.country_code,
  u.created_at,
  fs.engagement_retention_score,
  fs.sessions_30d,
  fs.active_days_30d,
  fs.push_open_rate_30d,
  fs.avg_sessions_per_active_day,
  fs.is_retained_90d
FROM final_score fs
JOIN users u ON fs.user_id = u.id
ORDER BY engagement_retention_score DESC
LIMIT 100;
