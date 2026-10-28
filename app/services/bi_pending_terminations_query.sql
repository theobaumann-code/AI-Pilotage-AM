-- Temporary "Suivi des résiliations": one row per BO contract termination created in 2026, whatever its status
-- (as of the latest snapshot), with the account it belongs to. Read by BiPendingTerminationSync.
WITH
terminations AS (
  SELECT *
  FROM %{dataset}.s_contract_terminations
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _PARTITIONTIME DESC, updated_at DESC) = 1
),
user_pros AS (
  SELECT id, social_name
  FROM %{dataset}.s_user_pros
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _PARTITIONTIME DESC) = 1
),
-- Same account mapping as bi_portfolio_query.sql: the user pro's company set (latest membership), otherwise itself.
memberships AS (
  SELECT user_pro_id, company_set_id
  FROM %{dataset}.s_company_setings
  QUALIFY ROW_NUMBER() OVER (PARTITION BY user_pro_id ORDER BY created_at DESC, id DESC) = 1
),
-- ARR of a SideCare contract being terminated: its Q1 2026 commission × 4, real invoices winning over "factice"
-- ones, health brought back to net (without the TSA) as everywhere else.
q1_entries AS (
  SELECT e.internal_contract_id AS contract_id, e.purpose,
         SUM(e.price * e.quantity * IFNULL(e.total_commission_rate, 0)) AS commission
  FROM %{dataset}.invoice_entries e
  WHERE e.purpose IN ('Facture réelle', 'Facture factice')
    AND e.invoice_start_date BETWEEN '2026-01-01' AND '2026-03-31'
    AND e.internal_contract_id IN (SELECT terminable_id FROM terminations
                                   WHERE created_at >= '2026-01-01' AND terminable_type = 'InternalContract')
  GROUP BY 1, 2
),
q1_arr AS (
  SELECT contract_id, ARRAY_AGG(commission ORDER BY purpose = 'Facture réelle' DESC LIMIT 1)[OFFSET(0)] * 4 AS arr
  FROM q1_entries
  GROUP BY 1
)
SELECT t.id AS bi_id, t.name, t.terminable_type, t.terminable_id, t.product_type, t.college_type, t.operation_status,
       t.user_pro_id, up.social_name,
       IF(m.company_set_id IS NULL, 'user_pro', 'set') AS account_kind,
       IFNULL(m.company_set_id, t.user_pro_id) AS account_bi_id,
       DATE(t.created_at) AS created_on, t.termination_date,
       IF(t.terminable_type = 'InternalContract',
          q.arr / IF(t.product_type IN (1, 4), 1 + %{health_tsa_rate}, 1), NULL) AS contract_arr
FROM terminations t
LEFT JOIN user_pros up ON up.id = t.user_pro_id
LEFT JOIN memberships m ON m.user_pro_id = t.user_pro_id
LEFT JOIN q1_arr q ON t.terminable_type = 'InternalContract' AND q.contract_id = t.terminable_id
WHERE t.created_at >= '2026-01-01' AND t.user_pro_id IS NOT NULL
