# The AM roster and role-management actions used to live on Vue globale — split out because that page had
# grown too dense. Gated to whoever can add an AM in the first place (current_user.privileged?, via
# require_admin! despite its name — see ApplicationController), since everything here is a rights-editing
# action, not a reporting view.
class GestionDroitsController < ApplicationController
  before_action :require_admin!

  def show
    @active_ams = User.active.order(:name)
    # produit_deals is a separate has_many association from :deals (its own `type` scope), so
    # `includes(:deals)` wouldn't preload it — every PortfolioSummary#count/arr_initial/etc. call below
    # would otherwise issue its own query per AM (see PilotageController for the same fix, same reason).
    @am_rows = @active_ams.map do |am|
      { am: am, summary: PortfolioSummary.new(am.companies.includes(:produit_deals), user: am) }
    end

    @am_q = params[:am_q].to_s.strip
    am_rows_filtered = @am_rows
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
  end
end
