# "Attribution portefeuille": how big each person's portfolio is, in number of accounts and ARR, and who is
# over the account ceiling — the app's version of the "CALCULS PTF" sheet (répartition + capacité). Admins only.
class AttributionPortefeuilleController < ApplicationController
  before_action :require_strict_admin!

  def show
    companies_by_user = Company.includes(:produit_deals).group_by(&:user_id)

    # Everyone who carries — or could carry — a portfolio: AMs, KAMs and team leads, plus anyone who has
    # accounts (an admin with none isn't a portfolio holder and would only inflate the capacity).
    @rows = User.assignable.order(:name).filter_map do |user|
      accounts = companies_by_user[user.id] || []
      next unless user.role.in?([:am, :kam, :tl_am, :tl_csm]) || accounts.any?

      build_row(user, accounts)
    end

    total_arr = @rows.sum { |r| r[:arr] }
    @rows.each { |r| r[:part] = total_arr > 0 ? r[:arr] / total_arr * 100 : 0.0 }

    @over = @rows.select { |r| r[:over] }.sort_by { |r| -r[:comptes] }
    @totals = {
      comptes: @rows.sum { |r| r[:comptes] }, arr: total_arr, people: @rows.size,
      capacity: @rows.sum { |r| r[:limit] }, churned: @rows.sum { |r| r[:churned] }
    }
    @totals[:remaining] = @totals[:capacity] - @totals[:comptes]
    @totals[:basket] = @totals[:comptes] > 0 ? total_arr / @totals[:comptes] : 0.0
    @by_role = ["KAM", "AM", "TL AM", "TL Customer Care", "Admin"].filter_map do |label|
      group = @rows.select { |r| r[:role] == label }
      next if group.empty?

      { role: label, people: group.size, capacity: group.sum { |r| r[:limit] }, limit: group.first[:limit], comptes: group.sum { |r| r[:comptes] },
        arr: group.sum { |r| r[:arr] }, over: group.count { |r| r[:over] } }
    end

    @pager = TablePager.new(@rows, params: params.merge(attr_size: 100), prefix: "attr",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:user].name) },
        role: ->(r) { TablePager.key(r[:role]) },
        comptes: ->(r) { TablePager.key(r[:comptes]) },
        restant: ->(r) { TablePager.key(r[:remaining]) },
        arr: ->(r) { TablePager.key(r[:arr]) },
        panier: ->(r) { TablePager.key(r[:basket]) },
        part: ->(r) { TablePager.key(r[:part]) }
      }, default_sort: :comptes, default_dir: "desc")

    load_entreprises
  end

  RISQUES = ["Santé", "Prévoyance", "Double risque"].freeze
  OPEN_UPSELL_STATUTS = ["Non démarré", "En cours"].freeze

  private

  # Every company, one row each: its AM, its ARR stake (produits still alive), the risk(s) it is covered for
  # and whether an upsell is still open on it. Filterable by name / AM / risque / upsell, then sorted + paged.
  def load_entreprises
    @ent_q = params[:ent_q].to_s.strip
    @ent_ams = Array(params[:ent_ams]).reject(&:blank?)
    @ent_risques = Array(params[:ent_risques]).reject(&:blank?)
    @ent_upsell = params[:ent_upsell].present?

    all = Company.includes(:user, :produit_deals, :upsell_deals).map { |company| entreprise_row(company) }
    @ent_available_ams = all.map { |r| r[:am].name }.uniq.sort
    rows = all
    rows = rows.select { |r| r[:company].name.downcase.include?(@ent_q.downcase) } if @ent_q.present?
    rows = rows.select { |r| @ent_ams.include?(r[:am].name) } if @ent_ams.present?
    rows = rows.select { |r| @ent_risques.include?(r[:risque]) } if @ent_risques.present?
    rows = rows.select { |r| r[:upsell] } if @ent_upsell
    @ent_total = { count: rows.size, arr: rows.sum { |r| r[:arr] }, upsell: rows.count { |r| r[:upsell] },
                   upsell_amount: rows.sum { |r| r[:upsell_amount] } }

    @ent_pager = TablePager.new(rows, params: params.reverse_merge("ent_size" => 50), prefix: "ent",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:company].name) },
        am: ->(r) { TablePager.key(r[:am].name) },
        arr: ->(r) { TablePager.key(r[:arr]) },
        risque: ->(r) { TablePager.key(r[:risque]) },
        upsell: ->(r) { TablePager.key(r[:upsell] ? r[:upsell_amount] : -1) }
      }, default_sort: :arr, default_dir: "desc")
  end

  def entreprise_row(company)
    alive = company.produit_deals.reject(&:churned?)
    produits = alive.map(&:produit).uniq
    risque = if produits.include?("Mutuelle") && produits.include?("Prévoyance") then "Double risque"
    elsif produits.include?("Mutuelle") then "Santé"
    elsif produits.include?("Prévoyance") then "Prévoyance"
    end
    open_upsells = company.upsell_deals.select { |u| OPEN_UPSELL_STATUTS.include?(u.statut_signature) }
    { company: company, am: company.user, arr: alive.sum { |d| d.arr.to_f }, risque: risque,
      churned: company.produit_deals.any? && alive.empty?,
      upsell: open_upsells.any?, upsell_amount: open_upsells.sum(&:upsell_amount).to_f }
  end

  # An account is a client the person still has to look after: one whose produits aren't all churned (a client
  # without any produit yet counts). ARR is that of the produits still alive.
  def build_row(user, companies)
    fully_churned, active = companies.partition { |c| c.produit_deals.any? && c.produit_deals.all?(&:churned?) }
    arr = active.sum { |c| c.produit_deals.reject(&:churned?).sum { |d| d.arr.to_f } }
    comptes = active.size
    { user: user, role: user.role_label, comptes: comptes, churned: fully_churned.size, arr: arr,
      basket: comptes > 0 ? arr / comptes : 0.0, limit: user.account_limit, remaining: user.account_limit - comptes, over: comptes > user.account_limit }
  end
end
