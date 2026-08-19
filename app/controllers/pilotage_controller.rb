class PilotageController < ApplicationController
  def show
    @am_rows = User.active.order(:name).map do |am|
      { am: am, summary: PortfolioSummary.new(am.companies.includes(:deals)) }
    end
    @global_summary = PortfolioSummary.new(Company.all)

    @renewal_am_id = params[:renewal_am_id]
    @renewal_produit = params[:renewal_produit]
    @renewal_donut = renewal_donut_slices

    @upsell_produit = params[:upsell_produit]
    @global_upsells = filtered_global_upsells
    @upsell_montant_total = @global_upsells.sum(&:upsell_amount)
    @upsell_projection_total = @global_upsells.sum(&:projection)
    @upsell_signed_total = @global_upsells.select(&:signed?).sum(&:upsell_amount)
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

  def filtered_global_upsells
    deals = UpsellDeal.includes(:company).to_a
    deals = deals.select { |d| d.produit == @upsell_produit } if @upsell_produit.present?
    deals.sort_by { |d| d.company.name }
  end
end
