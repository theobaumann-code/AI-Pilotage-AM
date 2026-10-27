# Core of the ARR estimation engine of SideCare Analytics (lounna-team/ai-sidecare-analytics), ported to the BI
# portfolio sync: the estimated annual ARR of every active collective contract, independent of its invoices.
#
#   estimated ARR = expected affiliates × annual premium per affiliate × total commission rate
#
# Ported from, in Analytics: src/lib/bq/arr.ts (getContractARR: commission, target population, pricing hierarchy),
# src/lib/bq/health-pricing-sql.ts and health-dated-pricing-sql.ts (health grids, PMSS-indexed tariffs),
# src/lib/bq/live-pricing-sql.ts (health family mix and portfolio benchmarks), src/lib/bq/provident-live-reference-sql.ts
# (provident DSN contributions), src/lib/bq/population-conversion-sql.ts and src/lib/arr-population-conversion.ts
# (business-validated conversion of visible / signed employees into affiliates).
#
# Left out of this core copy: the invoice-based projection ("invoice_projection" - here the invoice is the other
# side of the comparison), confirmed / billed population floors, live learned affiliation rates, deflation of closed
# years, TNS and manual inputs. Figures are therefore very close to Analytics' estimate, not guaranteed identical.
module BiArrEstimateSql
  HEALTH = "CompanyHealthMutualInternalContract".freeze
  PROVIDENT = "CompanyProvidentInsuranceInternalContract".freeze

  # Plafond mensuel de la sécurité sociale (Urssaf, cas général), for health grids indexed on it. Analytics reads the
  # dated schedule from the Urssaf API; add each new year here in January.
  PMSS_MONTHLY = { 2024 => 3864, 2025 => 3925, 2026 => 4005 }.freeze

  # Business-validated population conversion (Analytics, 2026-09-07): share of signed employees who end up affiliated,
  # and share of signed employees who become visible in the BO. Visible employees convert at signed / registration.
  CONVERSION = {
    HEALTH => { registration_rate: 0.9885, signed_affiliation_rate: 0.80 },
    PROVIDENT => { registration_rate: 0.973, signed_affiliation_rate: 0.95 }
  }.freeze
  # Before coverage starts, visibles below this share of the signed employees are preparation records: use signed.
  FUTURE_VISIBLE_SHARE_FLOOR = 0.66

  FEE_FIELDS = %w[fee_price fee_price_adult fee_price_family fee_price_child fee_price_partner fee_price_duo
                  fee_price_unique fee_price_duo_family fee_price_duo_child fee_price_salarie_with_children
                  fee_price_salarie_with_partner].freeze

  TODAY = "CURRENT_DATE('Europe/Paris')".freeze

  module_function

  # CTEs to insert in a WITH clause; they need `company_sets` (id, name) defined before them. The last one,
  # contract_arr_estimates, has one row per active collective contract: contract_id, estimated_arr, source_detail,
  # expected_affiliates, annual_premium_per_affiliate, total_commission_rate.
  def ctes(dataset)
    [ contracts_ctes(dataset), health_fee_ctes(dataset), health_affiliation_ctes(dataset), provident_ctes(dataset),
      reference_ctes, estimate_ctes ].join(",\n")
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
          ic.start_date AS contract_start_date, up.ccn, ic.ta_rate, ic.tb_rate, ic.tc_rate,
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
      est_contracts AS (
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
          COUNT(*) AS observed_months, LAST_DAY(MAX(declaration_month)) AS observation_end,
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
        SELECT DISTINCT o.contract_id, o.sample_employees,
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
          ARRAY_AGG(STRUCT(source_contract_id, annual_primes_per_employee, dsn_population_count)
            ORDER BY IF(source_contract_id = contract_id, 0, 1), IF(same_college, 0, 1), dsn_population_count DESC, source_contract_id
            LIMIT 1)[SAFE_OFFSET(0)] AS basis
        FROM (
          SELECT c.contract_id, m.source_contract_id, m.dsn_population_count, m.college_key = #{college("c")} AS same_college,
            IF(IFNULL((m.mass_ta_per_employee = 0 OR SAFE_CAST(c.ta_rate AS FLOAT64) >= 0)
                AND (m.mass_tb_per_employee = 0 OR SAFE_CAST(c.tb_rate AS FLOAT64) >= 0)
                AND (m.mass_tc_per_employee = 0 OR SAFE_CAST(c.tc_rate AS FLOAT64) >= 0), false),
              (m.mass_ta_per_employee * IFNULL(SAFE_CAST(c.ta_rate AS FLOAT64), 0)
                + m.mass_tb_per_employee * IFNULL(SAFE_CAST(c.tb_rate AS FLOAT64), 0)
                + m.mass_tc_per_employee * IFNULL(SAFE_CAST(c.tc_rate AS FLOAT64), 0)) / 100.0,
              m.annual_primes_per_employee) AS annual_primes_per_employee
          FROM est_contracts c
          JOIN est_provident_mass m
            ON m.group_id = c.group_id AND m.group_type = c.group_type AND c.contract_type = '#{PROVIDENT}'
           AND (m.college_key = #{college("c")} OR m.college_key = 'Ensemble du personnel')
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
        SELECT contract_id, level,
          IF(MOD(ARRAY_LENGTH(premiums), 2) = 0,
            premiums[SAFE_OFFSET(DIV(ARRAY_LENGTH(premiums), 2) - 1)] * 0.5 + premiums[SAFE_OFFSET(DIV(ARRAY_LENGTH(premiums), 2))] * 0.5,
            premiums[SAFE_OFFSET(DIV(ARRAY_LENGTH(premiums), 2))]) AS annual_premium
        FROM (
          SELECT contract_id, level, ARRAY_AGG(annual_premium IGNORE NULLS ORDER BY annual_premium) AS premiums
          FROM est_benchmark_groups g
          GROUP BY 1, 2
          HAVING COUNT(*) >= 3 AND SUM(g.sample_employees) >= 30
        )
        QUALIFY ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY level) = 1
      )
    SQL
  end

  # ---------- Price choice, expected affiliates, ARR (arr.ts: collective_pricing_choices; arr-population-conversion.ts) ----------

  def estimate_ctes
    health_flat = "COALESCE(#{(FEE_FIELDS - %w[fee_price fee_price_unique]).map { |f| "fa.fee.#{f}" }.join(", ")}) IS NULL"
    <<~SQL.chomp
      est_pricing AS (
        SELECT c.*,
          CASE
            WHEN c.contract_type = '#{PROVIDENT}' AND po.annual_premium > 0 THEN STRUCT(po.annual_premium AS annual_premium, 'dsn_recent' AS source_detail)
            WHEN c.contract_type = '#{PROVIDENT}' AND pm.basis.annual_primes_per_employee > 0 THEN STRUCT(pm.basis.annual_primes_per_employee, 'dsn_group')
            WHEN c.contract_type = '#{HEALTH}' AND hp.occurrence_monthly_primes_per_employee > 0 THEN STRUCT(hp.occurrence_monthly_primes_per_employee * 12, 'fee_occurrence')
            WHEN c.contract_type = '#{HEALTH}' AND fa.fee.fee_price_unique > 0 THEN STRUCT(fa.fee.fee_price_unique * 12, 'fee')
            WHEN c.contract_type = '#{HEALTH}' AND hp.mix_monthly_primes_per_employee > 0 THEN STRUCT(hp.mix_monthly_primes_per_employee * 12, hp.mix_source_detail)
            -- fee_price alone is the employee-only tier when dependants have prices: only a flat tariff is used as is.
            WHEN c.contract_type = '#{HEALTH}' AND fa.fee.fee_price > 0 AND #{health_flat} THEN STRUCT(fa.fee.fee_price * 12, 'fee')
            WHEN lb.annual_premium > 0 THEN STRUCT(lb.annual_premium, IF(c.contract_type = '#{HEALTH}', 'benchmark_mut', 'benchmark_prev'))
            ELSE STRUCT(CAST(NULL AS FLOAT64), 'none')
          END AS pricing
        FROM est_contracts c
        LEFT JOIN est_fee_agg fa ON fa.internal_contract_id = c.contract_id
        LEFT JOIN est_health_pricing hp ON hp.contract_id = c.contract_id
        LEFT JOIN est_provident_own po ON po.contract_id = c.contract_id
        LEFT JOIN est_provident_mass_basis pm ON pm.contract_id = c.contract_id
        LEFT JOIN est_benchmark lb ON lb.contract_id = c.contract_id
      ),
      contract_arr_estimates AS (
        SELECT contract_id, pricing.source_detail, pricing.annual_premium AS annual_premium_per_affiliate, total_commission_rate,
          expected_affiliates, expected_affiliates * pricing.annual_premium * total_commission_rate AS estimated_arr
        FROM (
          SELECT p.*,
            -- Visible employees convert at the affiliation rate of visibles; without visibles (or with only
            -- preparation records before coverage starts), signed employees convert at the signed rate.
            IF(p.visible_employees > 0
                 AND NOT (p.contract_start_date > #{TODAY} AND p.visible_employees < #{FUTURE_VISIBLE_SHARE_FLOOR} * p.effective_salaries),
               p.visible_employees * #{affiliation_rate_sql("p.contract_type", :visible)},
               p.effective_salaries * #{affiliation_rate_sql("p.contract_type", :signed)}) AS expected_affiliates
          FROM est_pricing p
        )
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

  def affiliation_rate_sql(type_column, basis)
    rates = CONVERSION.transform_values do |c|
      basis == :signed ? c[:signed_affiliation_rate] : c[:signed_affiliation_rate] / c[:registration_rate]
    end
    "CASE #{type_column} WHEN '#{HEALTH}' THEN #{rates[HEALTH]} WHEN '#{PROVIDENT}' THEN #{rates[PROVIDENT]} ELSE 0 END"
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
