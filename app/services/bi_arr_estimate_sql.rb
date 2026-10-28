# SQL half of the ARR engine of SideCare Analytics (lounna-team/ai-sidecare-analytics, src/lib/bq/arr.ts:
# getContractARR), ported to the BI portfolio sync. One row per active collective contract with everything the Ruby
# half (AnalyticsArr) needs to choose, as Analytics does, between the invoiced ARR and the estimated one:
#
#   invoiced ARR  = last complete, exploitable invoiced period, annualised by the duration it covers
#   estimated ARR = expected affiliates × annual premium per affiliate × total commission rate
#
# Ported from, in Analytics: arr.ts (contracts, commission, pricing hierarchy, final row), arr-invoice-sql.ts,
# premium-regularization-sql.ts and invoice-readiness-sql.ts (invoice periods and whether they are representative),
# arr-population-sql.ts and confirmed-population-sql.ts (health census, confirmed affiliates), health-pricing-sql.ts
# and health-dated-pricing-sql.ts (health grids, PMSS-indexed tariffs), live-pricing-sql.ts (family mix and portfolio
# benchmarks), provident-live-reference-sql.ts (provident DSN contributions). The population conversion itself is
# applied in Ruby (AnalyticsArr), like Analytics' arr-population-conversion.ts.
#
# Not ported, irrelevant to an AM portfolio: TNS individual contracts, manual ARR inputs of the sales bonus, the
# deflation of closed years and the live affiliation rates (off in Analytics' production).
module BiArrEstimateSql
  HEALTH = "CompanyHealthMutualInternalContract".freeze
  PROVIDENT = "CompanyProvidentInsuranceInternalContract".freeze

  # Plafond mensuel de la sécurité sociale (Urssaf, cas général), for health grids indexed on it. Analytics reads the
  # dated schedule from the Urssaf API; add each new year here in January.
  PMSS_MONTHLY = { 2024 => 3864, 2025 => 3925, 2026 => 4005 }.freeze

  # Analytics' arr-invoice-readiness.ts: before M+2, an invoice is mature once 75 % of the signed employees are billed.
  EARLY_INVOICE_AFFILIATION_THRESHOLD = 0.75

  FEE_FIELDS = %w[fee_price fee_price_adult fee_price_family fee_price_child fee_price_partner fee_price_duo
                  fee_price_unique fee_price_duo_family fee_price_duo_child fee_price_salarie_with_children
                  fee_price_salarie_with_partner].freeze

  TODAY = "CURRENT_DATE('Europe/Paris')".freeze

  module_function

  # CTEs to insert in a WITH clause; they need `company_sets` (id, name) defined before them. The last one,
  # contract_arr_engine, has one row per active collective contract (see AnalyticsArr::ENGINE_COLUMNS). `year` is
  # Analytics' ARR year: its invoices are read from January 1st of that year.
  def ctes(dataset, year: Time.find_zone("Europe/Paris").today.year)
    [ contracts_ctes(dataset), invoice_ctes(dataset, year), population_ctes(dataset), health_fee_ctes(dataset),
      health_affiliation_ctes(dataset), provident_ctes(dataset), reference_ctes, estimate_ctes ].join(",\n")
  end

  # ---------- Contracts, commission and target population (arr.ts: all_contracts, contracts) ----------

  def contracts_ctes(dataset)
    <<~SQL.chomp
      est_pmss AS (
        SELECT year, CAST(monthly AS NUMERIC) AS monthly
        FROM UNNEST([#{PMSS_MONTHLY.map { |year, monthly| "STRUCT(#{year} AS year, #{monthly} AS monthly)" }.join(", ")}])
      ),
      est_all_contracts AS (
        SELECT ic.*
        FROM #{dataset}.internal_contracts ic
        WHERE ic.contract_status = 'Actif'
          AND ic.type IN ('#{HEALTH}', '#{PROVIDENT}')
          AND (ic.is_external_affiliation = false OR ic.is_external_affiliation IS NULL)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ic.id ORDER BY ic.updated_at DESC) = 1
      ),
      est_avg_commission_rates AS (
        SELECT banking_actor_name, type, AVG(NULLIF(commission_rate, 0)) AS avg_commission_rate
        FROM est_all_contracts
        WHERE commission_rate > 0
        GROUP BY banking_actor_name, type
      ),
      est_contracts_base AS (
        SELECT
          ic.id AS contract_id, ic.type AS contract_type, ic.user_pro_id, ic.college, ic.use_fee_entry_date,
          ic.start_date AS contract_start_date, ic.payment_frequency_invoice AS expected_invoice_frequency,
          up.ccn, ic.ta_rate, ic.tb_rate, ic.tc_rate,
          COALESCE(cs.id, ic.group_id, ic.user_pro_id) AS group_id,
          IF(cs.id IS NOT NULL, 'set', 'user_pro') AS group_type,
          COALESCE(NULLIF(ic.commission_rate, 0), acr.avg_commission_rate, 0)
            + IFNULL(ic.supervisor_retro_commission_rate, 0) AS total_commission_rate,
          IFNULL(ic.salaries_count, 0) AS salaries_count,
          IFNULL(ic.matching_visible_employees_count, 0) AS visible_employees
        FROM est_all_contracts ic
        LEFT JOIN #{dataset}.user_pros up ON up.id = ic.user_pro_id
        LEFT JOIN company_sets cs ON ic.group_id = cs.id AND ic.group_id != ic.user_pro_id
        LEFT JOIN est_avg_commission_rates acr ON acr.banking_actor_name = ic.banking_actor_name AND acr.type = ic.type
      ),
      est_contracts_signed AS (
        -- The group's signed headcount is a fallback only when no contract of the group/risk has its own, and it is
        -- given to one contract only, so empty subsidiaries don't each receive the whole group.
        SELECT c.*,
          CASE
            WHEN c.salaries_count > 0 THEN c.salaries_count
            WHEN SUM(c.salaries_count) OVER (PARTITION BY c.group_id, c.contract_type) = 0
                 AND ROW_NUMBER() OVER (PARTITION BY c.group_id, c.contract_type ORDER BY c.contract_id) = 1
              THEN IFNULL(bg.sign_total, 0)
            ELSE 0
          END AS effective_salaries
        FROM est_contracts_base c
        LEFT JOIN #{dataset}.bi_groups bg ON bg.group_id = c.group_id AND bg.group_type = c.group_type
      ),
      est_contracts AS (
        -- Signed employees sit on one contract per group/risk while visibles are spread over subsidiaries: the share
        -- of visibles is read at that level (arr-population-conversion.ts: withGroupRiskPopulation).
        SELECT c.*,
          SUM(c.visible_employees) OVER (PARTITION BY c.group_type, c.group_id, c.contract_type) AS group_risk_visibles,
          SUM(c.effective_salaries) OVER (PARTITION BY c.group_type, c.group_id, c.contract_type) AS group_risk_signed
        FROM est_contracts_signed c
      )
    SQL
  end

  # ---------- Invoices: recurring base, regularisations, readiness (arr-invoice-sql.ts and its two inputs) ----------

  def invoice_ctes(dataset, year)
    year_start = "DATE '#{year}-01-01'"
    invoice_end = "LEAST(#{TODAY}, DATE '#{year + 1}-01-01')"
    person = lambda do |column|
      clean = "REGEXP_REPLACE(UPPER(TRIM(#{column})), r'[^0-9AB]', '')"
      "IF(LENGTH(#{clean}) IN (13,15) AND REGEXP_CONTAINS(#{clean}, r'^[123478]'), SUBSTR(#{clean},1,13), NULL)"
    end
    threshold = EARLY_INVOICE_AFFILIATION_THRESHOLD
    <<~SQL.chomp
      est_eligible_premium_invoices AS (
        SELECT DISTINCT i.id, i.internal_contract_id AS contract_id, c.user_pro_id,
          i.invoiceable_type, i.invoiceable_id, i.start_date, i.end_date,
          i.invoice_entries AS amount,
          COALESCE(i.total_commission_rate, c.total_commission_rate, 0) AS total_commission_rate,
          IFNULL(i.payment_frequency_invoice, 1) AS frequency
        FROM #{dataset}.invoices i
        JOIN est_contracts c ON c.contract_id = i.internal_contract_id
        WHERE i.operation_status NOT IN ('cancelled', 'problem_with_dsn')
          AND i.purpose = 1
          AND i.type NOT IN ('CancellationCreditNote', 'CancelledWithCreditNoteInvoice', 'CancellationCreditNoteWithRefund')
          AND i.internal_invoice_management IS TRUE
          AND i.invoice_entries IS NOT NULL
          AND i.end_date >= #{year_start}
          AND i.start_date <= #{TODAY}
          AND (i.invoiceable_type = 'InternalContract'
            OR (c.contract_type = '#{HEALTH}' AND i.invoiceable_type = 'HealthMutualAffiliation'))
      ),
      est_observation_invoices AS (
        SELECT i.* FROM est_eligible_premium_invoices i WHERE i.start_date >= #{year_start} AND i.end_date < #{invoice_end}
      ),
      est_source_premium_invoices AS (
        SELECT i.* FROM est_eligible_premium_invoices i
        JOIN (SELECT contract_id, MIN(start_date) AS first_start FROM est_observation_invoices GROUP BY contract_id) o
          ON o.contract_id = i.contract_id AND i.end_date >= o.first_start
      ),
      est_source_premium_entries AS (
        SELECT ie.id, ie.invoice_id, ie.price, ie.quantity,
          ie.contextable_type, ie.contextable_id, ie.updated_at,
          ie.start_date, ie.end_date, ie.price * COALESCE(ie.quantity, 1) AS amount,
          i.contract_id, i.invoiceable_type, i.invoiceable_id,
          i.start_date AS invoice_start, i.end_date AS invoice_end,
          IFNULL(ie.start_date <= ie.end_date AND ie.end_date < i.start_date, FALSE) AS dated_arrears,
          STARTS_WITH(LOWER(TRIM(IFNULL(ie.name, ''))), 'correction des mois précédents') AS cumulative_correction
        FROM est_source_premium_invoices i
        JOIN #{dataset}.s_invoice_entries ie ON ie.invoice_id = i.id
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ie.id ORDER BY ie.updated_at DESC) = 1
      ),
      est_premium_dsn_latest AS (
        SELECT d.id, d.validated
        FROM #{dataset}.s_cotisation_individu_urssafs d
        WHERE d.id IN (SELECT contextable_id FROM est_source_premium_entries WHERE contextable_type = 'CotisationIndividuUrssaf')
        QUALIFY ROW_NUMBER() OVER (PARTITION BY d.id ORDER BY d.updated_at DESC) = 1
      ),
      est_source_premium_totals AS (
        -- A missing or invalid DSN rejects the whole observation rather than inventing a credit note.
        SELECT e.invoice_id, SUM(e.amount) AS amount,
          COUNTIF(e.amount IS NULL OR (e.contextable_type = 'CotisationIndividuUrssaf'
            AND d.validated IS NOT TRUE AND ABS(e.amount) > 0.005)) AS invalid_entries
        FROM est_source_premium_entries e
        LEFT JOIN est_premium_dsn_latest d ON e.contextable_type = 'CotisationIndividuUrssaf' AND e.contextable_id = d.id
        GROUP BY e.invoice_id
      ),
      est_observation_cycles AS (
        -- The recurring base, once older-period arrears and refunds are taken out.
        SELECT DISTINCT i.contract_id, i.invoiceable_type, i.invoiceable_id, i.start_date, i.end_date
        FROM est_observation_invoices i
        LEFT JOIN (SELECT invoice_id, SUM(IF(dated_arrears, amount, 0)) AS arrears
          FROM est_source_premium_entries GROUP BY invoice_id) e ON e.invoice_id = i.id
        WHERE i.amount - IFNULL(e.arrears, 0) > 0 AND i.start_date = DATE_TRUNC(i.start_date, MONTH)
          AND i.end_date = LAST_DAY(i.end_date) AND i.start_date <= i.end_date
      ),
      est_premium_entry_destinations AS (
        SELECT e.id, COUNT(c.contract_id) AS matches, MIN(c.start_date) AS target_start, MIN(c.end_date) AS target_end
        FROM est_source_premium_entries e
        LEFT JOIN est_observation_cycles c ON e.dated_arrears
          AND c.contract_id = e.contract_id AND c.invoiceable_type = e.invoiceable_type
          AND c.invoiceable_id = e.invoiceable_id
          AND e.start_date >= c.start_date AND e.end_date <= c.end_date
        GROUP BY e.id
      ),
      est_premium_entry_allocation AS (
        -- Dated arrears go back to the cycle they cover; undated cumulative corrections invalidate their invoice.
        SELECT e.*, d.matches,
          IF(e.dated_arrears, d.target_start, e.invoice_start) AS target_start,
          IF(e.dated_arrears, d.target_end, e.invoice_end) AS target_end,
          ABS(e.amount) > 0.005 AND ((e.cumulative_correction AND NOT e.dated_arrears)
            OR (e.dated_arrears AND d.matches > 1)
            OR (e.start_date IS NOT NULL AND e.end_date IS NOT NULL
              AND (e.start_date > e.end_date OR (e.start_date < e.invoice_start AND NOT e.dated_arrears)))) AS unallocated
        FROM est_source_premium_entries e JOIN est_premium_entry_destinations d USING (id)
      ),
      est_premium_invoice_slices AS (
        SELECT i.id AS source_invoice_id, i.start_date, i.end_date,
          i.amount - IFNULL(SUM(IF(e.dated_arrears, e.amount, 0)), 0) AS amount,
          COUNTIF(e.unallocated AND NOT e.dated_arrears) = 0 AS allocated
        FROM est_observation_invoices i LEFT JOIN est_premium_entry_allocation e ON e.invoice_id = i.id
        GROUP BY i.id, i.start_date, i.end_date, i.amount
        UNION ALL
        SELECT e.invoice_id, e.target_start, e.target_end, SUM(e.amount), TRUE
        FROM est_premium_entry_allocation e
        WHERE e.dated_arrears AND e.matches = 1
        GROUP BY e.invoice_id, e.target_start, e.target_end
      ),
      est_selected_invoices AS (
        SELECT CONCAT(CAST(i.id AS STRING), ':', CAST(s.start_date AS STRING), ':', CAST(s.end_date AS STRING)) AS id,
          i.id AS source_invoice_id, i.contract_id, i.user_pro_id, i.invoiceable_type,
          s.amount > 0 AND s.start_date = i.start_date AND s.end_date = i.end_date AS is_base_invoice,
          s.end_date AS period, s.amount, i.total_commission_rate,
          s.start_date = DATE_TRUNC(s.start_date, MONTH) AND s.end_date = LAST_DAY(s.end_date)
            AND s.allocated AND IFNULL(t.invalid_entries = 0 AND ABS(t.amount - i.amount) < 0.02, FALSE) AS full_period,
          SAFE_DIVIDE(12.0, NULLIF(DATE_DIFF(DATE_ADD(s.end_date, INTERVAL 1 DAY), s.start_date, MONTH), 0)) AS annual_factor,
          i.frequency
        FROM est_premium_invoice_slices s JOIN est_source_premium_invoices i ON i.id = s.source_invoice_id
        LEFT JOIN est_source_premium_totals t ON t.invoice_id = i.id
      ),
      est_selected_premium_entries AS (
        SELECT e.* EXCEPT (invoice_id),
          CONCAT(CAST(e.invoice_id AS STRING), ':', CAST(e.target_start AS STRING), ':', CAST(e.target_end AS STRING)) AS invoice_id
        FROM est_premium_entry_allocation e
        WHERE NOT e.dated_arrears OR e.matches = 1
      ),
      est_readiness_dsn AS (
        SELECT d.* FROM #{dataset}.s_cotisation_individu_urssafs d
        JOIN (SELECT DISTINCT contextable_id FROM est_source_premium_entries WHERE contextable_type = 'CotisationIndividuUrssaf') e
          ON e.contextable_id = d.id
        QUALIFY ROW_NUMBER() OVER (PARTITION BY d.id ORDER BY d.updated_at DESC) = 1
      ),
      est_readiness_employees AS (
        SELECT e.id, e.user_pro_id,
          IF(COUNT(DISTINCT #{person.call("e.social_security_number")}) = 1, MAX(#{person.call("e.social_security_number")}), NULL) AS person_key
        FROM #{dataset}.employees e GROUP BY 1, 2
      ),
      est_readiness_lines AS (
        -- A full invoice header does not mean every employee was covered all along: only employees whose every line
        -- covers the whole cycle train the price.
        SELECT ie.id, i.contract_id, i.period, i.invoiceable_type, i.is_base_invoice, ie.amount,
          ie.amount * i.annual_factor AS annual_amount,
          CASE WHEN d.id IS NOT NULL THEN CONCAT('person:', CAST(i.user_pro_id AS STRING), ':', #{person.call("d.social_security_number")})
            WHEN e.person_key IS NOT NULL THEN CONCAT('person:', CAST(i.user_pro_id AS STRING), ':', e.person_key)
            WHEN COALESCE(h.employee_id, p.employee_id) IS NOT NULL THEN CONCAT('employee:', CAST(COALESCE(h.employee_id, p.employee_id) AS STRING))
            ELSE NULL END AS person_key,
          ie.contextable_type = 'CotisationIndividuUrssaf' AND IFNULL(d.validated, FALSE) = FALSE AS invalid_dsn,
          ie.start_date <= DATE_SUB(DATE_ADD(i.period, INTERVAL 1 DAY), INTERVAL CAST(ROUND(12 / i.annual_factor) AS INT64) MONTH)
            AND ie.end_date >= i.period AS full_exposure
        FROM est_selected_invoices i JOIN est_selected_premium_entries ie ON ie.invoice_id = i.id
        LEFT JOIN est_readiness_dsn d ON ie.contextable_type = 'CotisationIndividuUrssaf' AND d.id = ie.contextable_id AND d.internal_contract_id = i.contract_id
        LEFT JOIN #{dataset}.health_mutual_affiliations h ON ie.contextable_type = 'HealthMutualAffiliation' AND h.id = ie.contextable_id AND h.internal_contract_id = i.contract_id
        LEFT JOIN #{dataset}.provident_insurance_affiliations p ON ie.contextable_type = 'ProvidentInsuranceAffiliation' AND p.id = ie.contextable_id AND p.internal_contract_id = i.contract_id
        LEFT JOIN est_readiness_employees e ON e.id = COALESCE(h.employee_id, p.employee_id) AND e.user_pro_id = i.user_pro_id
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ie.id, i.id ORDER BY ie.updated_at DESC) = 1
      ),
      est_readiness_people AS (
        SELECT contract_id, period, person_key, SUM(annual_amount) AS annual_premium,
          LOGICAL_AND(IF(ABS(amount) > 0.005, IFNULL(full_exposure, FALSE) AND NOT invalid_dsn, TRUE)) AS full_exposure,
          COUNTIF(invoiceable_type = 'InternalContract' AND is_base_invoice AND amount > 0) > 0 AS has_base
        FROM est_readiness_lines WHERE person_key IS NOT NULL GROUP BY 1, 2, 3 HAVING SUM(annual_amount) > 0.005
      ),
      est_readiness_samples AS (
        SELECT contract_id, period, COUNTIF(has_base) AS billed_people, COUNTIF(NOT has_base) AS orphan_people,
          COUNTIF(has_base AND full_exposure) AS full_people,
          AVG(IF(has_base AND full_exposure, annual_premium, NULL)) AS annual_price,
          COUNTIF(has_base AND NOT full_exposure) AS partial_people
        FROM est_readiness_people GROUP BY 1, 2
      ),
      est_readiness_periods AS (
        SELECT contract_id, period, COUNTIF(ABS(amount) > 0.005 AND (invalid_dsn OR person_key IS NULL)) AS invalid_lines
        FROM est_readiness_lines GROUP BY 1, 2
      ),
      est_invoice_periods AS (
        SELECT s.contract_id AS internal_contract_id, c.contract_type, s.period AS month_start,
          MAX(c.contract_start_date) AS contract_start_date,
          -- A group fallback allocated to one contract is not its signed base.
          MAX(c.salaries_count) AS signed_people,
          MAX(c.expected_invoice_frequency) AS expected_invoice_frequency,
          MIN(IF(s.invoiceable_type = 'InternalContract' AND s.is_base_invoice, 12 / s.annual_factor, NULL)) AS base_months,
          MIN(IF(s.invoiceable_type = 'InternalContract' AND s.is_base_invoice,
            DATE_SUB(DATE_ADD(s.period, INTERVAL 1 DAY), INTERVAL CAST(ROUND(12 / s.annual_factor) AS INT64) MONTH), NULL)) AS base_start,
          MIN(DATE_SUB(DATE_ADD(s.period, INTERVAL 1 DAY), INTERVAL CAST(ROUND(12 / s.annual_factor) AS INT64) MONTH)) AS coverage_start,
          DATE_ADD(s.period, INTERVAL 1 DAY) AS month_end,
          SAFE_DIVIDE(SUM(s.amount * s.annual_factor * s.total_commission_rate), SUM(s.amount * s.annual_factor)) AS total_commission_rate,
          SUM(s.amount * s.annual_factor) AS annual_primes,
          LOGICAL_AND(s.full_period AND s.annual_factor > 0) AS complete,
          COUNTIF(s.invoiceable_type = 'InternalContract' AND s.is_base_invoice) > 0 AS has_base,
          CONCAT('Contrat #', CAST(s.contract_id AS STRING), ' : période complète terminée le ', CAST(s.period AS STRING),
            '. Annualisation par durée couverte : ', STRING_AGG(DISTINCT CONCAT(CAST(ROUND(12 / s.annual_factor) AS STRING), ' mois × ', CAST(s.annual_factor AS STRING)), ' ; '),
            '. Régularisations datées réattribuées à leur période.') AS invoice_reference
        FROM est_selected_invoices s JOIN est_contracts c ON c.contract_id = s.contract_id
        GROUP BY s.contract_id, c.contract_type, s.period
      ),
      est_invoice_affiliate_periods AS (
        SELECT ip.internal_contract_id, ip.month_start, COUNT(DISTINCT h.employee_id) AS affiliates
        FROM est_invoice_periods ip
        LEFT JOIN #{dataset}.health_mutual_affiliations h
          ON h.internal_contract_id = ip.internal_contract_id
         AND h.ins_first_validated_date IS NOT NULL
         AND COALESCE(h.start_date, h.affil_start_date, h.ins_first_validated_date) < ip.month_end
         AND (COALESCE(h.end_date, h.affil_end_date) IS NULL OR COALESCE(h.end_date, h.affil_end_date) >= ip.coverage_start)
        WHERE ip.contract_type = '#{HEALTH}'
        GROUP BY 1, 2
        UNION ALL
        SELECT ip.internal_contract_id, ip.month_start, COUNT(DISTINCT p.employee_id) AS affiliates
        FROM est_invoice_periods ip
        LEFT JOIN #{dataset}.provident_insurance_affiliations p
          ON p.internal_contract_id = ip.internal_contract_id
         AND p.affiliation_status = 5
         AND COALESCE(p.calc_start_date, p.start_date, p.entry_date) < ip.month_end
         AND (COALESCE(p.calc_end_date, p.end_date) IS NULL OR COALESCE(p.calc_end_date, p.end_date) >= ip.coverage_start)
        WHERE ip.contract_type = '#{PROVIDENT}'
        GROUP BY 1, 2
      ),
      est_invoice_period_quality AS (
        SELECT ip.*, IFNULL(a.affiliates, 0) AS affiliates, IFNULL(r.invalid_lines, 1) AS invalid_lines,
          IFNULL(s.billed_people, 0) AS billed_people, IFNULL(s.full_people, 0) AS full_people,
          IFNULL(s.partial_people, 0) AS partial_people, IFNULL(s.orphan_people, 0) AS orphan_people, s.annual_price,
          IFNULL((ip.expected_invoice_frequency = 1 AND ip.base_months = 1) OR (ip.expected_invoice_frequency = 2 AND ip.base_months = 3), FALSE) AS valid_base_cycle,
          IFNULL((ip.expected_invoice_frequency = 1 AND ip.base_months = 1) OR (ip.expected_invoice_frequency = 2 AND ip.base_months = 3), FALSE)
            AND IFNULL(r.invalid_lines, 1) = 0 AND IFNULL(s.orphan_people, 0) = 0 AND IFNULL(s.billed_people, 0) > 0 AS billed_population_usable,
          IFNULL(ip.base_start >= DATE_ADD(ip.contract_start_date, INTERVAL 2 MONTH), FALSE) AS mature_by_age,
          IFNULL(ip.base_start >= ip.contract_start_date AND ip.signed_people > 0
            AND IFNULL(s.billed_people, 0) >= ip.signed_people * #{threshold}, FALSE) AS mature_by_affiliation
        FROM est_invoice_periods ip
        LEFT JOIN est_invoice_affiliate_periods a ON a.internal_contract_id = ip.internal_contract_id AND a.month_start = ip.month_start
        LEFT JOIN est_readiness_samples s ON s.contract_id = ip.internal_contract_id AND s.period = ip.month_start
        LEFT JOIN est_readiness_periods r ON r.contract_id = ip.internal_contract_id AND r.period = ip.month_start
        WHERE ip.complete AND ip.has_base AND ip.annual_primes > 0
          AND NOT (ip.contract_type = '#{HEALTH}' AND IFNULL(a.affiliates, 0) <= 0)
      ),
      est_invoice_agg AS (
        -- The latest exploitable period, with whether it is mature and representative enough to be the ARR.
        SELECT internal_contract_id, COUNT(*) OVER (PARTITION BY internal_contract_id) AS months_invoiced,
          total_commission_rate, affiliates AS invoice_affiliates, annual_primes AS factured_primes_annualisees,
          invoice_reference, month_start AS invoice_period,
          billed_population_usable, billed_population_usable AND full_people > 0 AND (mature_by_age OR mature_by_affiliation) AS readiness_eligible,
          CASE WHEN NOT valid_base_cycle THEN 'Cycle de base incomplet ou fréquence contractuelle non confirmée'
            WHEN invalid_lines > 0 OR orphan_people > 0 THEN 'Cotisations invalidées ou salariés facturés non identifiables'
            WHEN full_people = 0 THEN 'Aucun salarié avec toutes ses lignes sur une période entière'
            WHEN contract_start_date IS NULL THEN 'Date d’effet du contrat non renseignée'
            WHEN base_start < contract_start_date THEN 'Cycle antérieur à la date d’effet du contrat'
            WHEN mature_by_age THEN 'Période mature M+2 ; prix hors proratas disponible'
            WHEN mature_by_affiliation THEN 'Seuil atteint : au moins #{(threshold * 100).round} % des salariés signés sont facturés'
            WHEN IFNULL(signed_people, 0) <= 0 THEN 'Avant M+2 : effectif signé du contrat non renseigné'
            ELSE 'Avant M+2 : moins de #{(threshold * 100).round} % des salariés signés facturés' END AS readiness_reason,
          billed_people, full_people, partial_people, annual_price,
          CASE WHEN NOT billed_population_usable OR full_people = 0 THEN NULL
            WHEN mature_by_age THEN 'age' WHEN mature_by_affiliation THEN 'affiliation' ELSE NULL END AS maturity_basis
        FROM est_invoice_period_quality
        QUALIFY ROW_NUMBER() OVER (PARTITION BY internal_contract_id ORDER BY month_start DESC) = 1
      )
    SQL
  end

  # ---------- Population censuses (arr-population-sql.ts, confirmed-population-sql.ts) ----------

  def population_ctes(dataset)
    employed = "e.is_visible IS TRUE AND (e.employment_start_date IS NULL OR e.employment_start_date <= #{TODAY}) " \
               "AND (e.employment_end_date IS NULL OR e.employment_end_date >= #{TODAY})"
    mature = "c.contract_start_date IS NOT NULL AND DATE_ADD(c.contract_start_date, INTERVAL 2 MONTH) <= #{TODAY}"
    <<~SQL.chomp
      est_health_decisions AS (
        SELECT h.internal_contract_id, h.employee_id,
          LOGICAL_OR(h.type IN ('PositiveAffiliation', 'AutomaticAffiliation')
            AND h.insuree_status = 5 AND h.ins_first_validated_date <= #{TODAY}) AS affiliated,
          LOGICAL_OR(h.type = 'ExemptionAffiliation') AS exempt,
          LOGICAL_AND(h.type = 'ExemptionAffiliation' OR (h.type IN ('PositiveAffiliation', 'AutomaticAffiliation')
            AND h.insuree_status = 5 AND h.ins_first_validated_date <= #{TODAY})) AS resolved
        FROM #{dataset}.health_mutual_affiliations h
        JOIN est_contracts c ON c.contract_id = h.internal_contract_id
        JOIN #{dataset}.employees e ON e.id = h.employee_id AND e.user_pro_id = c.user_pro_id
        WHERE c.contract_type = '#{HEALTH}' AND #{employed}
          AND COALESCE(h.start_date, h.affil_start_date) <= #{TODAY}
          AND (COALESCE(h.end_date, h.affil_end_date) IS NULL OR COALESCE(h.end_date, h.affil_end_date) >= #{TODAY})
        GROUP BY 1, 2
      ),
      est_provident_decisions AS (
        SELECT p.internal_contract_id, p.employee_id,
          LOGICAL_OR(p.affiliation_status = 5) AS affiliated, FALSE AS exempt, LOGICAL_AND(p.affiliation_status = 5) AS resolved
        FROM #{dataset}.provident_insurance_affiliations p
        JOIN est_contracts c ON c.contract_id = p.internal_contract_id
        JOIN #{dataset}.employees e ON e.id = p.employee_id AND e.user_pro_id = c.user_pro_id
        WHERE c.contract_type = '#{PROVIDENT}' AND #{employed}
          AND COALESCE(p.calc_start_date, p.start_date, p.entry_date) <= #{TODAY}
          AND (COALESCE(p.calc_end_date, p.end_date) IS NULL OR COALESCE(p.calc_end_date, p.end_date) >= #{TODAY})
        GROUP BY 1, 2
      ),
      est_census AS (
        -- census_* is the health census (arr_health_census), confirmed_* the confirmed affiliates of both risks.
        SELECT c.contract_id,
          COUNT(h.employee_id) AS recorded_people,
          COUNTIF(h.affiliated AND NOT h.exempt) AS census_affiliated,
          COUNTIF(h.exempt AND NOT h.affiliated) AS census_exempt,
          COUNTIF(h.affiliated AND NOT h.exempt AND h.resolved IS TRUE) AS confirmed_affiliated,
          COUNTIF(h.exempt AND NOT h.affiliated AND h.resolved IS TRUE) AS confirmed_exempt,
          COUNTIF(h.resolved IS NOT TRUE OR (h.affiliated AND h.exempt)) AS unresolved_people,
          #{mature} AS census_mature,
          #{mature} AND c.visible_employees > 0 AND COUNT(h.employee_id) = c.visible_employees
            AND COUNTIF(h.resolved IS NOT TRUE OR (h.affiliated AND h.exempt)) = 0 AS census_complete
        FROM est_contracts c
        LEFT JOIN (SELECT * FROM est_health_decisions UNION ALL SELECT * FROM est_provident_decisions) h
          ON h.internal_contract_id = c.contract_id
        GROUP BY c.contract_id, c.contract_start_date, c.visible_employees
      )
    SQL
  end

  # ---------- Health grids (arr.ts: fee_date_active, fee_candidates, fee_entries_resolved, fee_agg) ----------

  def health_fee_ctes(dataset)
    observation = "GREATEST(#{TODAY}, COALESCE(c.contract_start_date, #{TODAY}))"
    <<~SQL.chomp
      est_fee_date_active AS (
        SELECT d.*, (SELECT monthly FROM est_pmss WHERE year = EXTRACT(YEAR FROM #{TODAY})) AS pmss_euros
        FROM #{dataset}.s_internal_contract_health_mutual_fee_entry_dates d
        JOIN #{dataset}.s_internal_contract_health_mutual_fee_entries f ON f.id = d.internal_contract_health_mutual_fee_entry_id
        JOIN est_contracts c ON c.contract_id = f.internal_contract_id
        WHERE d.is_active = true
          AND d.start_date <= #{observation}
          AND (d.end_date IS NULL OR d.end_date >= #{observation})
        QUALIFY ROW_NUMBER() OVER (PARTITION BY d.internal_contract_health_mutual_fee_entry_id ORDER BY d.start_date DESC, d.id DESC) = 1
      ),
      est_fee_candidates AS (
        SELECT f.internal_contract_id, f.id AS fee_entry_id, SAFE_CAST(f.cotisation_structure AS INT64) AS cotisation_structure,
          #{FEE_FIELDS.map { |field| "CAST(NULLIF(f.#{field}, 0) AS FLOAT64) AS #{field}" }.join(",\n    ")},
          IF(f.main_contract, 0, 1) AS main_sort, IFNULL(f.popularity_order, 999) AS popularity_sort, 0 AS source_sort
        FROM #{dataset}.internal_contract_health_mutual_fee_entries f
        JOIN est_contracts c ON f.internal_contract_id = c.contract_id
        WHERE f.contract_status = 'Actif'
        UNION ALL
        SELECT f.internal_contract_id, f.id AS fee_entry_id, SAFE_CAST(f.cotisation_structure AS INT64) AS cotisation_structure,
          #{FEE_FIELDS.map { |field| "#{dated_price(field)} AS #{field}" }.join(",\n    ")},
          IF(f.main_contract, 0, 1) AS main_sort, IFNULL(f.popularity_order, 999) AS popularity_sort,
          CASE WHEN d.id IS NOT NULL AND (d.follow_pmss_price IS NOT TRUE OR d.pmss_euros IS NOT NULL) THEN -1 ELSE 1 END AS source_sort
        FROM #{dataset}.s_internal_contract_health_mutual_fee_entries f
        JOIN est_contracts c ON f.internal_contract_id = c.contract_id
        LEFT JOIN est_fee_date_active d ON d.internal_contract_health_mutual_fee_entry_id = f.id AND c.use_fee_entry_date IS TRUE
      ),
      est_fee_entries AS (
        SELECT *
        FROM est_fee_candidates
        WHERE COALESCE(fee_price, fee_price_salarie_with_children, fee_price_salarie_with_partner, fee_price_partner,
                       fee_price_adult, fee_price_unique, fee_price_duo, fee_price_family, fee_price_child) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY internal_contract_id, fee_entry_id ORDER BY source_sort, main_sort, popularity_sort) = 1
      ),
      est_fee_agg AS (
        SELECT internal_contract_id,
          ARRAY_AGG(STRUCT(cotisation_structure, #{FEE_FIELDS.join(", ")})
            ORDER BY main_sort, GREATEST(source_sort, 0), popularity_sort LIMIT 1)[SAFE_OFFSET(0)] AS fee
        FROM est_fee_entries
        GROUP BY internal_contract_id
      )
    SQL
  end

  # ---------- Health affiliations and their family mix (arr.ts: health_*; live-pricing-sql.ts: health_mix_*) ----------

  def health_affiliation_ctes(dataset)
    active = ->(start, finish) { "#{start} <= #{TODAY} AND (#{finish} IS NULL OR #{finish} >= #{TODAY})" }
    <<~SQL.chomp
      est_health_affiliations AS (
        SELECT h.*
        FROM #{dataset}.health_mutual_affiliations h
        JOIN est_contracts c ON h.internal_contract_id = c.contract_id AND c.contract_type = '#{HEALTH}'
        WHERE h.ins_first_validated_date IS NOT NULL AND h.employee_id IS NOT NULL
          AND h.internal_contract_health_mutual_fee_entry_id IS NOT NULL
          AND #{active.call("COALESCE(h.start_date, h.affil_start_date, h.ins_first_validated_date)", "COALESCE(h.end_date, h.affil_end_date)")}
        QUALIFY ROW_NUMBER() OVER (PARTITION BY h.internal_contract_id, h.employee_id
          ORDER BY COALESCE(h.start_date, h.affil_start_date, h.ins_first_validated_date) DESC, h.id DESC) = 1
      ),
      est_health_components AS (
        SELECT h.internal_contract_id, h.internal_contract_health_mutual_fee_entry_id AS fee_entry_id, h.employee_id,
          COUNT(DISTINCT IF(i.type = 'PartnerHealthMutualInsuree', i.id, NULL)) AS partner_occurrences,
          COUNT(DISTINCT IF(i.type = 'ChildHealthMutualInsuree', i.id, NULL)) AS child_occurrences
        FROM est_health_affiliations h
        LEFT JOIN #{dataset}.health_mutual_insurees i
          ON i.health_mutual_affiliation_id = h.id AND i.first_validated_date IS NOT NULL
         AND #{active.call("COALESCE(i.start_date, DATE(i.first_validated_date))", "COALESCE(i.end_date, i.insuree_end_date)")}
        GROUP BY 1, 2, 3
      ),
      est_health_occurrences AS (
        SELECT internal_contract_id, fee_entry_id,
          COUNT(*) AS affiliation_occurrences,
          SUM(partner_occurrences) AS partner_occurrences,
          SUM(child_occurrences) AS child_occurrences,
          COUNTIF(partner_occurrences = 0 AND child_occurrences = 0) AS employee_only_occurrences,
          COUNTIF(partner_occurrences = 0 AND child_occurrences > 0) AS salarie_children_occurrences,
          COUNTIF(partner_occurrences > 0 AND child_occurrences = 0) AS duo_occurrences,
          COUNTIF(partner_occurrences > 0 AND child_occurrences > 0) AS family_occurrences
        FROM est_health_components
        GROUP BY 1, 2
      ),
      est_occurrence_priced AS (
        SELECT o.internal_contract_id, o.fee_entry_id, #{occurrence_premium("f", "o")} AS monthly_primes
        FROM est_health_occurrences o
        JOIN est_fee_entries f ON o.internal_contract_id = f.internal_contract_id AND o.fee_entry_id = f.fee_entry_id
      ),
      est_health_sample AS (
        -- Only employees on a priced grid count in the denominator: an unpriced one would dilute the premium.
        SELECT h.internal_contract_id, COUNT(DISTINCT h.employee_id) AS sample_employees
        FROM est_health_components h
        JOIN (SELECT DISTINCT internal_contract_id, fee_entry_id FROM est_occurrence_priced WHERE monthly_primes > 0) p
          ON p.internal_contract_id = h.internal_contract_id AND p.fee_entry_id = h.fee_entry_id
        GROUP BY 1
      ),
      est_occurrence_agg AS (
        SELECT p.internal_contract_id,
          SAFE_DIVIDE(SUM(p.monthly_primes), MAX(s.sample_employees)) AS occurrence_monthly_primes_per_employee,
          MAX(s.sample_employees) AS occurrence_sample_affiliates
        FROM est_occurrence_priced p
        JOIN est_health_sample s ON p.internal_contract_id = s.internal_contract_id
        WHERE p.monthly_primes > 0
        GROUP BY 1
      ),
      est_health_mix_observations AS (
        SELECT c.contract_id, c.group_id, c.group_type, c.college, c.ccn, f.cotisation_structure,
          COUNT(*) AS sample_employees,
          AVG(h.partner_occurrences) AS partner_occurrences,
          AVG(h.child_occurrences) AS child_occurrences,
          AVG(IF(h.partner_occurrences = 0 AND h.child_occurrences = 0, 1.0, 0)) AS employee_only_occurrences,
          AVG(IF(h.partner_occurrences = 0 AND h.child_occurrences > 0, 1.0, 0)) AS salarie_children_occurrences,
          AVG(IF(h.partner_occurrences > 0 AND h.child_occurrences = 0, 1.0, 0)) AS duo_occurrences,
          AVG(IF(h.partner_occurrences > 0 AND h.child_occurrences > 0, 1.0, 0)) AS family_occurrences
        FROM est_contracts c
        JOIN est_health_components h ON h.internal_contract_id = c.contract_id
        JOIN est_fee_entries f ON f.internal_contract_id = h.internal_contract_id AND f.fee_entry_id = h.fee_entry_id
        WHERE f.main_sort = 0
        GROUP BY 1, 2, 3, 4, 5, 6
      ),
      est_health_mix_candidates AS (
        SELECT c.contract_id AS target_id, m.*, level, IF(level <= 1, 'fee_group', 'fee_portfolio') AS source_detail
        FROM est_contracts c
        JOIN est_fee_agg fa ON fa.internal_contract_id = c.contract_id
        JOIN est_health_mix_observations m ON m.cotisation_structure = fa.fee.cotisation_structure AND m.contract_id != c.contract_id
        CROSS JOIN UNNEST([0, 1, 2, 3, 4]) level
        WHERE c.contract_type = '#{HEALTH}' AND CASE level
          WHEN 0 THEN m.group_id = c.group_id AND m.group_type = c.group_type AND #{college("m")} = #{college("c")}
          WHEN 1 THEN m.group_id = c.group_id AND m.group_type = c.group_type AND #{college("m")} = 'Ensemble du personnel'
          WHEN 2 THEN (m.group_id != c.group_id OR m.group_type != c.group_type)
            AND NULLIF(TRIM(m.ccn), '') = NULLIF(TRIM(c.ccn), '') AND #{college("m")} = #{college("c")}
          WHEN 3 THEN (m.group_id != c.group_id OR m.group_type != c.group_type) AND #{college("m")} = #{college("c")}
          ELSE m.group_id != c.group_id OR m.group_type != c.group_type
        END
      ),
      est_health_mix_by_group AS (
        SELECT target_id, level, source_detail, group_id, group_type,
          SUM(sample_employees) AS sample_employees, LEAST(SUM(sample_employees), 100) AS reference_weight,
          #{%w[partner child employee_only salarie_children duo family].map { |k| "SAFE_DIVIDE(SUM(#{k}_occurrences * sample_employees), SUM(sample_employees)) AS #{k}_occurrences" }.join(",\n    ")}
        FROM est_health_mix_candidates
        GROUP BY 1, 2, 3, 4, 5
      ),
      est_health_mix_reference AS (
        SELECT target_id AS contract_id, level, source_detail, COUNT(*) AS reference_groups,
          SUM(sample_employees) AS sample_employees, 1 AS affiliation_occurrences,
          #{%w[partner child employee_only salarie_children duo family].map { |k| "SAFE_DIVIDE(SUM(#{k}_occurrences * reference_weight), SUM(reference_weight)) AS #{k}_occurrences" }.join(",\n    ")}
        FROM est_health_mix_by_group g
        GROUP BY 1, 2, 3
        HAVING level <= 1 OR (COUNT(*) >= 3 AND SUM(g.sample_employees) >= 30)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY level) = 1
      ),
      est_health_pricing AS (
        SELECT c.contract_id, foa.occurrence_sample_affiliates, foa.occurrence_monthly_primes_per_employee,
          m.source_detail AS mix_source_detail, m.level AS mix_level, m.sample_employees AS mix_sample_employees,
          m.reference_groups AS mix_reference_groups,
          #{occurrence_premium("fa.fee", "m")} AS mix_monthly_primes_per_employee
        FROM est_contracts c
        LEFT JOIN est_occurrence_agg foa ON foa.internal_contract_id = c.contract_id
        LEFT JOIN est_fee_agg fa ON fa.internal_contract_id = c.contract_id
        LEFT JOIN est_health_mix_reference m ON m.contract_id = c.contract_id
      )
    SQL
  end

  # ---------- Provident: own DSN contributions, then payroll mass × rates (provident-live-reference-sql.ts, arr.ts) ----------

  def provident_ctes(dataset)
    <<~SQL.chomp
      est_provident_window AS (
        -- Three settled months ending at M-2: the latest declaration month is still incomplete early in the month.
        SELECT DATE_SUB(DATE_TRUNC(#{TODAY}, MONTH), INTERVAL 4 MONTH) AS first_month,
               DATE_SUB(DATE_TRUNC(#{TODAY}, MONTH), INTERVAL 1 MONTH) AS exclusive_end
      ),
      est_provident_contributions_latest AS (
        SELECT d.id, c.contract_id, d.declaration_month, d.start_date, d.end_date, d.validated,
          REGEXP_REPLACE(UPPER(TRIM(d.social_security_number)), r'[^0-9AB]', '') AS person_key,
          SAFE_CAST(d.amountcotisation_cents AS FLOAT64) / 100.0 AS contribution
        FROM #{dataset}.s_cotisation_individu_urssafs d
        JOIN est_contracts c
          ON c.contract_id = COALESCE(d.internal_contract_id, SAFE_CAST(REGEXP_EXTRACT(d.affiliation_option, r'_(\\d+)$') AS INT64))
         AND c.contract_type = '#{PROVIDENT}'
        QUALIFY ROW_NUMBER() OVER (PARTITION BY d.id ORDER BY d.updated_at DESC) = 1
      ),
      est_provident_months AS (
        SELECT d.contract_id, d.declaration_month,
          COUNT(DISTINCT SUBSTR(d.person_key, 1, 13)) AS sample_employees, SUM(d.contribution) AS monthly_premium
        FROM est_provident_contributions_latest d
        CROSS JOIN est_provident_window w
        WHERE d.validated = true AND d.declaration_month >= w.first_month AND d.declaration_month < w.exclusive_end
          AND DATE_TRUNC(d.start_date, MONTH) = d.declaration_month AND DATE_TRUNC(d.end_date, MONTH) = d.declaration_month
          AND d.end_date >= d.start_date AND LENGTH(d.person_key) IN (13, 15) AND d.contribution IS NOT NULL
        GROUP BY 1, 2
        HAVING sample_employees >= 3 AND monthly_premium > 0
      ),
      est_provident_observations AS (
        SELECT contract_id, MAX(sample_employees) AS sample_employees,
          SAFE_DIVIDE(SUM(monthly_premium) * 12.0, SUM(sample_employees)) AS annual_premium,
          COUNT(*) AS observed_months, MIN(declaration_month) AS observation_start, LAST_DAY(MAX(declaration_month)) AS observation_end,
          SAFE_DIVIDE(MAX(SAFE_DIVIDE(monthly_premium, sample_employees)), MIN(SAFE_DIVIDE(monthly_premium, sample_employees))) AS monthly_price_ratio
        FROM est_provident_months
        GROUP BY 1
        HAVING COUNT(*) >= 2
      ),
      est_provident_medians AS (
        SELECT DISTINCT contract_id,
          PERCENTILE_CONT(SAFE_DIVIDE(monthly_premium * 12, sample_employees), 0.5) OVER (PARTITION BY contract_id) AS median_price,
          MIN(SAFE_DIVIDE(monthly_premium * 12, sample_employees)) OVER (PARTITION BY contract_id) AS min_price,
          MAX(SAFE_DIVIDE(monthly_premium * 12, sample_employees)) OVER (PARTITION BY contract_id) AS max_price
        FROM est_provident_months
      ),
      est_provident_own AS (
        -- The last two settled months are required; a volatile month falls back to the median of three.
        SELECT DISTINCT o.contract_id, o.sample_employees, o.observed_months, o.observation_start, o.observation_end,
          o.monthly_price_ratio, o.monthly_price_ratio > 1.5 AS uses_median,
          IF(o.monthly_price_ratio > 1.5, p.median_price, o.annual_premium) AS annual_premium
        FROM est_provident_observations o
        JOIN est_provident_medians p USING (contract_id)
        JOIN est_provident_months m ON m.contract_id = o.contract_id
        CROSS JOIN est_provident_window w
        WHERE (o.monthly_price_ratio <= 1.5 OR (o.observed_months = 3
            AND LEAST(SAFE_DIVIDE(p.median_price, p.min_price), SAFE_DIVIDE(p.max_price, p.median_price)) <= 1.5))
          AND o.observation_end = DATE_SUB(w.exclusive_end, INTERVAL 1 DAY)
          AND m.declaration_month = DATE_SUB(w.exclusive_end, INTERVAL 2 MONTH)
      ),
      est_provident_mass AS (
        SELECT source_contract_id, group_id, group_type, college_key, dsn_population_count,
          SAFE_DIVIDE(mass_ta, dsn_population_count) AS mass_ta_per_employee,
          SAFE_DIVIDE(mass_tb, dsn_population_count) AS mass_tb_per_employee,
          SAFE_DIVIDE(mass_tc, dsn_population_count) AS mass_tc_per_employee,
          -- A payroll band with a mass needs its rate: a missing rate is not a zero rate.
          IF((mass_ta = 0 OR ta_rate >= 0) AND (mass_tb = 0 OR tb_rate >= 0) AND (mass_tc = 0 OR tc_rate >= 0),
            SAFE_DIVIDE((mass_ta * IFNULL(ta_rate, 0) + mass_tb * IFNULL(tb_rate, 0) + mass_tc * IFNULL(tc_rate, 0)) / 100.0,
              dsn_population_count),
            NULL) AS annual_primes_per_employee
        FROM (
          SELECT c.contract_id AS source_contract_id, c.group_id, c.group_type, #{college("c")} AS college_key,
            SAFE_CAST(c.ta_rate AS FLOAT64) AS ta_rate, SAFE_CAST(c.tb_rate AS FLOAT64) AS tb_rate, SAFE_CAST(c.tc_rate AS FLOAT64) AS tc_rate,
            #{mass_by_college("ta")} AS mass_ta, #{mass_by_college("tb")} AS mass_tb, #{mass_by_college("tc")} AS mass_tc,
            CASE TRIM(c.college)
              -- Never divide a college's mass by the whole headcount.
              WHEN 'Cadres' THEN COALESCE(NULLIF(up.cadres_count, 0), NULLIF(up.employees_cadres_count, 0), 0)
              WHEN 'Non Cadres' THEN COALESCE(NULLIF(up.non_cadres_count, 0), NULLIF(up.employees_non_cadres_count, 0), 0)
              ELSE COALESCE(NULLIF(up.employees_count, 0), NULLIF(IFNULL(up.cadres_count, 0) + IFNULL(up.non_cadres_count, 0), 0),
                NULLIF(up.employees_employees_count, 0), 0)
            END AS dsn_population_count
          FROM est_contracts c
          LEFT JOIN #{dataset}.user_pros up ON up.id = c.user_pro_id
          WHERE c.contract_type = '#{PROVIDENT}'
        )
        WHERE (mass_ta + mass_tb + mass_tc) > 0 AND mass_ta >= 0 AND mass_tb >= 0 AND mass_tc >= 0 AND dsn_population_count > 0
      ),
      est_provident_mass_basis AS (
        SELECT contract_id,
          ARRAY_AGG(STRUCT(source_contract_id, annual_primes_per_employee, dsn_population_count, uses_target_rates, same_college)
            ORDER BY IF(source_contract_id = contract_id, 0, 1), IF(same_college, 0, 1), dsn_population_count DESC, source_contract_id
            LIMIT 1)[SAFE_OFFSET(0)] AS basis
        FROM (
          SELECT *, IF(uses_target_rates, target_annual_primes_per_employee, source_annual_primes_per_employee) AS annual_primes_per_employee
          FROM (
            SELECT c.contract_id, m.source_contract_id, m.dsn_population_count, m.college_key = #{college("c")} AS same_college,
              m.annual_primes_per_employee AS source_annual_primes_per_employee,
              (m.mass_ta_per_employee * IFNULL(SAFE_CAST(c.ta_rate AS FLOAT64), 0)
                + m.mass_tb_per_employee * IFNULL(SAFE_CAST(c.tb_rate AS FLOAT64), 0)
                + m.mass_tc_per_employee * IFNULL(SAFE_CAST(c.tc_rate AS FLOAT64), 0)) / 100.0 AS target_annual_primes_per_employee,
              IFNULL((m.mass_ta_per_employee = 0 OR SAFE_CAST(c.ta_rate AS FLOAT64) >= 0)
                AND (m.mass_tb_per_employee = 0 OR SAFE_CAST(c.tb_rate AS FLOAT64) >= 0)
                AND (m.mass_tc_per_employee = 0 OR SAFE_CAST(c.tc_rate AS FLOAT64) >= 0), false) AS uses_target_rates
            FROM est_contracts c
            JOIN est_provident_mass m
              ON m.group_id = c.group_id AND m.group_type = c.group_type AND c.contract_type = '#{PROVIDENT}'
             AND (m.college_key = #{college("c")} OR m.college_key = 'Ensemble du personnel')
          )
        )
        WHERE annual_primes_per_employee > 0
        GROUP BY contract_id
      )
    SQL
  end

  # ---------- Portfolio benchmark: median of other groups' observed premiums (live-pricing-sql.ts) ----------

  def reference_ctes
    <<~SQL.chomp
      est_live_observations AS (
        SELECT c.*, foa.occurrence_sample_affiliates AS sample_employees, foa.occurrence_monthly_primes_per_employee * 12 AS annual_premium
        FROM est_contracts c
        JOIN est_occurrence_agg foa ON foa.internal_contract_id = c.contract_id
        WHERE foa.occurrence_sample_affiliates >= 3 AND foa.occurrence_monthly_primes_per_employee > 0
        UNION ALL
        SELECT c.*, d.sample_employees, d.annual_premium
        FROM est_contracts c
        JOIN est_provident_observations d ON d.contract_id = c.contract_id
        WHERE d.sample_employees >= 3 AND d.annual_premium > 0
      ),
      est_benchmark_groups AS (
        SELECT c.contract_id, level, o.group_id, o.group_type, SUM(o.sample_employees) AS sample_employees,
          SAFE_DIVIDE(SUM(o.annual_premium * o.sample_employees), SUM(o.sample_employees)) AS annual_premium
        FROM est_contracts c
        JOIN est_live_observations o
          ON o.contract_type = c.contract_type AND (o.group_id != c.group_id OR o.group_type != c.group_type)
        CROSS JOIN UNNEST([0, 1, 2]) level
        WHERE CASE level
          WHEN 0 THEN NULLIF(TRIM(o.ccn), '') = NULLIF(TRIM(c.ccn), '') AND #{college("o")} = #{college("c")}
          WHEN 1 THEN #{college("o")} = #{college("c")}
          ELSE true
        END
        GROUP BY 1, 2, 3, 4
      ),
      est_benchmark AS (
        SELECT contract_id, level, reference_groups, sample_employees,
          IF(MOD(ARRAY_LENGTH(premiums), 2) = 0,
            premiums[SAFE_OFFSET(DIV(ARRAY_LENGTH(premiums), 2) - 1)] * 0.5 + premiums[SAFE_OFFSET(DIV(ARRAY_LENGTH(premiums), 2))] * 0.5,
            premiums[SAFE_OFFSET(DIV(ARRAY_LENGTH(premiums), 2))]) AS annual_premium
        FROM (
          SELECT contract_id, level, ARRAY_AGG(annual_premium IGNORE NULLS ORDER BY annual_premium) AS premiums,
            COUNT(*) AS reference_groups, SUM(g.sample_employees) AS sample_employees
          FROM est_benchmark_groups g
          GROUP BY 1, 2
          HAVING COUNT(*) >= 3 AND SUM(g.sample_employees) >= 30
        )
        QUALIFY ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY level) = 1
      )
    SQL
  end

  # ---------- Price choice and the engine's row (arr.ts: collective_pricing_choices, final SELECT) ----------

  def estimate_ctes
    health_flat = "COALESCE(#{(FEE_FIELDS - %w[fee_price fee_price_unique]).map { |f| "fa.fee.#{f}" }.join(", ")}) IS NULL"
    <<~SQL.chomp
      est_pricing AS (
        -- Annual premium per affiliate, its method, sample, reference, reference groups and SQL confidence.
        SELECT c.*,
          CASE
            WHEN c.contract_type = '#{PROVIDENT}' AND po.annual_premium > 0 THEN STRUCT(po.annual_premium AS annual_premium,
              'dsn_recent' AS source_detail, po.sample_employees AS sample_size,
              CONCAT('DSN propres · ', CAST(po.observation_start AS STRING), ' au ', CAST(po.observation_end AS STRING), ' · ',
                CAST(po.observed_months AS STRING), ' mois · variation du prix mensuel ', CAST(ROUND((po.monthly_price_ratio - 1) * 100) AS STRING), ' %',
                IF(po.uses_median, ' · médiane, confiance limitée', ' · moyenne pondérée')) AS reference,
              1 AS reference_groups, IF(po.uses_median, 'low', 'medium') AS confidence)
            WHEN c.contract_type = '#{PROVIDENT}' AND pm.basis.annual_primes_per_employee > 0 THEN STRUCT(pm.basis.annual_primes_per_employee,
              'dsn_group', pm.basis.dsn_population_count,
              IF(pm.basis.source_contract_id = c.contract_id, 'DSN contrat',
                IF(pm.basis.uses_target_rates, 'DSN groupe · taux du contrat', 'DSN groupe · taux source')),
              1, CASE WHEN NOT pm.basis.uses_target_rates OR NOT pm.basis.same_college THEN 'low'
                WHEN pm.basis.dsn_population_count >= 5 THEN 'medium' ELSE 'low' END)
            WHEN c.contract_type = '#{HEALTH}' AND hp.occurrence_monthly_primes_per_employee > 0 THEN STRUCT(hp.occurrence_monthly_primes_per_employee * 12,
              'fee_occurrence', hp.occurrence_sample_affiliates, 'Affiliations du contrat', 1,
              CASE WHEN hp.occurrence_sample_affiliates >= 10 THEN 'high' WHEN hp.occurrence_sample_affiliates >= 3 THEN 'medium' ELSE 'low' END)
            WHEN c.contract_type = '#{HEALTH}' AND fa.fee.fee_price_unique > 0 THEN STRUCT(fa.fee.fee_price_unique * 12,
              'fee', 0, 'Tarif unique du contrat', 0, 'medium')
            WHEN c.contract_type = '#{HEALTH}' AND hp.mix_monthly_primes_per_employee > 0 THEN STRUCT(hp.mix_monthly_primes_per_employee * 12,
              hp.mix_source_detail, hp.mix_sample_employees,
              CASE WHEN hp.mix_level <= 1 THEN 'Mix groupe' WHEN hp.mix_level = 2 THEN 'Mix CCN + collège'
                WHEN hp.mix_level = 3 THEN 'Mix collège' ELSE 'Mix portefeuille' END,
              hp.mix_reference_groups, IF(hp.mix_source_detail = 'fee_group' AND hp.mix_sample_employees >= 10, 'medium', 'low'))
            -- fee_price alone is the employee-only tier when dependants have prices: only a flat tariff is used as is.
            WHEN c.contract_type = '#{HEALTH}' AND fa.fee.fee_price > 0 AND #{health_flat} THEN STRUCT(fa.fee.fee_price * 12,
              'fee', 0, 'Tarif simple du contrat', 0, 'medium')
            WHEN lb.annual_premium > 0 THEN STRUCT(lb.annual_premium,
              IF(c.contract_type = '#{HEALTH}', 'benchmark_mut', 'benchmark_prev'), lb.sample_employees,
              CASE lb.level WHEN 0 THEN 'CCN + collège' WHEN 1 THEN 'Collège' ELSE 'Portefeuille' END, lb.reference_groups, 'low')
            ELSE STRUCT(CAST(NULL AS FLOAT64), 'none', 0, 'Aucune référence exploitable', 0, 'very_low')
          END AS pricing
        FROM est_contracts c
        LEFT JOIN est_fee_agg fa ON fa.internal_contract_id = c.contract_id
        LEFT JOIN est_health_pricing hp ON hp.contract_id = c.contract_id
        LEFT JOIN est_provident_own po ON po.contract_id = c.contract_id
        LEFT JOIN est_provident_mass_basis pm ON pm.contract_id = c.contract_id
        LEFT JOIN est_benchmark lb ON lb.contract_id = c.contract_id
      ),
      contract_arr_engine AS (
        -- Without any estimate, a contract with invoices is invoiced; AnalyticsArr then makes the final choice.
        SELECT p.contract_id, p.contract_type, CAST(p.contract_start_date AS STRING) AS start_date,
          p.visible_employees, p.effective_salaries, p.group_risk_visibles, p.group_risk_signed,
          IF(p.pricing.source_detail != 'none', p.total_commission_rate, IFNULL(ia.total_commission_rate, p.total_commission_rate)) AS total_commission_rate,
          IF(p.pricing.source_detail = 'none' AND ia.months_invoiced > 0, 'invoice', p.pricing.source_detail) AS source_detail,
          IF(p.pricing.source_detail = 'none' AND ia.months_invoiced > 0, 'high', p.pricing.confidence) AS calculation_confidence,
          IF(p.pricing.source_detail = 'none' AND ia.months_invoiced > 0, 'Factures du contrat', p.pricing.reference) AS pricing_reference,
          IFNULL(p.pricing.sample_size, 0) AS pricing_sample_size,
          IF(p.pricing.source_detail = 'none' AND ia.months_invoiced > 0, 0, IFNULL(p.pricing.reference_groups, 0)) AS pricing_reference_groups,
          p.pricing.annual_premium / 12 AS monthly_premium_per_employee,
          IFNULL(ia.months_invoiced, 0) AS months_invoiced, IFNULL(ia.invoice_affiliates, 0) AS invoice_affiliates,
          ia.factured_primes_annualisees,
          ia.factured_primes_annualisees * IFNULL(ia.total_commission_rate, p.total_commission_rate) AS factured_arr,
          ia.invoice_reference, CAST(ia.invoice_period AS STRING) AS invoice_period,
          ia.internal_contract_id IS NOT NULL AS has_readiness, ia.billed_population_usable, ia.readiness_eligible,
          ia.readiness_reason, ia.billed_people, ia.full_people, ia.partial_people, ia.annual_price, ia.maturity_basis,
          CAST(#{TODAY} AS STRING) AS observed_on, pc.recorded_people, pc.unresolved_people,
          pc.census_affiliated, pc.census_exempt, pc.census_complete,
          pc.census_mature AS confirmed_mature, pc.confirmed_affiliated, pc.confirmed_exempt
        FROM est_pricing p
        LEFT JOIN est_invoice_agg ia ON ia.internal_contract_id = p.contract_id
        LEFT JOIN est_census pc ON pc.contract_id = p.contract_id
      )
    SQL
  end

  # ---------- SQL helpers ----------

  # A dated grid indexed on the PMSS stores percentages; a fixed one stores euros (health-dated-pricing-sql.ts).
  def dated_price(field)
    "CAST(CASE WHEN IFNULL(d.follow_pmss_price, false) " \
      "THEN ROUND(SAFE_CAST(NULLIF(d.#{field}, 0) AS NUMERIC) * d.pmss_euros / 100, 2) " \
      "ELSE COALESCE(NULLIF(SAFE_CAST(d.#{field} AS NUMERIC), 0), NULLIF(SAFE_CAST(f.#{field} AS NUMERIC), 0)) END AS FLOAT64)"
  end

  def college(table)
    "COALESCE(NULLIF(TRIM(#{table}.college), ''), 'Ensemble du personnel')"
  end

  def mass_by_college(band)
    "CASE TRIM(c.college) WHEN 'Cadres' THEN IFNULL(up.cadres_#{band}, 0) WHEN 'Non Cadres' THEN IFNULL(up.non_cadres_#{band}, 0) " \
      "ELSE IFNULL(up.total_#{band}, 0) END"
  end

  # Monthly premium of a grid for a set of affiliation occurrences, per cotisation structure (health-pricing-sql.ts).
  # Mix fields are counts for a contract's own affiliations, proportions for a reference employee.
  def occurrence_premium(fee, mix)
    f = ->(*fields) { "COALESCE(#{fields.map { |x| x.to_s.include?("+") ? x : "#{fee}.#{x}" }.join(", ")}, 0)" }
    sum = ->(x, y) { "#{fee}.#{x} + #{fee}.#{y}" }
    <<~SQL.chomp
      CASE
        WHEN #{fee}.fee_price_unique IS NOT NULL THEN #{fee}.fee_price_unique * #{mix}.affiliation_occurrences
        WHEN #{fee}.cotisation_structure = 1 THEN #{f.call(:fee_price, :fee_price_adult)} * #{mix}.affiliation_occurrences
          + #{f.call(:fee_price_partner, :fee_price_adult)} * #{mix}.partner_occurrences + #{f.call(:fee_price_child)} * #{mix}.child_occurrences
        WHEN #{fee}.cotisation_structure = 2 THEN #{f.call(:fee_price_adult, :fee_price)} * (#{mix}.affiliation_occurrences + #{mix}.partner_occurrences)
          + #{f.call(:fee_price_child)} * #{mix}.child_occurrences
        WHEN #{fee}.cotisation_structure = 3 THEN #{f.call(:fee_price)} * #{mix}.employee_only_occurrences
          + #{f.call(:fee_price_duo_child, :fee_price_duo_family, :fee_price_family, :fee_price_duo, :fee_price)} * #{mix}.salarie_children_occurrences
          + #{f.call(:fee_price_duo, :fee_price_salarie_with_partner, :fee_price_family, :fee_price)} * #{mix}.duo_occurrences
          + #{f.call(:fee_price_duo_family, :fee_price_family, :fee_price_duo, :fee_price)} * #{mix}.family_occurrences
        WHEN #{fee}.cotisation_structure = 4 THEN #{f.call(:fee_price)} * #{mix}.employee_only_occurrences
          + #{f.call(:fee_price_family, :fee_price_duo_family, :fee_price)} * (#{mix}.salarie_children_occurrences + #{mix}.duo_occurrences + #{mix}.family_occurrences)
        WHEN #{fee}.cotisation_structure = 6 THEN #{f.call(:fee_price_salarie_with_children, :fee_price, :fee_price_adult)} * #{mix}.affiliation_occurrences
          + #{f.call(:fee_price_partner, :fee_price_salarie_with_partner)} * #{mix}.partner_occurrences
        WHEN #{fee}.cotisation_structure = 8 THEN #{f.call(:fee_price)} * #{mix}.employee_only_occurrences
          + #{f.call(:fee_price_salarie_with_children, :fee_price_family, :fee_price)} * (#{mix}.salarie_children_occurrences + #{mix}.duo_occurrences + #{mix}.family_occurrences)
        WHEN #{fee}.cotisation_structure = 9 THEN #{f.call(:fee_price)} * #{mix}.employee_only_occurrences
          + #{f.call(:fee_price_salarie_with_children, :fee_price)} * #{mix}.salarie_children_occurrences
          + #{f.call(:fee_price_salarie_with_partner, :fee_price_duo, sum.call(:fee_price, :fee_price_partner), :fee_price_partner, :fee_price)} * #{mix}.duo_occurrences
          + #{f.call(:fee_price_family, :fee_price_duo_family, sum.call(:fee_price_salarie_with_children, :fee_price_partner), :fee_price_salarie_with_children, :fee_price)} * #{mix}.family_occurrences
        WHEN #{fee}.cotisation_structure = 10 THEN #{f.call(:fee_price)} * #{mix}.employee_only_occurrences
          + #{f.call(:fee_price_salarie_with_children, :fee_price)} * #{mix}.salarie_children_occurrences
          + #{f.call(:fee_price_family, :fee_price_duo, :fee_price)} * #{mix}.duo_occurrences
          + #{f.call(:fee_price_family, :fee_price_duo_family, :fee_price_salarie_with_children, :fee_price)} * #{mix}.family_occurrences
        ELSE #{f.call(:fee_price, :fee_price_adult, :fee_price_salarie_with_children)} * #{mix}.employee_only_occurrences
          + #{f.call(:fee_price_salarie_with_children, :fee_price_duo_child, :fee_price_family, :fee_price_duo_family, :fee_price, :fee_price_adult)} * #{mix}.salarie_children_occurrences
          + #{f.call(:fee_price_salarie_with_partner, :fee_price_duo, :fee_price_family, :fee_price_duo_family, :fee_price_partner, :fee_price)} * #{mix}.duo_occurrences
          + #{f.call(:fee_price_family, :fee_price_duo_family, :fee_price_salarie_with_children, :fee_price_duo, :fee_price)} * #{mix}.family_occurrences
      END
    SQL
  end
end
