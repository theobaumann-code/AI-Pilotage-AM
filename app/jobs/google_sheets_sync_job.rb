# Runs off the request cycle so a produit edit doesn't wait on Google's API — enqueued after every commit
# that changes what's on the sheet (see ProduitDeal, Company, User).
class GoogleSheetsSyncJob < ApplicationJob
  queue_as :default

  def perform
    GoogleSheetsSync.sync_produits!
  rescue GoogleSheetsSync::SyncError => error
    Rails.logger.error("[GoogleSheetsSync] #{error.message}")
  end
end
