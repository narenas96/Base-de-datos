WITH engagement_30d AS (
  -- Calcula las métricas de engagement de los últimos 30 días
  SELECT
    u.id AS user_id,
    COALESCE(s.sessions_30d, 0) AS sessions_30d,
    COALESCE(s.active_days_30d, 0) AS active_days_30d,
    -- Calcula el ratio de apertura de pushes, manejando el caso de cero envíos
    CASE
      WHEN COALESCE(p.pushes_sent_30d, 0) = 0 THEN 0.0
      ELSE COALESCE(p.pushes_opened_30d, 0)::numeric / p.pushes_sent_30d::numeric
    END AS push_open_rate_30d
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
  -- Identifica usuarios retenidos en los últimos 90 días
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
    COALESCE(r.is_retained_90d, 0) AS is_retained_90d
  FROM engagement_30d e
  LEFT JOIN retention_90d r ON e.user_id = r.user_id
),
normalization_stats AS (
  -- Calcula los valores mínimos y máximos para la normalización
  SELECT
    MIN(sessions_30d) AS min_sessions,
    MAX(sessions_30d) AS max_sessions,
    MIN(active_days_30d) AS min_active_days,
    MAX(active_days_30d) AS max_active_days,
    MIN(push_open_rate_30d) AS min_push_rate,
    MAX(push_open_rate_30d) AS max_push_rate
  FROM user_metrics
),
scored_users AS (
  -- Calcula el score final normalizado y ponderado
  SELECT
    m.user_id,
    m.sessions_30d,
    m.active_days_30d,
    m.push_open_rate_30d,
    m.is_retained_90d,
    -- Aplica el bonus de retención al score compuesto
    (
      -- Normaliza sessions_30d (0 a 1)
      (CASE WHEN (s.max_sessions - s.min_sessions) = 0 THEN 0.0
            ELSE (m.sessions_30d::numeric - s.min_sessions) / (s.max_sessions - s.min_sessions)
       END * 0.4) +
      -- Normaliza active_days_30d (0 a 1)
      (CASE WHEN (s.max_active_days - s.min_active_days) = 0 THEN 0.0
            ELSE (m.active_days_30d::numeric - s.min_active_days) / (s.max_active_days - s.min_active_days)
       END * 0.4) +
      -- Normaliza push_open_rate_30d (0 a 1)
      (CASE WHEN (s.max_push_rate - s.min_push_rate) = 0 THEN 0.0
            ELSE (m.push_open_rate_30d - s.min_push_rate) / (s.max_push_rate - s.min_push_rate)
       END * 0.2)
    ) * (1 + 0.5 * m.is_retained_90d) AS engagement_retention_score
  FROM user_metrics m
  CROSS JOIN normalization_stats s -- Unimos con las estadísticas para tenerlas disponibles en cada fila
)
-- Selección final: Top 100 usuarios con su score y datos de perfil
SELECT
  su.user_id,
  u.display_name,
  u.country_code,
  u.created_at,
  su.engagement_retention_score,
  su.sessions_30d,
  su.active_days_30d,
  su.push_open_rate_30d,
  su.is_retained_90d
FROM scored_users su
JOIN users u ON su.user_id = u.id
ORDER BY engagement_retention_score DESC
LIMIT 100;
