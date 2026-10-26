require "csv"

# "Projection portefeuille": next campaign's portfolios, starting from the BI's real assignment, with temporary
# what-ifs on top - AMs leaving, fictitious recruits, accounts moved in bulk (see PortfolioProjection). Admins only,
# like "Attribution portefeuille". Fully separate from every other page: nothing here changes the BO or any KPI.
class ProjectionPortefeuilleController < ApplicationController
  before_action :require_strict_admin!

  # Query params kept across a bulk action, so the page comes back with the same filters / sort / page.
  KEPT_PARAMS = %w[pc_q pc_owners pc_owners_open pc_bo pc_bo_open pc_modified pc_sort pc_dir pc_page pc_size
                   ps_q ps_sort ps_dir ps_page ps_size].freeze

  def show
    @annee = AppSetting.instance.annee_en_cours
    @last_synced_at = BiAccount.last_synced_at
    @projection = PortfolioProjection.new
    load_rows
    load_comptes
    load_sans_am
  end

  def bulk
    projection = PortfolioProjection.new
    keys = if params[:all_filtered] == "1"
      (params[:table] == "sans_am" ? filtered_sans_am(projection) : filtered_comptes(projection)).map(&:account_key)
    else
      Array(params[:keys])
    end
    result = projection.apply!(keys, action: params[:bulk_action].to_s, target: params[:target].presence, by: current_user)
    notice = "#{result[:done]} compte#{"s" if result[:done] > 1} mis à jour dans la projection."
    if result[:skipped] > 0
      notice += " #{result[:skipped]} ignoré#{"s" if result[:skipped] > 1} (un compte sans AM dans le BO ne peut pas aller à une recrue ni être mis en réserve)."
    end
    redirect_to back_path(params[:table]), notice: notice
  rescue PortfolioProjection::Error => error
    redirect_to back_path(params[:table]), alert: error.message
  end

  def toggle_departure
    user = User.assignable.find(params[:user_id])
    departure = Projection::Departure.find_by(user: user)
    if departure
      departure.destroy!
      notice = "#{user.name} reste dans la projection : ses comptes du BO lui reviennent."
    else
      Projection::Departure.create!(user: user)
      notice = "#{user.name} est sortant(e) : ses comptes passent dans « À réattribuer »."
    end
    redirect_to back_path("equipe"), notice: notice
  end

  def create_recruit
    recruit = Projection::Recruit.new(name: params[:name], role: params[:role])
    if recruit.save
      redirect_to back_path("equipe"), notice: "#{recruit.name} ajouté(e) à la projection."
    else
      redirect_to back_path("equipe"), alert: recruit.errors.full_messages.to_sentence
    end
  end

  def destroy_recruit
    recruit = Projection::Recruit.find(params[:recruit_id])
    recruit.destroy!
    redirect_to back_path("equipe"), notice: "#{recruit.name} retiré(e) : ses comptes reviennent à leur AM du BO."
  end

  # Starts the projection over from the BO: every departure, recruit and move is dropped.
  def destroy
    Projection::Move.delete_all
    Projection::Departure.delete_all
    Projection::Recruit.delete_all
    redirect_to projection_portefeuille_path, notice: "Projection réinitialisée : elle reprend l'attribution du BO."
  end

  # The "plan de mouvements": every account whose projected holder differs from the BO - what to enter in the BO
  # once the projection is decided.
  def export
    projection = PortfolioProjection.new
    csv = CSV.generate(col_sep: ";") do |out|
      out << [ "Compte", "Type", "SIREN", "AM dans le BO", "AM projeté", "Mouvement", "Statut", "ARR (€)", "Risque couvert" ]
      projection.tracked_entries.select(&:moved?).sort_by { |e| [ projection.label(e.bo_key), e.account.name.to_s ] }.each do |e|
        out << [ e.account.name, e.account.kind_label, e.account.siren, projection.label(e.bo_key), projection.label(e.key),
                 movement_label(e), status_label(e), e.account.arr.to_f.round(2), e.account.risque ]
      end
    end
    send_data "\xEF\xBB\xBF" + csv, filename: "plan-mouvements-projection-#{Date.current.iso8601}.csv", type: "text/csv; charset=utf-8"
  end

  helper_method :movement_label, :status_label

  def movement_label(entry)
    case entry.key
    when PortfolioProjection::RESERVE
      entry.move ? "Retiré à l'AM" : "AM sortant"
    when PortfolioProjection::DROP then "Plus accompagné"
    else entry.bo_key == PortfolioProjection::NONE ? "Attribué (était sans AM)" : "Réattribué"
    end
  end

  STATUS_LABELS = { applied: "Fait dans le BO", conflict: "Le BO a changé depuis", pending: "À faire dans le BO" }.freeze

  def status_label(entry)
    entry.move ? STATUS_LABELS.fetch(entry.status) : "À faire dans le BO"
  end

  private

  def back_path(anchor)
    kept = params.permit(KEPT_PARAMS.map(&:to_sym), pc_owners: [], pc_bo: []).to_h.symbolize_keys
    projection_portefeuille_path(**kept, anchor: anchor)
  end

  def load_rows
    @rows = @projection.rows
    total_arr = @rows.sum { |r| r[:arr] }
    @rows.each { |r| r[:part] = total_arr > 0 ? r[:arr] / total_arr * 100 : 0.0 }
    @over = @rows.select { |r| r[:over] }
    @totals = {
      real_comptes: @rows.sum { |r| r[:real_comptes] }, real_arr: @rows.sum { |r| r[:real_arr] },
      comptes: @rows.sum { |r| r[:comptes] }, arr: total_arr, capacity: @rows.sum { |r| r[:limit] }
    }
    @totals[:remaining] = @totals[:capacity] - @totals[:comptes]
    @reserve = @projection.place_total(PortfolioProjection::RESERVE)
    @dropped = @projection.place_total(PortfolioProjection::DROP)
    @moved_count = @projection.tracked_entries.count(&:moved?)

    @pager = TablePager.new(@rows, params: params.merge(proj_size: 100), prefix: "proj",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:holder].name) },
        role: ->(r) { TablePager.key(r[:holder].role) },
        comptes: ->(r) { TablePager.key(r[:comptes]) },
        restant: ->(r) { TablePager.key(r[:remaining]) },
        arr: ->(r) { TablePager.key(r[:arr]) },
        part: ->(r) { TablePager.key(r[:part]) }
      }, default_sort: :comptes, default_dir: "desc")
  end

  def read_comptes_filters
    @pc_q = params[:pc_q].to_s.strip
    @pc_owners = Array(params[:pc_owners]).reject(&:blank?)
    @pc_bo = Array(params[:pc_bo]).reject(&:blank?)
    @pc_modified = params[:pc_modified].present?
  end

  def filtered_comptes(projection)
    read_comptes_filters
    rows = projection.tracked_entries
    rows = rows.select { |e| e.account.name.to_s.downcase.include?(@pc_q.downcase) } if @pc_q.present?
    rows = rows.select { |e| @pc_owners.include?(projection.label(e.key)) } if @pc_owners.present?
    rows = rows.select { |e| @pc_bo.include?(projection.label(e.bo_key)) } if @pc_bo.present?
    rows = rows.select(&:moved?) if @pc_modified
    rows
  end

  def load_comptes
    all = @projection.tracked_entries
    @pc_owner_options = all.map { |e| @projection.label(e.key) }.uniq.sort
    @pc_bo_options = all.map { |e| @projection.label(e.bo_key) }.uniq.sort
    rows = filtered_comptes(@projection)
    @pc_total = { count: rows.size, arr: rows.sum { |e| e.account.arr.to_f } }
    @pc_pager = TablePager.new(rows, params: params.reverse_merge("pc_size" => 50), prefix: "pc",
      sort_procs: {
        nom: ->(e) { TablePager.key(e.account.name) },
        am: ->(e) { TablePager.key(@projection.label(e.key)) },
        bo: ->(e) { TablePager.key(@projection.label(e.bo_key)) },
        arr: ->(e) { TablePager.key(e.account.arr.to_f) }
      }, default_sort: :arr, default_dir: "desc")
    @targets = @projection.assignable_holders
  end

  def filtered_sans_am(projection)
    @ps_q = params[:ps_q].to_s.strip
    rows = projection.sans_am_entries
    rows = rows.select { |e| e.account.name.to_s.downcase.include?(@ps_q.downcase) } if @ps_q.present?
    rows
  end

  def load_sans_am
    rows = filtered_sans_am(@projection)
    @ps_total = { count: rows.size, arr: rows.sum { |e| e.account.arr.to_f } }
    @ps_pager = TablePager.new(rows, params: params.reverse_merge("ps_size" => 50), prefix: "ps",
      sort_procs: {
        nom: ->(e) { TablePager.key(e.account.name) },
        arr: ->(e) { TablePager.key(e.account.arr.to_f) }
      }, default_sort: :arr, default_dir: "desc")
    @sans_am_targets = @projection.assignable_holders(recruits: false)
  end
end
