# Pulls the BI's view of every account (company set, or user pro outside any set) - its "responsable AM" in the
# BO, its ARR and the risks it is covered for - into bi_accounts, which "Attribution portefeuille" reads for the
# next campaign. A full replace each run: an account reassigned in the BO shows up under its new AM on the next
# sync, one that lost its AM drops into "Comptes sans AM". The query itself lives in bi_portfolio_query.sql.
class BiPortfolioSync
  QUERY_PATH = Rails.root.join("app/services/bi_portfolio_query.sql")
  COLUMNS = %w[kind name siren user_pros_count am_email am_name arr arr_sante arr_prevoyance has_sante has_prevoyance
               has_standard_sante contracts_count contracts_without_q1 employees_count arr_billed arr_estimated
               contracts_estimated].freeze

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
    records = rows.map { |row| record_for(row, now) }
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

  def record_for(row, now)
    attrs = row.slice(*COLUMNS).symbolize_keys
    attrs[:am_email] = attrs[:am_email].to_s.strip.downcase.presence
    attrs[:am_name] = attrs[:am_name].to_s.strip.presence
    %i[arr arr_sante arr_prevoyance arr_billed arr_estimated].each { |key| attrs[key] = attrs[key].to_f.round(2) }
    attrs[:contracts_estimated] = attrs[:contracts_estimated].to_i
    attrs.merge(bi_id: row["account_id"], synced_at: now, created_at: now, updated_at: now)
  end
end
