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
    @summary_ams = Array(params[:summary_ams]).reject(&:blank?)
    @summary_roles = Array(params[:summary_roles]).reject(&:blank?)
    @available_summary_ams = @active_ams.map(&:name)
    @available_summary_roles = ["Admin", "KAM", "AM"]

    # Both filters narrow the same "team" of AMs — used below for both the summary cards and the roster
    # table, so selecting a role and/or specific names filters the two together rather than independently.
    filtered_ams = @active_ams
    filtered_ams = filtered_ams.select { |am| @summary_roles.include?(am.role_label) } if @summary_roles.present?
    filtered_ams = filtered_ams.select { |am| @summary_ams.include?(am.name) } if @summary_ams.present?
    team_filter_active = @summary_ams.present? || @summary_roles.present?

    summary_companies = Company.includes(:produit_deals, :upsell_deals)
    summary_companies = summary_companies.where(user_id: filtered_ams.map(&:id)) if team_filter_active
    @global_summary = PortfolioSummary.new(summary_companies)

    @am_q = params[:am_q].to_s.strip
    am_rows_filtered = @am_rows
    am_rows_filtered = am_rows_filtered.select { |r| @summary_roles.include?(r[:am].role_label) } if @summary_roles.present?
    am_rows_filtered = am_rows_filtered.select { |r| @summary_ams.include?(r[:am].name) } if @summary_ams.present?
    am_rows_filtered = am_rows_filtered.select { |r| r[:am].name.downcase.include?(@am_q.downcase) } if @am_q.present?
    @am_pager = TablePager.new(am_rows_filtered, params: params, prefix: "am",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:am].name) },
        role: ->(r) { TablePager.key({ admin: 0, kam: 1, am: 2 }[r[:am].role]) },
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

    @produit_q = params[:produit_q].to_s.strip
    @produit_ams = Array(params[:produit_ams]).reject(&:blank?)
    @produit_produits = Array(params[:produit_produits]).reject(&:blank?)
    @produit_statuts = Array(params[:produit_statuts]).reject(&:blank?)
    @available_produit_ams = @active_ams.map(&:name)
    @global_produits = filtered_global_produits
    @produit_taux_avg = weighted_avg(@global_produits, :taux, :arr)
    @gprod_pager = TablePager.new(@global_produits, params: params, prefix: "gprod",
      sort_procs: {
        nom: ->(d) { TablePager.key(d.company.name) },
        am: ->(d) { TablePager.key(d.company.user.name) },
        produit: ->(d) { TablePager.key(d.produit) },
        college: ->(d) { TablePager.key(d.college) },
        assureur: ->(d) { TablePager.key(d.assureur) },
        identifiant: ->(d) { TablePager.key(d.identifiant) },
        arr: ->(d) { TablePager.key(d.arr.to_f) },
        taux: ->(d) { TablePager.key(d.taux.to_f) },
        statut_renouvellement: ->(d) { TablePager.key(d.statut_renouvellement) },
        risque_churn: ->(d) { TablePager.key(d.risque_churn) },
        final_arr: ->(d) { TablePager.key(d.final_arr) }
      }, default_sort: :nom)

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

  # Mirrors "Produits à renouveler (tous AM)" exactly (same filters, unpaginated), across every AM.
  def export_produits
    @produit_q = params[:produit_q].to_s.strip
    @produit_ams = Array(params[:produit_ams]).reject(&:blank?)
    @produit_produits = Array(params[:produit_produits]).reject(&:blank?)
    @produit_statuts = Array(params[:produit_statuts]).reject(&:blank?)

    csv = CSV.generate(col_sep: ";") do |csv|
      csv << ["Nom", "AM", "Produit", "Collège", "Assureur", "ID externe", "ARR (€)", "Taux négocié (%)",
              "Statut de renouvellement", "% risque churn", "ARR final (€)"]
      filtered_global_produits.each do |d|
        csv << [d.company.name, d.company.user.name, d.produit, d.college, d.assureur, d.identifiant,
                d.arr, d.taux, d.statut_renouvellement, d.risque_churn, d.final_arr]
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

  def filtered_global_produits
    deals = ProduitDeal.includes(company: :user).to_a
    deals = deals.select { |d| d.company.name.downcase.include?(@produit_q.downcase) } if @produit_q.present?
    deals = deals.select { |d| @produit_ams.include?(d.company.user.name) } if @produit_ams.present?
    deals = deals.select { |d| @produit_produits.include?(d.produit) } if @produit_produits.present?
    deals = deals.select { |d| @produit_statuts.include?(d.statut_renouvellement) } if @produit_statuts.present?
    deals.sort_by { |d| d.company.name }
  end

  def weighted_avg(rows, value_method, weight_method)
    total_weight = rows.sum { |r| r.public_send(weight_method).to_f }
    return nil if total_weight <= 0

    rows.sum { |r| r.public_send(value_method).to_f * r.public_send(weight_method).to_f } / total_weight
  end
end
