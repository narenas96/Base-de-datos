-- (Q5) Social & copy-trading influence feature
-- Goal: Build signals for who to copy and who influences others.
-- followers_count, copiers_count → influence/performance social proof.
-- likes_received_total & comments_received_total → content quality/engagement.
-- Useful to rank leaders for CopyTrader recommendations.

WITH social AS (
  SELECT u.id AS user_id,
         COUNT(sp.id) AS posts_total,
         COUNT(sc.id) AS comments_total,
         COUNT(sl.id) AS likes_given_total
  FROM users u
  LEFT JOIN social_posts sp ON sp.user_id = u.id
  LEFT JOIN social_comments sc ON sc.user_id = u.id
  LEFT JOIN social_likes sl ON sl.user_id = u.id
  GROUP BY u.id
),
engagement_received AS (
  SELECT sp.user_id,
         COUNT(sl.id) AS likes_received_total,
         COUNT(sc.id) AS comments_received_total
  FROM social_posts sp
  LEFT JOIN social_likes sl   ON sl.post_id = sp.id
  LEFT JOIN social_comments sc ON sc.post_id = sp.id
  GROUP BY sp.user_id
),
followers AS (
  SELECT f.followed_user_id AS user_id,
         COUNT(*) AS followers_count
  FROM follows f
  GROUP BY f.followed_user_id
),
copiers AS (
  SELECT ctl.leader_user_id AS user_id,
         COUNT(*) AS copiers_count
  FROM copy_trading_links ctl
  WHERE ctl.stopped_at IS NULL  -- activos
  GROUP BY ctl.leader_user_id
)
SELECT u.id AS user_id,
       COALESCE(s.posts_total,0) AS posts_total,
       COALESCE(s.comments_total,0) AS comments_total,
       COALESCE(s.likes_given_total,0) AS likes_given_total,
       COALESCE(er.likes_received_total,0) AS likes_received_total,
       COALESCE(er.comments_received_total,0) AS comments_received_total,
       COALESCE(f.followers_count,0) AS followers_count,
       COALESCE(c.copiers_count,0) AS copiers_count
FROM users u
LEFT JOIN social s  ON s.user_id = u.id
LEFT JOIN engagement_received er ON er.user_id = u.id
LEFT JOIN followers f ON f.user_id = u.id
LEFT JOIN copiers c   ON c.user_id = u.id;
