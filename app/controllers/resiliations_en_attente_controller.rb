# Temporary "Résiliations en attente" rubric, to be removed with BiPendingTermination: every BO contract termination
# waiting for the client's signature on an account that has an AM / KAM in the BO. Admins only.
class ResiliationsEnAttenteController < ApplicationController
  before_action :require_strict_admin!

  def show
    @last_synced_at = BiPendingTermination.last_synced_at
    all = BiPendingTermination.with_accounts.select { |_, account| account&.am_email.present? }
      .map { |t, account| { termination: t, account: account } }
    @all_total = totals(all)

    @q = params[:q].to_s.strip
    @ams = Array(params[:ams]).reject(&:blank?)
    @types = Array(params[:types]).reject(&:blank?)
    @products = Array(params[:products]).reject(&:blank?)
    @am_options = all.map { |r| r[:account].am_name.presence || r[:account].am_email }.uniq.sort
    @type_options = all.map { |r| r[:termination].type_label }.uniq.sort
    @product_options = all.map { |r| r[:termination].product_label }.uniq.sort

    rows = all
    if @q.present?
      needle = @q.downcase
      rows = rows.select { |r| [ r[:termination].social_name, r[:termination].name, r[:account].name ].any? { |s| s.to_s.downcase.include?(needle) } }
    end
    rows = rows.select { |r| @ams.include?(r[:account].am_name.presence || r[:account].am_email) } if @ams.present?
    rows = rows.select { |r| @types.include?(r[:termination].type_label) } if @types.present?
    rows = rows.select { |r| @products.include?(r[:termination].product_label) } if @products.present?
    @total = totals(rows)

    @pager = TablePager.new(rows, params: params.reverse_merge("rs_size" => 50), prefix: "rs",
      sort_procs: {
        client: ->(r) { TablePager.key(r[:termination].social_name) },
        compte: ->(r) { TablePager.key(r[:account].name) },
        am: ->(r) { TablePager.key(r[:account].am_name) },
        type: ->(r) { TablePager.key(r[:termination].type_label) },
        produit: ->(r) { TablePager.key(r[:termination].product_label) },
        cree_le: ->(r) { TablePager.key(r[:termination].created_on) },
        date_effet: ->(r) { TablePager.key(r[:termination].termination_date) },
        arr: ->(r) { TablePager.key(r[:termination].contract_arr.to_f) },
        arr_compte: ->(r) { TablePager.key(r[:account].arr.to_f) }
      }, default_sort: :cree_le, default_dir: "desc")
  end

  def sync
    count = BiPendingTerminationSync.sync!
    redirect_to resiliations_en_attente_path, notice: "Données BI synchronisées : #{count} résiliations en attente."
  rescue BigQueryClient::QueryError => error
    redirect_to resiliations_en_attente_path, alert: "Synchronisation BI impossible : #{error.message}"
  end

  private

  def totals(rows)
    { count: rows.size, accounts: rows.map { |r| r[:account].id }.uniq.size,
      arr: rows.sum { |r| r[:termination].contract_arr.to_f } }
  end
end
