class PilotageController < ApplicationController
  def show
    @am_rows = User.active.order(:name).map do |am|
      { am: am, summary: PortfolioSummary.new(am.companies.includes(:deals)) }
    end
    @global_summary = PortfolioSummary.new(Company.all)

    @am_q = params[:am_q].to_s.strip
    am_rows_filtered = @am_q.present? ? @am_rows.select { |r| r[:am].name.downcase.include?(@am_q.downcase) } : @am_rows
    @am_pager = TablePager.new(am_rows_filtered, params: params, prefix: "am",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:am].name) },
        role: ->(r) { TablePager.key(r[:am].admin? ? 1 : 0) },
        count: ->(r) { TablePager.key(r[:summary].count) },
        arr_initial: ->(r) { TablePager.key(r[:summary].arr_initial) },
        churned: ->(r) { TablePager.key(r[:summary].churned) },
        upsold: ->(r) { TablePager.key(r[:summary].upsold) },
        renewed_arr: ->(r) { TablePager.key(r[:summary].renewed_arr) },
        arr_final: ->(r) { TablePager.key(r[:summary].arr_final) },
        nrr: ->(r) { TablePager.key(r[:summary].nrr) },
        statut: ->(r) { TablePager.key(r[:summary].target_met? ? 1 : 0) }
      }, default_sort: :nom)

    @renewal_am_id = params[:renewal_am_id]
    @renewal_produit = params[:renewal_produit]
    @renewal_donut = renewal_donut_slices

    @upsell_q = params[:upsell_q].to_s.strip
    @upsell_ams = Array(params[:upsell_ams]).reject(&:blank?)
    @upsell_produits = Array(params[:upsell_produits]).reject(&:blank?)
    @upsell_statuts = Array(params[:upsell_statuts]).reject(&:blank?)
    @available_upsell_ams = User.active.order(:name).pluck(:name)
    @global_upsells = filtered_global_upsells
    @upsell_montant_total = @global_upsells.sum(&:upsell_amount)
    @upsell_projection_total = @global_upsells.sum(&:projection)
    @upsell_signed_total = @global_upsells.select(&:signed?).sum(&:upsell_amount)
    @ups_pager = TablePager.new(@global_upsells, params: params, prefix: "gups",
      sort_procs: {
        nom: ->(d) { TablePager.key(d.company.name) },
        am: ->(d) { TablePager.key(d.company.user.name) },
        produit: ->(d) { TablePager.key(d.produit) },
        nombre_salaries: ->(d) { TablePager.key(d.nombre_salaries) },
        upsell_amount: ->(d) { TablePager.key(d.upsell_amount) },
        probabilite_signature: ->(d) { TablePager.key(d.probabilite_signature) },
        projection: ->(d) { TablePager.key(d.projection) },
        statut_signature: ->(d) { TablePager.key(d.statut_signature) }
      }, default_sort: :nom)
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
    deals = UpsellDeal.includes(company: :user).to_a
    deals = deals.select { |d| d.company.name.downcase.include?(@upsell_q.downcase) } if @upsell_q.present?
    deals = deals.select { |d| @upsell_ams.include?(d.company.user.name) } if @upsell_ams.present?
    deals = deals.select { |d| @upsell_produits.include?(d.produit) } if @upsell_produits.present?
    deals = deals.select { |d| @upsell_statuts.include?(d.statut_signature) } if @upsell_statuts.present?
    deals.sort_by { |d| d.company.name }
  end
end
