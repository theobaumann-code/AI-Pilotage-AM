class PortfolioController < ApplicationController
  def show
    @companies = viewed_user.companies.includes(:deals).order(:name)
    @summary = PortfolioSummary.new(@companies)
    @produit_deals = @companies.flat_map(&:produit_deals).sort_by { |d| d.company.name }
    @upsell_deals = @companies.flat_map(&:upsell_deals).sort_by { |d| d.company.name }
    @viewable_ams = current_user.admin? ? User.active.order(:name) : nil
    @selectable_companies = current_user.admin? ? Company.order(:name) : current_user.companies.order(:name)

    @evo_q = params[:evo_q].to_s.strip
    @evo_pager = TablePager.new(filter_by_name(@companies.to_a, @evo_q, &:name), params: params, prefix: "evo",
      sort_procs: {
        nom: ->(c) { TablePager.key(c.name) },
        arr_initial: ->(c) { TablePager.key(c.arr_initial) },
        churned: ->(c) { TablePager.key(c.churned_arr) },
        avg_increase_pct: ->(c) { TablePager.key(c.avg_increase_pct) },
        upsold: ->(c) { TablePager.key(c.upsold_arr) },
        final_arr: ->(c) { TablePager.key(c.final_arr) },
        evolution_pct: ->(c) { TablePager.key(c.evolution_pct) }
      }, default_sort: :nom)

    @ren_q = params[:ren_q].to_s.strip
    @ren_produit = params[:ren_produit]
    @ren_statut = params[:ren_statut]
    ren_rows = filter_by_name(@produit_deals, @ren_q) { |d| d.company.name }
    ren_rows = ren_rows.select { |d| d.produit == @ren_produit } if @ren_produit.present?
    ren_rows = ren_rows.select { |d| d.statut_renouvellement == @ren_statut } if @ren_statut.present?
    @ren_pager = TablePager.new(ren_rows, params: params, prefix: "ren",
      sort_procs: {
        nom: ->(d) { TablePager.key(d.company.name) },
        produit: ->(d) { TablePager.key(d.produit) },
        college: ->(d) { TablePager.key(d.college) },
        assureur: ->(d) { TablePager.key(d.assureur) },
        identifiant: ->(d) { TablePager.key(d.identifiant) },
        arr: ->(d) { TablePager.key(d.arr.to_f) },
        taux: ->(d) { TablePager.key(d.taux.to_f) },
        statut_renouvellement: ->(d) { TablePager.key(d.statut_renouvellement) },
        final_arr: ->(d) { TablePager.key(d.final_arr) }
      }, default_sort: :nom)

    @ups_q = params[:ups_q].to_s.strip
    @ups_produit = params[:ups_produit]
    @ups_statut = params[:ups_statut]
    ups_rows = filter_by_name(@upsell_deals, @ups_q) { |d| d.company.name }
    ups_rows = ups_rows.select { |d| d.produit == @ups_produit } if @ups_produit.present?
    ups_rows = ups_rows.select { |d| d.statut_signature == @ups_statut } if @ups_statut.present?
    @ups_pager = TablePager.new(ups_rows, params: params, prefix: "ups",
      sort_procs: {
        nom: ->(d) { TablePager.key(d.company.name) },
        produit: ->(d) { TablePager.key(d.produit) },
        nombre_salaries: ->(d) { TablePager.key(d.nombre_salaries) },
        probabilite_signature: ->(d) { TablePager.key(d.probabilite_signature) },
        statut_signature: ->(d) { TablePager.key(d.statut_signature) },
        upsell_amount: ->(d) { TablePager.key(d.upsell_amount) },
        projection: ->(d) { TablePager.key(d.projection) }
      }, default_sort: :nom)
  end

  private

  def filter_by_name(list, query)
    return list if query.blank?
    q = query.downcase
    list.select { |r| (block_given? ? yield(r) : r.name).to_s.downcase.include?(q) }
  end
end
