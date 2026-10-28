# Temporary "Résiliations en attente": pulls the BO's contract terminations waiting for signature into
# bi_pending_terminations, on the same schedule as BiPortfolioSync (see BiPortfolioSyncJob). A full replace each run.
# Unlike the accounts, an empty answer is a valid one (no termination waiting) and empties the table.
class BiPendingTerminationSync
  QUERY_PATH = Rails.root.join("app/services/bi_pending_terminations_query.sql")
  COLUMNS = %w[bi_id name terminable_type terminable_id product_type user_pro_id social_name account_kind account_bi_id
               created_on termination_date contract_arr].freeze

  def self.sync!
    new.sync!
  end

  def initialize(client: nil, dataset: ENV.fetch("BI_BIGQUERY_DATASET", "BI_EU"))
    @client = client
    @dataset = dataset
  end

  # Returns the number of terminations written. Raises BigQueryClient::QueryError (nothing replaced) on failure.
  def sync!
    now = Time.current
    records = client.query(sql).map do |row|
      COLUMNS.index_with { |c| row[c] }.merge("contract_arr" => row["contract_arr"]&.to_f&.round(2), "synced_at" => now)
    end
    BiPendingTermination.transaction do
      BiPendingTermination.delete_all
      BiPendingTermination.insert_all!(records) if records.any?
    end
    records.size
  end

  def sql
    dataset = "`#{project_id}.#{@dataset}`"
    format(File.read(QUERY_PATH), dataset: dataset, health_tsa_rate: BiPortfolioSync::HEALTH_TSA_RATE)
  end

  private

  def client
    @client ||= BigQueryClient.new(credentials_json: ENV["BI_BIGQUERY_CREDENTIALS_JSON"], project_id: project_id,
      location: ENV.fetch("BI_BIGQUERY_LOCATION", "EU"))
  end

  def project_id
    ENV.fetch("BI_BIGQUERY_PROJECT_ID", "dogwood-method-256009")
  end
end
