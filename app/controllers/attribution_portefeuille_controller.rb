# "Attribution portefeuille": how big each person's portfolio is, in number of accounts and ARR, and who is
# over the account ceiling — the app's version of the "CALCULS PTF" sheet (répartition + capacité). Admins only.
class AttributionPortefeuilleController < ApplicationController
  before_action :require_strict_admin!

  # Maximum number of accounts one person can carry (the sheet's "Portefeuille max" for an AM).
  ACCOUNT_LIMIT = 54

  def show
    @limit = ACCOUNT_LIMIT
    companies_by_user = Company.includes(:produit_deals).group_by(&:user_id)

    # Everyone who carries — or could carry — a portfolio: AMs and KAMs, plus anyone who has accounts
    # (an admin with none isn't a portfolio holder and would only inflate the capacity).
    @rows = User.assignable.order(:name).filter_map do |user|
      accounts = companies_by_user[user.id] || []
      next unless user.role.in?([:am, :kam]) || accounts.any?

      build_row(user, accounts)
    end

    total_arr = @rows.sum { |r| r[:arr] }
    @rows.each { |r| r[:part] = total_arr > 0 ? r[:arr] / total_arr * 100 : 0.0 }

    @over = @rows.select { |r| r[:over] }.sort_by { |r| -r[:comptes] }
    @totals = {
      comptes: @rows.sum { |r| r[:comptes] }, arr: total_arr, people: @rows.size,
      capacity: @rows.size * @limit, churned: @rows.sum { |r| r[:churned] }
    }
    @totals[:remaining] = @totals[:capacity] - @totals[:comptes]
    @totals[:basket] = @totals[:comptes] > 0 ? total_arr / @totals[:comptes] : 0.0
    @by_role = %w[KAM AM Admin].filter_map do |label|
      group = @rows.select { |r| r[:role] == label }
      next if group.empty?

      { role: label, people: group.size, capacity: group.size * @limit, comptes: group.sum { |r| r[:comptes] },
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
  end

  private

  # An account is a client the person still has to look after: one whose produits aren't all churned (a client
  # without any produit yet counts). ARR is that of the produits still alive.
  def build_row(user, companies)
    fully_churned, active = companies.partition { |c| c.produit_deals.any? && c.produit_deals.all?(&:churned?) }
    arr = active.sum { |c| c.produit_deals.reject(&:churned?).sum { |d| d.arr.to_f } }
    comptes = active.size
    { user: user, role: user.role_label, comptes: comptes, churned: fully_churned.size, arr: arr,
      basket: comptes > 0 ? arr / comptes : 0.0, remaining: @limit - comptes, over: comptes > @limit }
  end
end
