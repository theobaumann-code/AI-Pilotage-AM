# Split out of Vue globale (which had grown too dense) — open to the same audience Vue globale itself is
# (no before_action here, matching PilotageController's own lack of one), since this is just a different
# slice of the same reporting data, not a rights-management action.
class AutresStatistiquesController < ApplicationController
  def show
    @renewal_am_id = params[:renewal_am_id]
    @renewal_produit = params[:renewal_produit]
    @renewal_donut = renewal_donut_slices
  end

  private

  # Mirrors the original's "Nouveau contrat vs Augmentation" donut: only produit deals that were actually
  # renewed are in scope — "En cours" and "Churné" fall outside this chart entirely.
  def renewal_donut_slices
    scope = ProduitDeal.joins(:company)
    scope = scope.where(companies: { user_id: @renewal_am_id }) if @renewal_am_id.present?
    scope = scope.where(produit: @renewal_produit) if @renewal_produit.present?
    nouveau = scope.where(statut_renouvellement: "Nouveau contrat").count
    augmentation = scope.where(statut_renouvellement: ["Augmenté", "Augmentation particulière"]).count
    [
      { label: "Nouveau contrat", value: nouveau, color: "var(--primary)" },
      { label: "Augmentation", value: augmentation, color: "var(--burgundy)" }
    ]
  end
end
