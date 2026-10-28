# Pulls the BI's view of every account (company set, or user pro outside any set) - its "responsable AM" in the
# BO, its ARR and the risks it is covered for - into bi_accounts, which "Attribution portefeuille" reads for the
# next campaign. A full replace each run: an account reassigned in the BO shows up under its new AM on the next
# sync, one that lost its AM drops into "Comptes sans AM". The query itself lives in bi_portfolio_query.sql and
# returns one row per account and contract; the ARR of each contract is chosen by the Analytics engine (AnalyticsArr).
class BiPortfolioSync
  QUERY_PATH = Rails.root.join("app/services/bi_portfolio_query.sql")
  # TSA on health premiums, removed so that health ARR is net - the 2026 rate, the same as the upsell formula. Health
  # premiums, invoiced as well as estimated, include it; provident carries none.
  HEALTH_TSA_RATE = UpsellDeal::MUTUELLE_TAXE
  ACCOUNT_COLUMNS = %w[kind name siren user_pros_count am_email am_name employees_count].freeze

  def self.sync!
    new.sync!
  end

  def initialize(client: nil, dataset: ENV.fetch("BI_BIGQUERY_DATASET", "BI_EU"))
    @client = client
    @dataset = dataset
  end

  # Returns the number of accounts written. Raises BigQueryClient::QueryError (nothing replaced) if BigQuery
  # can't be reached or answers with nothing at all - an empty answer is far likelier a broken query or
  # permission than a company with no client left, and must not wipe the page.
  def sync!
    rows = client.query(sql)
    raise BigQueryClient::QueryError, "BigQuery n'a renvoyé aucun compte" if rows.empty?

    now = Time.current
    today = Time.find_zone("Europe/Paris").today.iso8601
    records = rows.group_by { |row| [ row["kind"], row["account_id"] ] }.map { |_, account_rows| record_for(account_rows, now, today) }
    BiAccount.transaction do
      BiAccount.delete_all
      BiAccount.insert_all!(records)
    end
    records.size
  end

  def sql
    dataset = "`#{project_id}.#{@dataset}`"
    format(File.read(QUERY_PATH), dataset: dataset, arr_estimate_ctes: BiArrEstimateSql.ctes(dataset))
  end

  private

  def client
    @client ||= BigQueryClient.new(credentials_json: ENV["BI_BIGQUERY_CREDENTIALS_JSON"], project_id: project_id,
      location: ENV.fetch("BI_BIGQUERY_LOCATION", "EU"))
  end

  def project_id
    ENV.fetch("BI_BIGQUERY_PROJECT_ID", "dogwood-method-256009")
  end

  def record_for(rows, now, today)
    first = rows.first
    attrs = first.slice(*ACCOUNT_COLUMNS).symbolize_keys
    attrs[:am_email] = attrs[:am_email].to_s.strip.downcase.presence
    attrs[:am_name] = attrs[:am_name].to_s.strip.presence

    contracts = rows.select { |row| row["account_contract_id"] }
    results = contracts.map do |row|
      result = row["contract_id"] ? AnalyticsArr.contract(row, today: today) : unknown_contract(row)
      net = row["risque"] == "sante" ? 1 + HEALTH_TSA_RATE : 1
      result.merge(arr: result[:arr].to_f / net, risque: row["risque"], standard: row["standard"])
    end
    arr_of = ->(list) { list.sum { |r| r[:arr] }.round(2) }
    calculation = AnalyticsArr.account_calculation(results) if results.any?

    attrs.merge(
      bi_id: first["account_id"],
      arr: arr_of.call(results),
      arr_sante: arr_of.call(results.select { |r| r[:risque] == "sante" }),
      arr_prevoyance: arr_of.call(results.select { |r| r[:risque] == "prevoyance" }),
      arr_billed: arr_of.call(results.select { |r| r[:source] == "invoice" }),
      arr_estimated: arr_of.call(results.reject { |r| r[:source] == "invoice" }),
      contracts_count: results.size,
      contracts_estimated: results.count { |r| r[:source] != "invoice" },
      has_sante: results.any? { |r| r[:risque] == "sante" },
      has_prevoyance: results.any? { |r| r[:risque] == "prevoyance" },
      has_standard_sante: results.any? { |r| r[:risque] == "sante" && r[:standard] },
      has_sur_mesure_sante: results.any? { |r| r[:risque] == "sante" && !r[:standard] },
      arr_source: calculation&.dig("source"),
      arr_calculation: calculation,
      synced_at: now, created_at: now, updated_at: now
    )
  end

  # An account contract the engine doesn't see (an external affiliation): nothing to value it with.
  def unknown_contract(row)
    { contract_id: row["account_contract_id"], arr: nil, source: "estimation", source_detail: "none", confidence: "very_low",
      pricing_reference: nil, pricing_sample_size: 0, pricing_reference_groups: 0, months_invoiced: 0, population_projections: [] }
  end
end
