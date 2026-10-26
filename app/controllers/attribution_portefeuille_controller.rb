# "Attribution portefeuille": how big each person's portfolio is, in number of accounts and ARR, and who is
# over the account ceiling - the app's version of the "CALCULS PTF" sheet (répartition + capacité). Admins only.
#
# Two views. "bi" (the default) prepares the next campaign from the BI: accounts and their AM as the BO has them
# (bi_accounts, see BiPortfolioSync), plus the unassigned accounts worth giving to an AM. "brut" is the current
# campaign as entered in the app (companies and their produits), kept as-is until it is closed into Historique.
class AttributionPortefeuilleController < ApplicationController
  before_action :require_strict_admin!

  VUES = %w[bi brut].freeze
  RISQUES = [ "Santé", "Prévoyance", "Double risque" ].freeze
  OPEN_UPSELL_STATUTS = [ "Non démarré", "En cours" ].freeze
  ROLES_ORDER = [ "KAM", "AM", "TL AM", "TL Customer Care", "Admin", "Hors outil" ].freeze

  def show
    @vue = VUES.include?(params[:vue]) ? params[:vue] : "bi"
    @annee = AppSetting.instance.annee_en_cours

    if @vue == "brut"
      @rows = brut_rows
      summarize_rows
      load_entreprises
    else
      @last_synced_at = BiAccount.last_synced_at
      @rows = bi_rows
      summarize_rows
      load_bi_entreprises
      load_sans_am
    end
  end

  # Re-reads the BI right away instead of waiting for the scheduled sync - after a batch of reassignments in the BO.
  def sync_bi
    count = BiPortfolioSync.sync!
    redirect_to attribution_portefeuille_path, notice: "Données BI synchronisées : #{count} comptes."
  rescue BigQueryClient::QueryError => error
    redirect_to attribution_portefeuille_path, alert: "Synchronisation BI impossible : #{error.message}"
  end

  private

  # Everyone who carries - or could carry - a portfolio: AMs, KAMs and team leads, plus anyone who has
  # accounts (an admin with none isn't a portfolio holder and would only inflate the capacity).
  def portfolio_holder?(user, accounts)
    user.role.in?([ :am, :kam, :tl_am, :tl_csm ]) || accounts.any?
  end

  def brut_rows
    companies_by_user = Company.includes(:produit_deals).group_by(&:user_id)
    User.assignable.order(:name).filter_map do |user|
      accounts = companies_by_user[user.id] || []
      next unless portfolio_holder?(user, accounts)

      brut_row(user, accounts)
    end
  end

  # An account is a client the person still has to look after: one whose produits aren't all churned (a client
  # without any produit yet counts). ARR is that of the produits still alive.
  def brut_row(user, companies)
    fully_churned, active = companies.partition { |c| c.produit_deals.any? && c.produit_deals.all?(&:churned?) }
    arr = active.sum { |c| c.produit_deals.reject(&:churned?).sum { |d| d.arr.to_f } }
    row(user: user, name: user.name, role: user.role_label, limit: user.account_limit,
      comptes: active.size, churned: fully_churned.size, arr: arr)
  end

  # The BO names each account's AM by their e-mail, matched to the app's users. An AM the BO knows but the app
  # doesn't (or not as an active user) still gets a row - their accounts must not silently vanish from the totals.
  def bi_rows
    accounts_by_email = BiAccount.with_am.group_by(&:am_email)
    rows = User.assignable.order(:name).filter_map do |user|
      accounts = accounts_by_email.delete(user.email.downcase) || []
      next unless portfolio_holder?(user, accounts)

      bi_row(accounts, user: user, name: user.name, role: user.role_label, limit: user.account_limit)
    end
    rows + accounts_by_email.map do |email, accounts|
      bi_row(accounts, user: nil, name: accounts.first.am_name || email, role: "Hors outil", limit: User::DEFAULT_ACCOUNT_LIMIT)
    end
  end

  # An account is one with at least one active contract; ARR is the BI's (see BiAccount).
  def bi_row(accounts, **attrs)
    active, inactive = accounts.partition(&:active?)
    row(**attrs, comptes: active.size, churned: inactive.size, arr: active.sum { |a| a.arr.to_f })
  end

  def row(user:, name:, role:, limit:, comptes:, churned:, arr:)
    { user: user, name: name, role: role, comptes: comptes, churned: churned, arr: arr,
      basket: comptes > 0 ? arr / comptes : 0.0, limit: limit, remaining: limit - comptes, over: comptes > limit }
  end

  def summarize_rows
    total_arr = @rows.sum { |r| r[:arr] }
    @rows.each { |r| r[:part] = total_arr > 0 ? r[:arr] / total_arr * 100 : 0.0 }

    @over = @rows.select { |r| r[:over] }.sort_by { |r| -r[:comptes] }
    @totals = {
      comptes: @rows.sum { |r| r[:comptes] }, arr: total_arr, people: @rows.size,
      capacity: @rows.sum { |r| r[:limit] }, churned: @rows.sum { |r| r[:churned] }
    }
    @totals[:remaining] = @totals[:capacity] - @totals[:comptes]
    @totals[:basket] = @totals[:comptes] > 0 ? total_arr / @totals[:comptes] : 0.0
    @by_role = ROLES_ORDER.filter_map do |label|
      group = @rows.select { |r| r[:role] == label }
      next if group.empty?

      { role: label, people: group.size, capacity: group.sum { |r| r[:limit] }, limit: group.first[:limit], comptes: group.sum { |r| r[:comptes] },
        arr: group.sum { |r| r[:arr] }, over: group.count { |r| r[:over] } }
    end

    @pager = TablePager.new(@rows, params: params.merge(attr_size: 100), prefix: "attr",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:name]) },
        role: ->(r) { TablePager.key(r[:role]) },
        comptes: ->(r) { TablePager.key(r[:comptes]) },
        restant: ->(r) { TablePager.key(r[:remaining]) },
        arr: ->(r) { TablePager.key(r[:arr]) },
        panier: ->(r) { TablePager.key(r[:basket]) },
        part: ->(r) { TablePager.key(r[:part]) }
      }, default_sort: :comptes, default_dir: "desc")
  end

  def read_entreprise_filters
    @ent_q = params[:ent_q].to_s.strip
    @ent_ams = Array(params[:ent_ams]).reject(&:blank?)
    @ent_risques = Array(params[:ent_risques]).reject(&:blank?)
    @ent_upsell = params[:ent_upsell].present?
  end

  # Filters by name / AM / risque / upsell, then sorts + pages. Rows carry :name, :am_name, :arr, :risque,
  # :upsell and :upsell_amount whichever view built them.
  def page_entreprises(all)
    @ent_available_ams = all.map { |r| r[:am_name] }.uniq.sort
    rows = all
    rows = rows.select { |r| r[:name].downcase.include?(@ent_q.downcase) } if @ent_q.present?
    rows = rows.select { |r| @ent_ams.include?(r[:am_name]) } if @ent_ams.present?
    rows = rows.select { |r| @ent_risques.include?(r[:risque]) } if @ent_risques.present?
    rows = rows.select { |r| r[:upsell] } if @ent_upsell
    @ent_total = { count: rows.size, arr: rows.sum { |r| r[:arr] }, upsell: rows.count { |r| r[:upsell] },
                   upsell_amount: rows.sum { |r| r[:upsell_amount] } }

    @ent_pager = TablePager.new(rows, params: params.reverse_merge("ent_size" => 50), prefix: "ent",
      sort_procs: {
        nom: ->(r) { TablePager.key(r[:name]) },
        am: ->(r) { TablePager.key(r[:am_name]) },
        arr: ->(r) { TablePager.key(r[:arr]) },
        risque: ->(r) { TablePager.key(r[:risque]) },
        upsell: ->(r) { TablePager.key(r[:upsell] ? r[:upsell_amount] : -1) }
      }, default_sort: :arr, default_dir: "desc")
  end

  # Every company, one row each: its AM, its ARR stake (produits still alive), the risk(s) it is covered for
  # and whether an upsell is still open on it.
  def load_entreprises
    read_entreprise_filters
    page_entreprises(Company.includes(:user, :produit_deals, :upsell_deals).map { |company| entreprise_row(company) })
  end

  def entreprise_row(company)
    alive = company.produit_deals.reject(&:churned?)
    produits = alive.map(&:produit).uniq
    risque = if produits.include?("Mutuelle") && produits.include?("Prévoyance") then "Double risque"
    elsif produits.include?("Mutuelle") then "Santé"
    elsif produits.include?("Prévoyance") then "Prévoyance"
    end
    open_upsells = company.upsell_deals.select { |u| OPEN_UPSELL_STATUTS.include?(u.statut_signature) }
    { company: company, name: company.name, am: company.user, am_name: company.user.name, arr: alive.sum { |d| d.arr.to_f },
      risque: risque, churned: company.produit_deals.any? && alive.empty?,
      upsell: open_upsells.any?, upsell_amount: open_upsells.sum(&:upsell_amount).to_f }
  end

  # Every BI account that has an AM, with the same follow-up data as the raw view: ARR, risk covered, and the
  # upsell opportunity - the risk it doesn't hold yet, valued on its headcount.
  def load_bi_entreprises
    read_entreprise_filters
    names = User.where(email: BiAccount.with_am.distinct.pluck(:am_email)).to_h { |u| [ u.email.downcase, u.name ] }
    page_entreprises(BiAccount.with_am.map do |account|
      { account: account, name: account.name.to_s, am_name: names[account.am_email] || account.am_name || account.am_email,
        arr: account.arr.to_f, risque: account.risque, churned: !account.active?,
        upsell: account.upsell?, upsell_produit: account.upsell_produit, upsell_amount: account.upsell_amount }
    end)
  end

  def load_sans_am
    @sam_q = params[:sam_q].to_s.strip
    all = BiAccount.sans_am.to_a
    @sam_all_total = { count: all.size, arr: all.sum { |a| a.arr.to_f } }
    rows = @sam_q.present? ? all.select { |a| a.name.to_s.downcase.include?(@sam_q.downcase) } : all
    @sam_total = { count: rows.size, arr: rows.sum { |a| a.arr.to_f } }

    @sam_pager = TablePager.new(rows, params: params.reverse_merge("sam_size" => 50), prefix: "sam",
      sort_procs: {
        nom: ->(a) { TablePager.key(a.name) },
        type: ->(a) { TablePager.key(a.kind_label) },
        arr: ->(a) { TablePager.key(a.arr.to_f) },
        risque: ->(a) { TablePager.key(a.risque) },
        nombre_salaries: ->(a) { TablePager.key(a.employees_count) }
      }, default_sort: :arr, default_dir: "desc")
  end
end
