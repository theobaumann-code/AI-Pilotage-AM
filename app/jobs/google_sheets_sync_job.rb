# Runs off the request cycle so a produit edit doesn't wait on Google's API — enqueued after every commit
# that changes what's on the sheet (see ProduitDeal, Company, User).
class GoogleSheetsSyncJob < ApplicationJob
  queue_as :default

  # Enqueuing is a side effect of an ordinary model save, called from an after_commit callback — it must
  # never be allowed to fail that save. It once did: the queue backend's own tables hadn't been migrated in
  # production, so every produit edit's after_commit blew up with a 500 (surfacing to the user as the whole
  # inline-edit table vanishing, since Turbo has no frame content to fall back on for an error response).
  def self.enqueue
    perform_later
  rescue StandardError => error
    Rails.logger.error("[GoogleSheetsSync] failed to enqueue: #{error.message}")
  end

  def perform
    GoogleSheetsSync.sync_produits!
  rescue GoogleSheetsSync::SyncError => error
    Rails.logger.error("[GoogleSheetsSync] #{error.message}")
  end
end
