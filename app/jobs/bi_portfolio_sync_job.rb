# Refreshes bi_accounts from BigQuery - scheduled in config/recurring.yml after the BI's own morning refresh, so an
# AM assigned in the BO shows up in "Attribution portefeuille" the next day at the latest. Admins can also run it
# from the page.
class BiPortfolioSyncJob < ApplicationJob
  queue_as :default

  def perform
    count = BiPortfolioSync.sync!
    Rails.logger.info("[BiPortfolioSync] #{count} comptes synchronisés")
    # Temporary "Suivi des résiliations" rubric.
    terminations = BiPendingTerminationSync.sync!
    Rails.logger.info("[BiPendingTerminationSync] #{terminations} résiliations 2026 synchronisées")
  rescue BigQueryClient::QueryError => error
    Rails.logger.error("[BiPortfolioSync] #{error.message}")
  end
end
