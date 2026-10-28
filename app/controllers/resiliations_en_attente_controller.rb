# Temporary "Suivi des résiliations" rubric, to be removed with BiPendingTermination: every produit flagged
# "A résilier" or renewed as a "Nouveau contrat", with the latest 2026 BO termination on the same company, risk and
# collège (BiPendingTermination.latest_for) and its status. Admins only.
class ResiliationsEnAttenteController < ApplicationController
  NONE = "Aucune résiliation 2026 en cours".freeze

  before_action :require_strict_admin!

  def show
    @last_synced_at = BiPendingTermination.last_synced_at
    deals = ProduitDeal.includes(company: :user)
      .where("deals.a_resilier OR deals.statut_renouvellement = ?", "Nouveau contrat").to_a
    latest = BiPendingTermination.latest_for(deals)
    all = deals.map { |d| { deal: d, termination: latest[d.id] } }
    @all_total = totals(all)

    @q = params[:q].to_s.strip
    @roles = Array(params[:roles]).reject(&:blank?)
    @ams = Array(params[:ams]).reject(&:blank?)
    @risques = Array(params[:risques]).reject(&:blank?)
    @statuts = Array(params[:statuts]).reject(&:blank?)
    @role_options = [ "Admin", "KAM", "AM" ]
    @am_options = all.map { |r| r[:deal].company.user.name }.uniq.sort
    @risque_options = all.map { |r| r[:deal].produit }.uniq.sort
    @statut_options = all.map { |r| statut(r) }.uniq.sort

    rows = all
    if @q.present?
      needle = @q.downcase
      rows = rows.select { |r| [ r[:deal].company.name, r[:termination]&.name ].any? { |s| s.to_s.downcase.include?(needle) } }
    end
    # Équipe as in Vue globale: the AM's team (the team leads sit with the AMs).
    rows = rows.select { |r| @roles.include?(r[:deal].company.user.team_label) } if @roles.present?
    rows = rows.select { |r| @ams.include?(r[:deal].company.user.name) } if @ams.present?
    rows = rows.select { |r| @risques.include?(r[:deal].produit) } if @risques.present?
    rows = rows.select { |r| @statuts.include?(statut(r)) } if @statuts.present?
    @total = totals(rows)

    @pager = TablePager.new(rows, params: params.reverse_merge("rs_size" => 50), prefix: "rs",
      sort_procs: {
        client: ->(r) { TablePager.key(r[:deal].company.name) },
        am: ->(r) { TablePager.key(r[:deal].company.user.name) },
        risque: ->(r) { TablePager.key(r[:deal].produit) },
        college: ->(r) { TablePager.key(r[:deal].college) },
        arr: ->(r) { TablePager.key(r[:deal].arr.to_f) },
        statut: ->(r) { TablePager.key(statut(r)) },
        cree_le: ->(r) { TablePager.key(r[:termination]&.created_on) },
        date_effet: ->(r) { TablePager.key(r[:termination]&.termination_date) }
      }, default_sort: :client, default_dir: "asc")
  end

  # "Actualiser depuis le BO": re-reads the terminations straight away, back on the page with its filters.
  def sync
    count = BiPendingTerminationSync.sync!
    redirect_back_or_to resiliations_en_attente_path, notice: "Données BO actualisées : #{count} résiliations 2026."
  rescue BigQueryClient::QueryError => error
    redirect_back_or_to resiliations_en_attente_path, alert: "Actualisation impossible : #{error.message}"
  end

  private

  def statut(row)
    row[:termination]&.status_label || NONE
  end

  def totals(rows)
    with = rows.count { |r| r[:termination] }
    { count: rows.size, with_termination: with, without_termination: rows.size - with,
      arr: rows.sum { |r| r[:deal].arr.to_f } }
  end
end
