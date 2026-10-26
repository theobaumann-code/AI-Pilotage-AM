-- One row per BI account: a company set, or a user pro that belongs to no set. Read by BiPortfolioSync.
-- Tables are read from the dataset BiPortfolioSync#sql fills in (e.g. `project.BI_EU`).
WITH
user_pros AS (
  SELECT id, social_name, siren, account_manager_administrator_id AS am_id
  FROM %{dataset}.s_user_pros
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _PARTITIONTIME DESC) = 1
),
administrators AS (
  SELECT id, LOWER(TRIM(email)) AS email, TRIM(CONCAT(IFNULL(first_name, ''), ' ', IFNULL(last_name, ''))) AS name
  FROM %{dataset}.s_administrators
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _PARTITIONTIME DESC) = 1
),
company_sets AS (
  SELECT id, name
  FROM %{dataset}.s_company_sets
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _PARTITIONTIME DESC) = 1
),
-- A handful of user pros sit in several sets: keep the most recent membership.
memberships AS (
  SELECT user_pro_id, company_set_id
  FROM %{dataset}.s_company_setings
  QUALIFY ROW_NUMBER() OVER (PARTITION BY user_pro_id ORDER BY created_at DESC, id DESC) = 1
),
-- Every user pro mapped to its account: its company set if it has one, otherwise itself.
members AS (
  SELECT up.id AS user_pro_id, up.am_id,
         IF(m.company_set_id IS NULL, 'user_pro', 'set') AS kind,
         IFNULL(m.company_set_id, up.id) AS account_id
  FROM user_pros up
  LEFT JOIN memberships m ON m.user_pro_id = up.id
),
-- The AM of a company set is the set's own "responsable AM" as the BO exposes it (groups_bo), resolved to
-- the administrator carrying that name among the set's user pros. A user pro outside any set uses its own AM.
set_am AS (
  SELECT g.group_id AS account_id, ANY_VALUE(mb.am_id) AS am_id
  FROM %{dataset}.groups_bo g
  JOIN members mb ON mb.kind = 'set' AND mb.account_id = g.group_id
  JOIN administrators a ON a.id = mb.am_id AND a.name = TRIM(g.account_manager)
  WHERE g.group_type = 'set'
  GROUP BY 1
),
account_am AS (
  SELECT mb.kind, mb.account_id, ANY_VALUE(IF(mb.kind = 'set', s.am_id, mb.am_id)) AS am_id, COUNT(*) AS user_pros_count
  FROM members mb
  LEFT JOIN set_am s ON mb.kind = 'set' AND s.account_id = mb.account_id
  GROUP BY 1, 2
),
contracts AS (
  SELECT ic.id, ic.user_pro_id,
         IF(ic.type = 'CompanyHealthMutualInternalContract', 'sante', 'prevoyance') AS risque,
         IFNULL(ic.offer_kind, -1) != 3 AS standard
  FROM %{dataset}.internal_contracts ic
  WHERE ic.contract_status = 'Actif'
    AND ic.type IN ('CompanyHealthMutualInternalContract', 'CompanyProvidentInsuranceInternalContract')
),
-- ARR = SideCare's commission on the contract's premiums (HT × total commission rate), annualised from Q1 2026
-- invoicing - the most reliable billing period. A contract not invoiced in Q1 (started since) is annualised from
-- its last three months invoiced after Q1 instead. Real invoices win over "factice" ones when a contract has both.
entries AS (
  SELECT e.internal_contract_id AS contract_id, DATE_TRUNC(e.invoice_start_date, MONTH) AS month, e.purpose,
         e.price * e.quantity * IFNULL(e.total_commission_rate, 0) AS commission
  FROM %{dataset}.invoice_entries e
  JOIN contracts c ON c.id = e.internal_contract_id
  WHERE e.purpose IN ('Facture réelle', 'Facture factice')
),
entries_kept AS (
  SELECT *
  FROM entries
  QUALIFY purpose = IF(LOGICAL_OR(purpose = 'Facture réelle') OVER (PARTITION BY contract_id), 'Facture réelle', 'Facture factice')
),
contract_months AS (
  SELECT contract_id, month, SUM(commission) AS commission FROM entries_kept GROUP BY 1, 2
),
contract_arr AS (
  SELECT contract_id,
         IF(COUNTIF(month BETWEEN '2026-01-01' AND '2026-03-01') > 0,
            SUM(IF(month BETWEEN '2026-01-01' AND '2026-03-01', commission, 0)) * 4,
            SAFE_DIVIDE(SUM(IF(month > '2026-03-01' AND recent_rank <= 3, commission, 0)) * 12,
                        COUNTIF(month > '2026-03-01' AND recent_rank <= 3))) AS arr,
         IF(COUNTIF(month BETWEEN '2026-01-01' AND '2026-03-01') > 0, 'T1 2026', 'après T1') AS basis
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY month DESC) AS recent_rank FROM contract_months)
  GROUP BY 1
),
account_contracts AS (
  SELECT mb.kind, mb.account_id, c.risque, c.standard, IFNULL(ca.arr, 0) AS arr, ca.basis
  FROM contracts c
  JOIN members mb ON mb.user_pro_id = c.user_pro_id
  LEFT JOIN contract_arr ca ON ca.contract_id = c.id
),
accounts AS (
  SELECT kind, account_id,
         SUM(arr) AS arr,
         SUM(IF(risque = 'sante', arr, 0)) AS arr_sante,
         SUM(IF(risque = 'prevoyance', arr, 0)) AS arr_prevoyance,
         LOGICAL_OR(risque = 'sante') AS has_sante,
         LOGICAL_OR(risque = 'prevoyance') AS has_prevoyance,
         LOGICAL_OR(risque = 'sante' AND standard) AS has_standard_sante,
         COUNT(*) AS contracts_count,
         COUNTIF(basis = 'après T1') AS contracts_without_q1
  FROM account_contracts
  GROUP BY 1, 2
)
SELECT am.kind, am.account_id,
       IF(am.kind = 'set', cs.name, up.social_name) AS name,
       IF(am.kind = 'user_pro', up.siren, NULL) AS siren,
       am.user_pros_count,
       a.email AS am_email, a.name AS am_name,
       IFNULL(acc.arr, 0) AS arr, IFNULL(acc.arr_sante, 0) AS arr_sante, IFNULL(acc.arr_prevoyance, 0) AS arr_prevoyance,
       IFNULL(acc.has_sante, FALSE) AS has_sante, IFNULL(acc.has_prevoyance, FALSE) AS has_prevoyance,
       IFNULL(acc.has_standard_sante, FALSE) AS has_standard_sante,
       IFNULL(acc.contracts_count, 0) AS contracts_count, IFNULL(acc.contracts_without_q1, 0) AS contracts_without_q1,
       IFNULL(g.visible_employees_count, g.employees_count) AS employees_count
FROM account_am am
LEFT JOIN administrators a ON a.id = am.am_id
LEFT JOIN accounts acc ON acc.kind = am.kind AND acc.account_id = am.account_id
LEFT JOIN company_sets cs ON am.kind = 'set' AND cs.id = am.account_id
LEFT JOIN user_pros up ON am.kind = 'user_pro' AND up.id = am.account_id
LEFT JOIN %{dataset}.groups_bo g ON g.group_type = am.kind AND g.group_id = am.account_id
-- Only what the page shows: every account with an AM, and unassigned accounts big enough for the "sans AM" list.
WHERE am.am_id IS NOT NULL OR IFNULL(acc.arr, 0) > 2000
