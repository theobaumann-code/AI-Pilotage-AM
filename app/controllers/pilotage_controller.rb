require "csv"

class PilotageController < ApplicationController
  def show
    @active_ams = User.active.order(:name)
    # produit_deals/upsell_deals are separate has_many associations from :deals (each with its own `type`
    # scope), so `includes(:deals)` doesn't preload them — every PortfolioSummary/Company aggregate method
    # below would otherwise issue its own query per company, which is what made this page crawl once there
    # were enough companies in production (1200+ queries, 20s+ loads).
    @am_rows = @active_ams.map do |am|
      { am: am, summary: PortfolioSummary.new(am.companies.includes(:produit_deals), user: am) }
    end
    @global_summary = PortfolioSummary.new(Company.includes(:produit_deals, :upsell_deals))

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
    @available_upsell_ams = @active_ams.map(&:name)
    @global_upsells = filtered_global_upsells
    @upsell_montant_total = @global_upsells.sum(&:upsell_amount)
    @upsell_projection_total = @global_upsells.sum(&:projection)
    @upsell_signed_total = @global_upsells.select(&:signed?).sum(&:upsell_amount)
    @ups_pager = TablePager.new(@global_upsells, params: params, prefix: "gups",
      sort_procs: {
        nom: ->(d) { TablePager.key(d.company.name) },
        am: ->(d) { TablePager.key(d.effective_user.name) },
        produit: ->(d) { TablePager.key(d.produit) },
        nombre_salaries: ->(d) { TablePager.key(d.nombre_salaries) },
        upsell_amount: ->(d) { TablePager.key(d.upsell_amount) },
        probabilite_signature: ->(d) { TablePager.key(d.probabilite_signature) },
        projection: ->(d) { TablePager.key(d.projection) },
        statut_signature: ->(d) { TablePager.key(d.statut_signature) }
      }, default_sort: :nom)
  end

  # Mirrors "Upsells en cours (tous AM)" exactly (same filters, unpaginated), across every AM.
  def export_upsells
    @upsell_q = params[:upsell_q].to_s.strip
    @upsell_ams = Array(params[:upsell_ams]).reject(&:blank?)
    @upsell_produits = Array(params[:upsell_produits]).reject(&:blank?)
    @upsell_statuts = Array(params[:upsell_statuts]).reject(&:blank?)

    csv = CSV.generate(col_sep: ";") do |csv|
      csv << ["Nom", "AM", "Produit", "Nb salariés", "Montant ARR upsellé (€)", "% de chance",
              "Projection upsell (€)", "Statut de signature"]
      filtered_global_upsells.each do |d|
        csv << [d.company.name, d.effective_user.name, d.produit, d.nombre_salaries, d.upsell_amount,
                d.probabilite_signature, d.projection, d.statut_signature]
      end
    end

    send_data "\xEF\xBB\xBF" + csv, filename: "upsells-tous-am-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8"
  end

  # Every produit deal across every AM — there's no on-screen raw table to mirror here (only the
  # "Nouveau contrat vs augmentation" donut, which shows aggregate counts, not rows), so this is
  # deliberately unfiltered: the whole renewal dataset in one file.
  def export_produits
    deals = ProduitDeal.includes(company: :user).to_a.sort_by { |d| d.company.name }

    csv = CSV.generate(col_sep: ";") do |csv|
      csv << ["Nom", "AM", "Produit", "Collège", "Assureur", "ID externe", "ARR (€)", "Taux négocié (%)",
              "Statut de renouvellement", "ARR final (€)"]
      deals.each do |d|
        csv << [d.company.name, d.company.user.name, d.produit, d.college, d.assureur, d.identifiant,
                d.arr, d.taux, d.statut_renouvellement, d.final_arr]
      end
    end

    send_data "\xEF\xBB\xBF" + csv, filename: "produits-tous-am-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8"
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
    deals = UpsellDeal.includes(:user, company: :user).to_a
    deals = deals.select { |d| d.company.name.downcase.include?(@upsell_q.downcase) } if @upsell_q.present?
    deals = deals.select { |d| @upsell_ams.include?(d.effective_user.name) } if @upsell_ams.present?
    deals = deals.select { |d| @upsell_produits.include?(d.produit) } if @upsell_produits.present?
    deals = deals.select { |d| @upsell_statuts.include?(d.statut_signature) } if @upsell_statuts.present?
    deals.sort_by { |d| d.company.name }
  end
end
