# Ruby half of the ARR engine of SideCare Analytics (lounna-team/ai-sidecare-analytics), applied to the rows of
# BiArrEstimateSql: per contract, the choice between the invoiced ARR and the estimate, and the expected affiliates
# behind an estimate; per account, how its ARR was obtained - "Facturé", "Estimé" or "Mixte", with the methods and the
# price reliability, worded as in Analytics.
#
# Ported from, in Analytics: src/lib/arr-population-conversion.ts (populationProjection, currentPopulationProjection,
# applyPopulationConversion, arrPriceConfidence, describePopulationProjection), arr-invoice-rules.ts
# (historicalInvoiceArrBasis), arr-estimation-audit.ts (confidenceFromAmounts), deal-arr-aggregation.ts (a deal's
# sources, methods and references) and arr-source-label.ts (sourceLabel, arrSourceSummary).
module AnalyticsArr
  HEALTH = BiArrEstimateSql::HEALTH
  PROVIDENT = BiArrEstimateSql::PROVIDENT

  # Business-validated population conversion (Analytics' population-conversion-sql.ts, rates given by Benoît on
  # 2026-09-07): share of signed employees who become visible in the BO, and share who end up affiliated.
  CONVERSION = {
    HEALTH => { registration_rate: 0.9885, signed_affiliation_rate: 0.80, observed_on: "2026-09-07" },
    PROVIDENT => { registration_rate: 0.973, signed_affiliation_rate: 0.95, observed_on: "2026-09-07" }
  }.freeze
  # Before coverage starts, visibles below this share of the signed employees are preparation records: use signed.
  FUTURE_VISIBLE_SHARE_FLOOR = 0.66

  CONFIDENCE_ORDER = %w[very_low low medium high very_high].freeze
  CONFIDENCE_LABELS = { "very_high" => "Très élevée", "high" => "Élevée", "medium" => "Moyenne", "low" => "Faible",
                        "very_low" => "Aucun prix" }.freeze

  # The methods, as Analytics names and explains them (arr-source-label.ts: METHODS).
  METHODS = {
    "dsn_recent" => [ "DSN du contrat", "Prévoyance : cotisations validées du contrat, au moins trois personnes par mois et les deux derniers mois consolidés disponibles. Moyenne pondérée par les personnes-mois ; au-delà de 50 % de variation, médiane de trois mois seulement si deux prix sont cohérents, avec confiance limitée. Crédits courants inclus, régularisations anciennes exclues." ],
    "invoice_projection" => [ "premières factures projetées", "Prix moyen facturé mesuré uniquement sur les salariés dont toutes les lignes couvrent une période entière, puis projeté sur les affiliés attendus. Le montant facturé observé reste distinct du rythme de croisière estimé." ],
    "dsn_group" => [ "DSN du groupe", "Prévoyance : masses salariales moyennes par tranche issues de la DSN exploitable du groupe, revalorisées aux taux du contrat cible lorsqu’ils sont exploitables et projetées sur les affiliés estimés après conversion des salariés visibles ou signés." ],
    "fee_occurrence" => [ "affiliations du contrat", "Santé : mix familial des affiliations observées, selon la structure de cotisation, appliqué aux tarifs propres du contrat et à ses options pondérées." ],
    "fee_group" => [ "tarifs × mix du groupe", "Santé : mix familial observé dans le même groupe, collège et structure de cotisation, revalorisé aux tarifs du contrat cible." ],
    "fee_portfolio" => [ "tarifs × mix comparable", "Santé : mix familial observé sur le portefeuille de structure compatible, collège privilégié, revalorisé aux tarifs du contrat cible." ],
    "fee" => [ "tarifs du contrat", "Santé : tarifs du contrat appliqués selon sa structure de cotisation et projetés sur les affiliés estimés après conversion des salariés visibles ou signés." ],
    "benchmark_mut" => [ "prix santé comparables", "Santé : référence de prime par salarié recalculée à partir des primes observées sur le portefeuille, puis projetée sur les affiliés estimés après conversion des salariés visibles ou signés." ],
    "benchmark_prev" => [ "prix prév. comparables", "Prévoyance : référence de prime par salarié recalculée à partir des cotisations DSN validées sur trois mois arrêtés à M−2, puis projetée sur les affiliés estimés après conversion des salariés visibles ou signés. Les régularisations anciennes sont exclues." ],
    "none" => [ "part non estimable", "Aucune base exploitable disponible pour estimer une partie des primes." ]
  }.freeze

  module_function

  # ---------- One contract (arr-population-conversion.ts) ----------

  # `row` is a contract_arr_engine row (string keys, as BigQueryClient returns them). Returns the contract's ARR,
  # premiums, source ("invoice" / "estimation"), method, price reliability and the population behind an estimate.
  def contract(row, today: Time.find_zone("Europe/Paris").today.iso8601)
    c = normalize(row)
    actual = invoice_basis(c)
    expected = current_projection(c, today)[:estimated_affiliates]
    representative = !c[:has_readiness] || (c[:readiness_eligible] && c[:partial_people].zero? &&
                                            !expected.nil? && c[:billed_people] >= expected)

    if actual && representative
      reference = (c[:maturity_basis] == "affiliation" ? "#{c[:readiness_reason]}. " : "") +
                  (c[:invoice_reference] || "Dernière période facturée complète, annualisée")
      return result(c, arr: actual[:arr], primes: actual[:primes], source: "invoice", source_detail: "invoice",
                       confidence: "very_high", pricing_reference: reference, pricing_sample_size: c[:invoice_affiliates],
                       pricing_reference_groups: 0, population_projections: [])
    end

    if c[:has_readiness]
      if c[:readiness_eligible] && c[:full_people].positive? && c[:annual_price].to_f.positive?
        c = c.merge(monthly_premium_per_employee: c[:annual_price] / 12.0, source_detail: "invoice_projection",
                    total_commission_rate: actual ? actual[:rate] : c[:total_commission_rate],
                    pricing_sample_size: c[:full_people], pricing_reference_groups: 1,
                    pricing_reference: "#{c[:maturity_basis] == "affiliation" ? "#{c[:readiness_reason]}. " : ""}#{c[:invoice_reference]} " \
                                       "Prix moyen sur #{c[:full_people]} salariés entièrement couverts, hors proratas ; projeté sur les " \
                                       "affiliés attendus. Facture observée conservée séparément.")
      else
        c = c.merge(pricing_reference: "#{c[:pricing_reference]} Facture non retenue pour le rythme de croisière : #{c[:readiness_reason]}.".strip)
      end
    end

    signed = projection(c, "signed")
    current = current_projection(c, today)
    convertible = c[:monthly_premium_per_employee].to_f.positive? && !current[:annual_primes].nil?
    invoice_fallback = !convertible && representative && !c[:factured_primes_annualisees].nil? && c[:months_invoiced].positive?
    projections = [ signed, *([ current ] if current[:basis] == "visible" || current[:billed_people]) ]

    if convertible
      result(c, arr: current[:annual_primes] * c[:total_commission_rate], primes: current[:annual_primes], source: "estimation",
                source_detail: c[:source_detail], confidence: price_confidence(c), population_projections: projections)
    elsif invoice_fallback
      result(c, arr: c[:factured_arr], primes: c[:factured_primes_annualisees], source: "invoice", source_detail: "invoice",
                confidence: "very_high", population_projections: projections)
    else
      result(c, arr: nil, primes: nil, source: "estimation", source_detail: "none", confidence: "very_low",
                population_projections: projections)
    end
  end

  # Expected affiliates and premiums on a basis: the visible employees, or the signed ones.
  def projection(c, basis)
    premium = c[:monthly_premium_per_employee] ? c[:monthly_premium_per_employee] * 12 : nil
    common = { contract_id: c[:contract_id], risk: c[:contract_type] == HEALTH ? "Santé" : "Prévoyance", basis: basis,
               annual_premium_per_affiliate: premium }

    # A complete health census after two months: the affiliates are known, no conversion rate left.
    if basis == "visible" && c[:contract_type] == HEALTH && c[:census_complete] && c[:unresolved_people].zero? &&
       c[:recorded_people] == c[:visible_employees] && c[:census_affiliated] + c[:census_exempt] == c[:recorded_people]
      affiliates = c[:census_affiliated]
      return common.merge(starting_people: affiliates, registration_rate: 1, affiliation_rate: 1, estimated_affiliates: affiliates,
                          annual_primes: premium && premium * affiliates,
                          observed_population: { observed_on: c[:observed_on], exempt_people: c[:census_exempt] })
    end

    reference = CONVERSION[c[:contract_type]]
    registration_rate = basis == "visible" ? 1 : reference&.dig(:registration_rate)
    affiliation_rate = reference && reference[:signed_affiliation_rate] / reference[:registration_rate]
    starting = basis == "visible" ? c[:visible_employees] : c[:effective_salaries]
    estimated = if reference
      starting * (basis == "signed" ? reference[:signed_affiliation_rate] : registration_rate * affiliation_rate)
    end

    # Confirmed affiliates are a floor once the contract is two months old, and the figure when the census is complete.
    valid = basis == "visible" && c[:confirmed_mature] && c[:recorded_people] <= starting &&
            c[:confirmed_affiliated] + c[:confirmed_exempt] + c[:unresolved_people] <= c[:recorded_people]
    complete = valid && c[:census_complete] && c[:unresolved_people].zero? && c[:recorded_people] == starting &&
               c[:confirmed_affiliated] + c[:confirmed_exempt] == starting
    confirmed = valid && (complete || (!estimated.nil? && c[:confirmed_affiliated] > estimated))
    estimated = c[:confirmed_affiliated] if confirmed

    common.merge(starting_people: starting, registration_rate: registration_rate, affiliation_rate: affiliation_rate,
                 estimated_affiliates: estimated, annual_primes: estimated && premium && estimated * premium,
                 **(confirmed ? { confirmed_population: { observed_on: c[:observed_on], complete: !!complete,
                                                          confirmed_affiliates: c[:confirmed_affiliated] } } : {}))
  end

  # Today's run rate: visibles (signed before coverage starts if visibles are still sparse), never below the
  # affiliates already billed on a usable invoice.
  def current_projection(c, today)
    visible = projection(c, c[:visible_employees].positive? ? "visible" : "signed")
    sparse = c[:start_date].present? && c[:start_date] > today && c[:group_risk_visibles].positive? &&
             c[:group_risk_visibles] < FUTURE_VISIBLE_SHARE_FLOOR * c[:group_risk_signed]
    signed = sparse ? projection(c, "signed") : nil
    projected = signed && !signed[:estimated_affiliates].nil? ? signed : visible

    billed = c[:has_readiness] ? c[:billed_people] : c[:invoice_affiliates]
    usable = c[:months_invoiced].positive? &&
             (c[:has_readiness] ? (c[:billed_population_usable].nil? ? c[:readiness_eligible] : c[:billed_population_usable]) : !c[:factured_primes_annualisees].nil?)
    return projected if !usable || !billed.positive? || (!projected[:estimated_affiliates].nil? && projected[:estimated_affiliates] > billed)

    premium = projected[:annual_premium_per_affiliate]
    projected.merge(estimated_affiliates: billed, annual_primes: premium && billed * premium, billed_people: billed,
                    billed_reference: c[:invoice_reference] || "Période facturée complète")
  end

  # Price reliability on the HubSpot pipe's scale (arrPriceConfidence): it qualifies the price, not the population.
  def price_confidence(c)
    sql = c[:calculation_confidence]
    case c[:source_detail]
    when "invoice" then "very_high"
    when "fee_occurrence" then { "high" => "very_high", "medium" => "high" }.fetch(sql, "medium")
    when "dsn_recent" then sql == "low" ? "high" : "very_high"
    when "invoice_projection", "fee", "dsn", "fee_group", "fee_portfolio" then "high"
    when "dsn_group" then %w[medium high].include?(sql) ? "high" : "low"
    when "benchmark_mut", "benchmark_prev" then c[:pricing_reference].to_s.start_with?("CCN + collège") ? "medium" : "low"
    when "none" then "very_low"
    else "low"
    end
  end

  # The last invoiced period, annualised (arr-invoice-rules.ts: historicalInvoiceArrBasis).
  def invoice_basis(c)
    primes = c[:factured_primes_annualisees]
    return nil unless c[:months_invoiced].positive? && primes.to_f.positive?

    arr = c[:factured_arr] || primes * c[:total_commission_rate]
    { primes: primes, arr: arr, rate: arr / primes }
  end

  # ---------- One account (deal-arr-aggregation.ts, arr-estimation-audit.ts) ----------

  # How an account's ARR was obtained, from its contracts' results: what AnalyticsArr.source_label displays.
  def account_calculation(results)
    by_confidence = Hash.new(0.0)
    results.each { |r| by_confidence[r[:confidence]] += r[:arr] if r[:arr].to_f.positive? }
    sources = results.map { |r| r[:source] }.uniq
    groups = results.map { |r| r[:pricing_reference_groups] }.select(&:positive?)
    {
      "source" => sources.size > 1 ? "mixed" : (sources.first || "estimation"),
      "source_details" => results.map { |r| r[:source_detail] }.uniq,
      "confidence" => majority_confidence(by_confidence, results.map { |r| r[:confidence] }),
      "pricing_sample_size" => results.map { |r| r[:pricing_sample_size] }.max.to_i,
      "pricing_references" => results.filter_map { |r| r[:pricing_reference].presence }.uniq.sort,
      "pricing_reference_groups" => groups.min.to_i,
      "months_invoiced" => results.map { |r| r[:months_invoiced] }.max.to_i,
      "population_projections" => results.flat_map { |r| r[:population_projections] }.map { |p| p.deep_stringify_keys }
    }
  end

  # As in the pipe, the level of the majority of the ARR; without any ARR, the weakest level.
  def majority_confidence(amounts, levels)
    total = amounts.values.sum
    return levels.min_by { |level| CONFIDENCE_ORDER.index(level) || 0 } || "very_low" unless total.positive?

    cumulated = 0.0
    CONFIDENCE_ORDER.reverse_each do |level|
      cumulated += amounts.fetch(level, 0.0) / total
      return level if cumulated > 0.5
    end
    "very_low"
  end

  # ---------- Labels (arr-source-label.ts) ----------

  # label (e.g. "Est. tarifs du contrat + DSN du contrat"), compact ("Facturé", "Estimé", "Mixte", "Non estimable"),
  # detail (the methods alone), css class, confidence label and tooltip, from an account's calculation.
  def source_label(calc)
    calc = (calc || {}).stringify_keys
    details = Array(calc["source_details"])
    confidence = calc["confidence"]
    reliability = confidence && confidence != "very_low" ? CONFIDENCE_LABELS[confidence].downcase : nil
    invoice_title = "Calcul basé sur la dernière période facturée complète exploitable, annualisée selon sa fréquence." +
                    (calc["months_invoiced"].to_i.positive? ? " #{calc["months_invoiced"]} périodes disponibles." : "")

    if calc["source"] == "invoice"
      return { label: "Facturé", compact: "Facturé", detail: "dernière période complète", css: "ok", reliability: CONFIDENCE_LABELS["very_high"].downcase,
               title: [ invoice_title, *calc["pricing_references"] ].join(" ") }
    end

    methods = METHODS.select { |method, _| details.include?(method) }.values
    if details.include?("dsn_group") && Array(calc["pricing_references"]).include?("DSN groupe · taux source")
      methods << [ "taux source", "Une partie de la prévoyance conserve les taux DSN du contrat de référence, faute de taux exploitables pour le contrat cible." ]
    end
    detail = methods.map(&:first).join(" + ")
    sample = calc["pricing_sample_size"].to_i
    groups = calc["pricing_reference_groups"].to_i
    references = Array(calc["pricing_references"])
    estimation_title = [
      *methods.map(&:last),
      *Array(calc["population_projections"]).map { |p| describe_projection(p) },
      ("Fiabilité du prix : #{CONFIDENCE_LABELS[confidence].downcase}." if confidence),
      ("Échantillon de référence : #{number(sample)} salariés." if sample.positive?),
      ("Références : #{references.join(" ; ")}." if references.any?),
      ("Groupes de référence : #{number(groups)}#{" (minimum parmi les références)" if references.size > 1}." if groups.positive?)
    ].compact.join(" ")

    if calc["source"] == "mixed"
      { label: detail.present? ? "Mixte #{detail}" : "Mixte",
        compact: "Mixte", detail: detail.presence, css: "tl", reliability: reliability,
        title: "#{invoice_title} Partie estimée : #{estimation_title.presence || "méthode non renseignée."}" }
    elsif details.any? && details.all? { |d| d == "none" }
      { label: "Non estimable", compact: "Non estimable", detail: nil, css: "ko", reliability: nil,
        title: estimation_title.presence || "Aucun prix exploitable pour estimer ce compte." }
    else
      { label: detail.present? ? "Est. #{detail}" : "Estimé", compact: "Estimé", detail: detail.presence, css: "warn", reliability: reliability,
        title: estimation_title.presence || "ARR estimé faute de facture ; méthode non renseignée." }
    end
  end

  # One contract's population, in Analytics' words (describePopulationProjection).
  def describe_projection(p)
    p = p.stringify_keys
    head = "#{p["risk"]} · contrat ##{p["contract_id"]}"
    premium = p["annual_premium_per_affiliate"]
    primes = p["annual_primes"]
    if p["billed_people"] && primes && premium
      return "#{head} : au moins #{number(p["billed_people"])} affiliés facturés × #{number(premium)} €/an = #{number(primes)} €. " \
             "Aucun taux d'affiliation supplémentaire sur cet effectif. #{p["billed_reference"]}. Le prix reste contrôlé séparément."
    end
    if (confirmed = p["confirmed_population"]) && primes && premium
      return "#{head} : #{number(p["estimated_affiliates"])} affiliés actifs confirmés au #{confirmed["observed_on"]} × #{number(premium)} €/an = #{number(primes)} €." +
             (confirmed["complete"] ? " Recensement complet : aucun taux de conversion supplémentaire." :
               " Recensement incomplet : le plancher des affiliés confirmés dépasse la projection. Aucun taux de conversion supplémentaire sur ces affiliés.")
    end
    if (observed = p["observed_population"]) && primes && premium
      return "#{head} : #{number(p["estimated_affiliates"])} affiliés actifs au #{observed["observed_on"]} × #{number(premium)} €/an = #{number(primes)} €. " \
             "Recensement complet après deux mois d’effet ; #{number(observed["exempt_people"])} dispensés. Aucun taux de conversion supplémentaire."
    end

    prefix = "#{head} · #{p["basis"] == "signed" ? "à la signature" : "sur visibles"} : "
    return "#{prefix}non estimable, prix ou référence de conversion insuffisant." if [ primes, premium, p["estimated_affiliates"], p["affiliation_rate"] ].any?(&:nil?)

    reference = CONVERSION[p["risk"] == "Santé" ? HEALTH : PROVIDENT]
    chain = if p["basis"] == "signed"
      "#{number(p["starting_people"])} signés × #{number(reference[:signed_affiliation_rate] * 100)} %"
    else
      "#{number(p["starting_people"])} visibles × #{number(p["affiliation_rate"] * 100)} % affiliés"
    end
    "#{prefix}#{chain} = #{number(p["estimated_affiliates"])} affiliés estimés. " \
      "#{number(p["estimated_affiliates"])} × #{number(premium)} €/an = #{number(primes)} € de primes estimées. " \
      "Référence métier communiquée par Benoît le #{reference[:observed_on]}. Affiliés / signés : #{number(reference[:signed_affiliation_rate] * 100)} %." +
      (p["basis"] == "signed" ? " Ce taux global inclut déjà l’enregistrement." :
        " Enregistrés / signés : #{number(reference[:registration_rate] * 100)} %. Affiliés / visibles = taux global / taux d’enregistrement.")
  end

  # ---------- helpers ----------

  INTEGERS = %i[contract_id visible_employees effective_salaries group_risk_visibles group_risk_signed pricing_sample_size
                pricing_reference_groups months_invoiced invoice_affiliates billed_people full_people partial_people
                recorded_people unresolved_people census_affiliated census_exempt confirmed_affiliated confirmed_exempt].freeze
  FLOATS = %i[total_commission_rate monthly_premium_per_employee factured_primes_annualisees factured_arr annual_price].freeze

  def normalize(row)
    c = row.to_h.symbolize_keys
    INTEGERS.each { |key| c[key] = c[key].to_i }
    FLOATS.each { |key| c[key] = c[key]&.to_f }
    c[:total_commission_rate] ||= 0.0
    c
  end

  def result(c, **attrs)
    { contract_id: c[:contract_id], contract_type: c[:contract_type], months_invoiced: c[:months_invoiced],
      pricing_reference: c[:pricing_reference], pricing_sample_size: c[:pricing_sample_size].to_i,
      pricing_reference_groups: c[:pricing_reference_groups].to_i }.merge(attrs)
  end

  def number(value)
    return "non communiqué" if value.nil?

    ActiveSupport::NumberHelper.number_to_rounded(value.to_f, precision: 2, strip_insignificant_zeros: true,
                                                              delimiter: " ", separator: ",")
  end
end
