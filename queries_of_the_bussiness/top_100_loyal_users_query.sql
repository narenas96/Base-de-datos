-- ESTA ES LA VERSIÓN QUE SÍ RESPETA TU ARQUITECTURA
WITH user_metrics AS (
  -- Paso 1: Leer las features ya calculadas de la tabla de engagement
  SELECT
    user_id,
    sessions_30d,
    active_days_30d,
    push_open_rate_30d,
    -- La nueva métrica se puede derivar fácilmente de las existentes
    sessions_30d::numeric / NULLIF(active_days_30d, 0) AS avg_sessions_per_active_day
  FROM feat.user_features_engagement_30d
  -- Asumimos que queremos el snapshot más reciente
  WHERE as_of_date = (SELECT MAX(as_of_date) FROM feat.user_features_engagement_30d)
),
retention_90d AS (
  -- La retención aún necesita una pequeña verificación, aunque podría ser otra feature
  SELECT DISTINCT user_id, 1 AS is_retained_90d
  FROM app_sessions
  WHERE started_at >= now() - interval '90 days'
),
zscore_stats AS (
  -- El cálculo de estadísticas se hace sobre la tabla de features, mucho más rápido
  SELECT
    AVG(sessions_30d) AS avg_sessions, STDDEV_SAMP(sessions_30d) AS stddev_sessions,
    AVG(active_days_30d) AS avg_active_days, STDDEV_SAMP(active_days_30d) AS stddev_active_days,
    AVG(push_open_rate_30d) AS avg_push_rate, STDDEV_SAMP(push_open_rate_30d) AS stddev_push_rate,
    AVG(avg_sessions_per_active_day) AS avg_avg_sessions, STDDEV_SAMP(avg_sessions_per_active_day) AS stddev_avg_sessions
  FROM user_metrics
),
final_score AS (
  -- El cálculo del score es idéntico, pero parte de datos pre-calculados
  SELECT
    m.user_id,
    m.sessions_30d,
    m.active_days_30d,
    m.push_open_rate_30d,
    COALESCE(m.avg_sessions_per_active_day, 0) as avg_sessions_per_active_day,
    COALESCE(r.is_retained_90d, 0) AS is_retained_90d,
    (
      (CASE WHEN COALESCE(s.stddev_sessions, 0) = 0 THEN 0.0 ELSE (m.sessions_30d - s.avg_sessions) / s.stddev_sessions END * 0.4) +
      (CASE WHEN COALESCE(s.stddev_active_days, 0) = 0 THEN 0.0 ELSE (m.active_days_30d - s.avg_active_days) / s.stddev_active_days END * 0.3) +
      (CASE WHEN COALESCE(s.stddev_push_rate, 0) = 0 THEN 0.0 ELSE (m.push_open_rate_30d - s.avg_push_rate) / s.stddev_push_rate END * 0.2) +
      (CASE WHEN COALESCE(s.stddev_avg_sessions, 0) = 0 THEN 0.0 ELSE (COALESCE(m.avg_sessions_per_active_day,0) - s.avg_avg_sessions) / s.stddev_avg_sessions END * 0.1)
    ) * (1 + 0.5 * COALESCE(r.is_retained_90d, 0)) AS engagement_retention_score
  FROM user_metrics m
  LEFT JOIN retention_90d r ON m.user_id = r.user_id
  CROSS JOIN zscore_stats s
)
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
