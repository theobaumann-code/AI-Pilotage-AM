require "csv"

class PilotageController < ApplicationController
  NOT_QUALIFIED = "À qualifier"
  NO_REFERENT = "Non attribué"

  def show
    @app_setting = AppSetting.instance
    @non_accompagne_churn_entries = NonAccompagneChurnEntry.all
    @active_ams = User.active.order(:name)
    @selectable_companies = Company.order(:name)
    @available_roles = ["Admin", "KAM", "AM"]
    # The "Non accompagné" option lives only in the summary cards' own Équipe filter (not the produit/
    # upsell/risque ones, which are about individual deals) — checking it folds the non-accompagné figures
    # into the summary cards' totals; see PortfolioSummary#non_accompagne.
    @available_summary_roles = @available_roles + ["Non accompagné"]
    @summary_ams = Array(params[:summary_ams]).reject(&:blank?)
    @summary_roles = Array(params[:summary_roles]).reject(&:blank?)
    @available_summary_ams = @active_ams.map(&:name)

    filtered_ams = @active_ams
    filtered_ams = filtered_ams.select { |am| @summary_roles.include?(am.role_label) } if @summary_roles.present?
    filtered_ams = filtered_ams.select { |am| @summary_ams.include?(am.name) } if @summary_ams.present?
    team_filter_active = @summary_ams.present? || @summary_roles.present?

    # No filter at all → the non-accompagné book counts toward the total by default (that's the point of
    # this toggle). The moment any Équipe/AM filter narrows the view, it drops out unless "Non accompagné"
    # is explicitly checked back in — same as narrowing to one AM naturally excludes every other AM's book.
    include_non_accompagne = @summary_roles.empty? || @summary_roles.include?("Non accompagné")

    summary_companies = Company.includes(:produit_deals, :upsell_deals)
    summary_companies = summary_companies.where(user_id: filtered_ams.map(&:id)) if team_filter_active
    @global_summary = PortfolioSummary.new(summary_companies, non_accompagne: (include_non_accompagne ? @app_setting : nil))

    @risque_q = params[:risque_q].to_s.strip
    @risque_ams = Array(params[:risque_ams]).reject(&:blank?)
    @risque_roles = Array(params[:risque_roles]).reject(&:blank?)
    @risque_produits = Array(params[:risque_produits]).reject(&:blank?)
    @risque_assureurs = Array(params[:risque_assureurs]).reject(&:blank?)
    @risque_statuts = Array(params[:risque_statuts]).reject(&:blank?)
    @risque_referents = Array(params[:risque_referents]).reject(&:blank?)
    @risque_manque_offres = params[:risque_manque_offres].present?
    @available_risque_ams = @active_ams.map(&:name)
    @referent_candidates = User.active.managers.order(:name).to_a
    @available_referents = [NO_REFERENT] + @referent_candidates.map(&:name)
    @at_risk_companies = filtered_at_risk_companies
    @rque_pager = TablePager.new(@at_risk_companies, params: params, prefix: "rque",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:company].name) },
        am: ->(r) { TablePager.key(r[:am].name) },
        count: ->(r) { TablePager.key(r[:count]) },
        arr_at_risk: ->(r) { TablePager.key(r[:arr_at_risk]) },
        max_risque: ->(r) { TablePager.key(r[:max_risque]) },
        last_note_at: ->(r) { TablePager.key(r[:last_note_at]) },
        referent: ->(r) { TablePager.key(r[:company].referent&.name) }
      }, default_sort: :arr_at_risk, default_dir: "desc")

    @produit_q = params[:produit_q].to_s.strip
    @produit_ams = Array(params[:produit_ams]).reject(&:blank?)
    @produit_roles = Array(params[:produit_roles]).reject(&:blank?)
    @produit_produits = Array(params[:produit_produits]).reject(&:blank?)
    @produit_assureurs = Array(params[:produit_assureurs]).reject(&:blank?)
    @produit_taux_min = numeric_param(params[:produit_taux_min])
    @produit_taux_max = numeric_param(params[:produit_taux_max])
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

    load_churn_filters
    @available_churn_ams = @active_ams.map(&:name)
    @global_churned = filtered_global_churned
    @churn_arr_total = @global_churned.sum { |d| d.arr.to_f }
    @gchurn_pager = TablePager.new(@global_churned, params: params, prefix: "gchurn",
      sort_procs: {
        nom: ->(d) { TablePager.key(d.company.name) },
        am: ->(d) { TablePager.key(d.company.user.name) },
        produit: ->(d) { TablePager.key(d.produit) },
        college: ->(d) { TablePager.key(d.college) },
        assureur: ->(d) { TablePager.key(d.assureur) },
        identifiant: ->(d) { TablePager.key(d.identifiant) },
        arr: ->(d) { TablePager.key(d.arr.to_f) },
        churn_reason: ->(d) { TablePager.key(d.churn_reason.to_s) }
      }, default_sort: :nom)

    @upsell_q = params[:upsell_q].to_s.strip
    @upsell_ams = Array(params[:upsell_ams]).reject(&:blank?)
    @upsell_roles = Array(params[:upsell_roles]).reject(&:blank?)
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
        college: ->(d) { TablePager.key(d.college) },
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
    @upsell_roles = Array(params[:upsell_roles]).reject(&:blank?)
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
    @produit_roles = Array(params[:produit_roles]).reject(&:blank?)
    @produit_produits = Array(params[:produit_produits]).reject(&:blank?)
    @produit_assureurs = Array(params[:produit_assureurs]).reject(&:blank?)
    @produit_taux_min = numeric_param(params[:produit_taux_min])
    @produit_taux_max = numeric_param(params[:produit_taux_max])
    @produit_statuts = Array(params[:produit_statuts]).reject(&:blank?)

    csv = CSV.generate(col_sep: ";") do |csv|
      header = ["Nom", "AM", "Produit", "Collège", "Assureur"]
      header << "ID externe" if current_user.admin?
      header.concat(["ARR (€)", "Taux négocié (%)", "Statut de renouvellement", "% risque churn", "ARR final (€)"])
      csv << header
      filtered_global_produits.each do |d|
        row = [d.company.name, d.company.user.name, d.produit, d.college, d.assureur]
        row << d.identifiant if current_user.admin?
        row.concat([d.arr, d.taux, d.statut_renouvellement, d.risque_churn, d.final_arr])
        csv << row
      end
    end

    send_data "\xEF\xBB\xBF" + csv, filename: "produits-tous-am-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8"
  end

  # Mirrors "Produits churnés (tous AM)" exactly (same filters, unpaginated), across every AM.
  def export_churn
    load_churn_filters

    csv = CSV.generate(col_sep: ";") do |csv|
      header = ["Nom", "AM", "Produit", "Collège", "Assureur"]
      header << "ID externe" if current_user.admin?
      header.concat(["ARR churné (€)", "Raison du churn", "Commentaire"])
      csv << header
      filtered_global_churned.each do |d|
        row = [d.company.name, d.company.user.name, d.produit, d.college, d.assureur]
        row << d.identifiant if current_user.admin?
        row.concat([d.arr, d.churn_reason, d.churn_comment])
        csv << row
      end
    end

    send_data "\xEF\xBB\xBF" + csv, filename: "produits-churnes-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8"
  end

  # Mirrors "Entreprises à risque" exactly (same filters, unpaginated), across every AM.
  def export_risque
    @risque_q = params[:risque_q].to_s.strip
    @risque_ams = Array(params[:risque_ams]).reject(&:blank?)
    @risque_roles = Array(params[:risque_roles]).reject(&:blank?)
    @risque_produits = Array(params[:risque_produits]).reject(&:blank?)
    @risque_assureurs = Array(params[:risque_assureurs]).reject(&:blank?)
    @risque_statuts = Array(params[:risque_statuts]).reject(&:blank?)
    @risque_referents = Array(params[:risque_referents]).reject(&:blank?)
    @risque_manque_offres = params[:risque_manque_offres].present?

    csv = CSV.generate(col_sep: ";") do |csv|
      csv << ["Nom", "AM", "Nb produits à risque", "ARR à risque (€)", "% risque max", "Manque d'offres",
              "Date du dernier commentaire", "Référent"]
      filtered_at_risk_companies.each do |r|
        csv << [r[:company].name, r[:am].name, r[:count], r[:arr_at_risk].round(2), r[:max_risque],
                r[:company].risque_manque_offres? ? "Oui" : "Non", r[:last_note_at]&.strftime("%d/%m/%Y"),
                r[:company].referent&.name]
      end
    end

    send_data "\xEF\xBB\xBF" + csv, filename: "entreprises-a-risque-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8"
  end

  private

  # A company is "at risk" once at least one of its still-active (non-churned) produits carries a nonzero
  # risque_churn — grouped from the same filtered produit-deal scope filtered_global_produits uses, so the
  # AM/Équipe/Produit/Statut filters behave identically to every other Vue globale table.
  def filtered_at_risk_companies
    deals = ProduitDeal.includes(company: [:user, :referent, :risk_notes]).to_a
    deals = deals.reject(&:churned?)
    deals = deals.select { |d| d.risque_churn.to_i > 0 }
    deals = deals.select { |d| d.company.name.downcase.include?(@risque_q.downcase) } if @risque_q.present?
    deals = deals.select { |d| @risque_ams.include?(d.company.user.name) } if @risque_ams.present?
    deals = deals.select { |d| @risque_roles.include?(d.company.user.role_label) } if @risque_roles.present?
    deals = deals.select { |d| @risque_produits.include?(d.produit) } if @risque_produits.present?
    deals = deals.select { |d| @risque_assureurs.include?(d.assureur) } if @risque_assureurs.present?
    deals = deals.select { |d| @risque_statuts.include?(d.statut_renouvellement) } if @risque_statuts.present?
    deals = deals.select { |d| d.company.risque_manque_offres? } if @risque_manque_offres
    deals = deals.select { |d| @risque_referents.include?(d.company.referent&.name || NO_REFERENT) } if @risque_referents.present?

    deals.group_by(&:company).map do |company, company_deals|
      {
        company: company,
        am: company.user,
        count: company_deals.size,
        arr_at_risk: company_deals.sum { |d| d.arr.to_f * d.risque_churn.to_f / 100 },
        max_risque: company_deals.map(&:risque_churn).max,
        last_note_at: company.risk_notes.map(&:created_at).max
      }
    end
  end

  def load_churn_filters
    @churn_q = params[:churn_q].to_s.strip
    @churn_ams = Array(params[:churn_ams]).reject(&:blank?)
    @churn_roles = Array(params[:churn_roles]).reject(&:blank?)
    @churn_produits = Array(params[:churn_produits]).reject(&:blank?)
    @churn_assureurs = Array(params[:churn_assureurs]).reject(&:blank?)
    @churn_raisons = Array(params[:churn_raisons]).reject(&:blank?)
  end

  # Only "Churné" (a lost contract the AM had a hand in) — not "Churné (subi)", which is liquidation/
  # acquisition and carries no reason worth qualifying.
  def filtered_global_churned
    deals = ProduitDeal.includes(company: :user).where(statut_renouvellement: ProduitDeal::CHURNED).to_a
    deals = deals.select { |d| d.company.name.downcase.include?(@churn_q.downcase) } if @churn_q.present?
    deals = deals.select { |d| @churn_ams.include?(d.company.user.name) } if @churn_ams.present?
    deals = deals.select { |d| @churn_roles.include?(d.company.user.role_label) } if @churn_roles.present?
    deals = deals.select { |d| @churn_produits.include?(d.produit) } if @churn_produits.present?
    deals = deals.select { |d| @churn_assureurs.include?(d.assureur) } if @churn_assureurs.present?
    deals = deals.select { |d| @churn_raisons.include?(d.churn_reason.presence || NOT_QUALIFIED) } if @churn_raisons.present?
    deals.sort_by { |d| d.company.name }
  end

  def filtered_global_upsells
    deals = UpsellDeal.includes(:user, company: :user).to_a
    deals = deals.select { |d| d.company.name.downcase.include?(@upsell_q.downcase) } if @upsell_q.present?
    deals = deals.select { |d| @upsell_ams.include?(d.effective_user.name) } if @upsell_ams.present?
    deals = deals.select { |d| @upsell_roles.include?(d.effective_user.role_label) } if @upsell_roles.present?
    deals = deals.select { |d| @upsell_produits.include?(d.produit) } if @upsell_produits.present?
    deals = deals.select { |d| @upsell_statuts.include?(d.statut_signature) } if @upsell_statuts.present?
    deals.sort_by { |d| d.company.name }
  end

  def filtered_global_produits
    deals = ProduitDeal.includes(company: :user).to_a
    deals = deals.select { |d| d.company.name.downcase.include?(@produit_q.downcase) } if @produit_q.present?
    deals = deals.select { |d| @produit_ams.include?(d.company.user.name) } if @produit_ams.present?
    deals = deals.select { |d| @produit_roles.include?(d.company.user.role_label) } if @produit_roles.present?
    deals = deals.select { |d| @produit_produits.include?(d.produit) } if @produit_produits.present?
    deals = deals.select { |d| @produit_assureurs.include?(d.assureur) } if @produit_assureurs.present?
    deals = deals.select { |d| d.taux.to_f >= @produit_taux_min } if @produit_taux_min
    deals = deals.select { |d| d.taux.to_f <= @produit_taux_max } if @produit_taux_max
    deals = deals.select { |d| @produit_statuts.include?(d.statut_renouvellement) } if @produit_statuts.present?
    deals.sort_by { |d| d.company.name }
  end

  def weighted_avg(rows, value_method, weight_method)
    total_weight = rows.sum { |r| r.public_send(weight_method).to_f }
    return nil if total_weight <= 0

    rows.sum { |r| r.public_send(value_method).to_f * r.public_send(weight_method).to_f } / total_weight
  end
end
