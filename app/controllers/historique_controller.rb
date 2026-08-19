class HistoriqueController < ApplicationController
  def show
    @current_year = AppSetting.instance.annee_en_cours
    @produit = params[:produit]
    @noms = Array(params[:noms])
    @statuts = Array(params[:statuts])
    @ams = Array(params[:ams])
    @assureurs = Array(params[:assureurs])
    @years = params[:years].present? ? Array(params[:years]).map(&:to_i) : [@current_year]

    @query = HistoriqueQuery.new(current_year: @current_year, produit: @produit, noms: @noms,
      statuts: @statuts, ams: @ams, assureurs: @assureurs, years: @years)
    @rows = @query.rows.sort_by { |r| [r.nom, r.produit, r.annee] }

    archived_years = ArchiveEntry.where(deal_type: "ProduitDeal").distinct.pluck(:year)
    @available_years = (archived_years + [@current_year]).uniq.sort.reverse
    @archivable_years = archived_years.reject { |y| y == @current_year }.sort.reverse

    archived_noms = ArchiveEntry.where(deal_type: "ProduitDeal").distinct.pluck(:company_name)
    live_noms = Company.joins(:deals).where(deals: { type: "ProduitDeal" }).distinct.pluck(:name)
    @available_noms = (archived_noms + live_noms).uniq.sort

    @available_ams = User.active.order(:name).pluck(:name)

    sorted_years = @years.sort
    @taux_chart = @query.taux_series(sorted_years)
    @nrr_chart = @query.nrr_series(sorted_years)
    @assureur_chart = @query.assureur_chart
    @statut_donut = @query.statut_donut

    @trash_batches = TrashBatch.order(deleted_at: :desc)
  end
end
