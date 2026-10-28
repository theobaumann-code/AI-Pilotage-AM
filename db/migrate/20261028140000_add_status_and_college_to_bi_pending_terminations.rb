class AddStatusAndCollegeToBiPendingTerminations < ActiveRecord::Migration[8.1]
  def change
    # The rubric now follows the produits flagged "A résilier" / "Nouveau contrat": every 2026 BO termination is
    # synced, whatever its status, with the collège it targets so it can be matched to the produit's.
    add_column :bi_pending_terminations, :operation_status, :integer
    add_column :bi_pending_terminations, :college_type, :integer
  end
end
