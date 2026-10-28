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
-- The contracts an account is made of: active, signed and sent to the insurer (subscription_status 5), and at an
-- ops stage where the client is actually handled - reviewed (2), onboarding (4), onboarded (3) or suspended (7). A
-- client with none of them has no contract here, so it shows nowhere in "Attribution portefeuille".
contracts AS (
  SELECT ic.id, ic.user_pro_id,
         IF(ic.type = 'CompanyHealthMutualInternalContract', 'sante', 'prevoyance') AS risque,
         IFNULL(ic.offer_kind, -1) != 3 AS standard
  FROM %{dataset}.internal_contracts ic
  WHERE ic.contract_status = 'Actif'
    AND ic.type IN ('CompanyHealthMutualInternalContract', 'CompanyProvidentInsuranceInternalContract')
    AND ic.subscription_status = 5
    AND ic.operation_status IN (2, 3, 4, 7)
),
-- The ARR engine of SideCare Analytics, one row per active contract (see BiArrEstimateSql). AnalyticsArr chooses,
-- contract by contract and as Analytics does, between the invoiced ARR and the estimate.
%{arr_estimate_ctes}
-- One row per account and contract (one row with no contract for an account without any); BiPortfolioSync adds the
-- contracts of an account up.
SELECT am.kind, am.account_id,
       IF(am.kind = 'set', cs.name, up.social_name) AS name,
       IF(am.kind = 'user_pro', up.siren, NULL) AS siren,
       am.user_pros_count,
       a.email AS am_email, a.name AS am_name,
       IFNULL(g.visible_employees_count, g.employees_count) AS employees_count,
       c.id AS account_contract_id, c.risque, c.standard, e.*
FROM account_am am
LEFT JOIN administrators a ON a.id = am.am_id
LEFT JOIN company_sets cs ON am.kind = 'set' AND cs.id = am.account_id
LEFT JOIN user_pros up ON am.kind = 'user_pro' AND up.id = am.account_id
LEFT JOIN %{dataset}.groups_bo g ON g.group_type = am.kind AND g.group_id = am.account_id
LEFT JOIN (
  SELECT c.*, mb.kind, mb.account_id FROM contracts c JOIN members mb ON mb.user_pro_id = c.user_pro_id
) c ON c.kind = am.kind AND c.account_id = am.account_id
LEFT JOIN contract_arr_engine e ON e.contract_id = c.id
-- Only what the page can show: every account with an AM, and unassigned accounts with a contract (the "sans AM"
-- list keeps the big enough ones).
WHERE am.am_id IS NOT NULL OR c.id IS NOT NULL
