# Split out of Vue globale (which had grown too dense) — open to the same audience Vue globale itself is
# (no before_action here, matching PilotageController's own lack of one), since this is just a different
# slice of the same reporting data, not a rights-management action.
#
# The Équipe / AM filters at the top of the page narrow *every* report to the companies those AMs own (and,
# for upsells, to the upsells effectively theirs) — see #load_scope.
class AutresStatistiquesController < ApplicationController
  # The first five colors are SideCare's brand and semantic tokens; the remaining shades extend them
  # for charts with many categories while keeping enough contrast against a white card.
  PALETTE = ["#ff7b44", "#6d092a", "#3ac26e", "#ffa656", "#3a99ff", "#99536a", "#e85f2a",
             "#1f9c53", "#3f3f3f", "#b97829", "#76618f", "#2f9e8f", "#c94f4f", "#5a7d9a"].freeze

  def show
    load_scope

    # "Subi" churn (liquidation/rachat) is excluded from every stat below exactly as it is everywhere else
    # in the app — it isn't a renewal or portfolio-health outcome anyone here had control over.
    @active_deals = ProduitDeal.where(company_id: @company_ids).includes(company: :user).reject(&:churn_subi?)

    @renewal_produit = params[:renewal_produit]
    @risque_assureurs = Array(params[:risque_assureurs]).reject(&:blank?)
    @renewal_donut = renewal_donut_slices

    @arr_by_produit = arr_by(:produit, ProduitDeal::PRODUITS)
    @arr_by_assureur = arr_by(:assureur, ProduitDeal::ASSUREURS).reject { |s| s[:value].zero? }
    @concentration = portfolio_concentration
    @company_distribution = company_distribution
    @am_performance = am_performance
    @pending_forecasts = pending_forecasts
    @churn_rate_by_assureur = churn_rate_by(:assureur)
    @churn_by_risque = churn_by_risque
    @churn_reasons_by_produit = churn_reasons_by_produit
    @upsell_funnel = upsell_funnel
    @renewal_funnel = renewal_funnel
    @accompagnement_split = accompagnement_split
  end

  private

  # Équipe (role) and AM filters, same semantics as Vue globale's summary filters: a team narrows to the
  # AMs of that role, named AMs narrow further. With neither, everything is in scope (companies owned by a
  # since-deactivated user included). Lecteurs are never offered — they own nothing.
  def load_scope
    @available_roles = ["Admin", "KAM", "AM", "TL AM", "TL Customer Care"]
    @roles = Array(params[:roles]).reject(&:blank?)
    @ams = Array(params[:ams]).reject(&:blank?)
    all_ams = User.assignable.order(:name).to_a
    @available_ams = all_ams.map(&:name)

    @filter_active = @roles.present? || @ams.present?
    @scoped_ams = all_ams
    @scoped_ams = @scoped_ams.select { |am| @roles.include?(am.role_label) } if @roles.present?
    @scoped_ams = @scoped_ams.select { |am| @ams.include?(am.name) } if @ams.present?
    @scoped_user_ids = @scoped_ams.map(&:id)

    companies = Company.all
    companies = companies.where(user_id: @scoped_user_ids) if @filter_active
    @company_ids = companies.pluck(:id)
  end

  # Mirrors the original's "Nouveau contrat vs Augmentation" donut: only produit deals that were actually
  # renewed are in scope — "En cours" and "Churné" fall outside this chart entirely.
  def renewal_donut_slices
    scope = ProduitDeal.where(company_id: @company_ids)
    scope = scope.where(produit: @renewal_produit) if @renewal_produit.present?
    nouveau = scope.where(statut_renouvellement: "Nouveau contrat").count
    augmentation = scope.where(statut_renouvellement: ["Augmenté", "Augmentation particulière"]).count
    [
      { label: "Nouveau contrat", value: nouveau, color: "var(--primary)" },
      { label: "Augmentation", value: augmentation, color: "var(--burgundy)" }
    ]
  end

  # ARR répartition (currently active book only — churned deals aren't part of "what the portfolio looks
  # like today") grouped by an arbitrary field (produit or assureur), one slice per known value.
  def arr_by(field, known_values)
    active = @active_deals.reject(&:churned?)
    known_values.each_with_index.map do |value, i|
      { label: value, value: active.select { |d| d.public_send(field) == value }.sum { |d| d.arr.to_f }, color: PALETTE[i % PALETTE.size] }
    end
  end

  # Top 10 clients by current ARR and what share of the whole active book they represent — a concentration
  # read: a portfolio leaning on a handful of accounts is a different risk profile than a long tail of many.
  def portfolio_concentration
    by_company = @active_deals.reject(&:churned?).group_by(&:company)
    rows = by_company.map { |company, deals| { company: company, arr: deals.sum { |d| d.arr.to_f } } }
    total = rows.sum { |r| r[:arr] }
    top10 = rows.sort_by { |r| -r[:arr] }.first(10)
    cumulative = 0.0
    ranked = top10.map do |r|
      cumulative += r[:arr]
      { name: r[:company].name, am: r[:company].user.name, arr: r[:arr],
        pct: total > 0 ? r[:arr] / total * 100 : 0, cumulative_pct: total > 0 ? cumulative / total * 100 : 0 }
    end
    { rows: ranked, top10_pct: total > 0 ? top10.sum { |r| r[:arr] } / total * 100 : 0, total: total }
  end

  # How many companies (and how much ARR) sit in each size band, by the company's *total* active ARR across
  # all its contracts — a book of many small companies behaves very differently, operationally and
  # risk-wise, than one leaning on a few large ones.
  BUCKETS = [
    { label: "< 5 000 €", range: 0...5_000 },
    { label: "5 000 – 20 000 €", range: 5_000...20_000 },
    { label: "20 000 – 50 000 €", range: 20_000...50_000 },
    { label: "≥ 50 000 €", range: 50_000...Float::INFINITY }
  ].freeze

  def company_distribution
    totals = @active_deals.reject(&:churned?).group_by(&:company_id).values.map { |deals| deals.sum { |d| d.arr.to_f } }
    BUCKETS.map do |bucket|
      matching = totals.select { |arr| bucket[:range].cover?(arr) }
      { label: bucket[:label], value: matching.size, arr: matching.sum }
    end
  end

  # One row per AM in scope, with the figures behind "Performance par AM". NRR/upsell/renewal/churn come
  # from PortfolioSummary scoped to the AM exactly like Mon portefeuille's cards, so they match what that AM
  # sees; "% de produits renouvelés" counts produits, not ARR, over everything except suffered churn.
  # AMs with no initial ARR have no meaningful NRR and are left out.
  def am_performance
    companies_by_user = Company.where(id: @company_ids).includes(:produit_deals).group_by(&:user_id)
    @scoped_ams.filter_map do |am|
      companies = companies_by_user[am.id] || []
      summary = PortfolioSummary.new(companies, user: am)
      next if summary.arr_initial <= 0

      produits = summary.produit_deals.reject(&:churn_subi?)
      renewed = produits.count { |d| ProduitDeal::RENEWED_STATUSES.include?(d.statut_renouvellement) }
      { am: am.name, nrr: summary.nrr, nrr_actual: summary.nrr_actual,
        upsold: summary.upsold, upsold_actual: summary.upsold_actual,
        renewal_rate: summary.renewal_rate, churn_rate: summary.churn_rate,
        renewed_pct: produits.empty? ? 0 : renewed.to_f / produits.size * 100,
        renewed_count: renewed, produits_count: produits.size }
    end.sort_by { |r| -r[:nrr] }
  end

  # Per AM, the share of their produits still "En cours" at a 0% renewal rate — i.e. whose forecast hasn't
  # been updated yet — to spot who hasn't filled in their predictions. Share of produits (suffered churn set
  # aside, like "% de produits renouvelés"), with the ARR those produits carry alongside. Worst first; AMs
  # with no produit at all have nothing to update and are left out.
  def pending_forecasts
    deals_by_user = ProduitDeal.where(company_id: @company_ids).includes(:company).reject(&:churn_subi?)
      .group_by { |d| d.company.user_id }
    @scoped_ams.filter_map do |am|
      deals = deals_by_user[am.id] || []
      next if deals.empty?

      pending = deals.select(&:forecast_pending?)
      pct = pending.size.to_f / deals.size * 100
      { label: am.name, value: pct, count: pending.size, total: deals.size, arr: pending.sum { |d| d.arr.to_f },
        status: pct.zero? ? "ok" : (pct >= 50 ? "ko" : nil) }
    end.sort_by { |r| [-r[:value], -r[:count], r[:label]] }
  end

  # Why churned produits were lost (the raison filled in on Vue globale's "Produits churnés" table), one
  # slice list per produit, weighted by churned ARR — blank reasons show up as "À qualifier" so an
  # unqualified backlog is visible rather than silently missing from the chart.
  def churn_reasons_by_produit
    churned = @active_deals.select { |d| d.statut_renouvellement == ProduitDeal::CHURNED }
    reasons = [PilotageController::NOT_QUALIFIED] + ProduitDeal::CHURN_REASONS
    colors = { PilotageController::NOT_QUALIFIED => "#c9c9c9" }
    ProduitDeal::CHURN_REASONS.each_with_index { |reason, i| colors[reason] = PALETTE[i % PALETTE.size] }

    ProduitDeal::PRODUITS.index_with do |produit|
      deals = churned.select { |d| d.produit == produit }
      reasons.filter_map do |reason|
        matching = deals.select { |d| (d.churn_reason.presence || PilotageController::NOT_QUALIFIED) == reason }
        next if matching.empty?
        { label: "#{reason} (#{matching.size})", value: matching.sum { |d| d.arr.to_f }, color: colors[reason] }
      end
    end
  end

  # Churn per "risque" — the two insurance lines, Mutuelle (santé) and Prévoyance: churned ARR over the
  # line's total ARR (suffered churn set aside, like every churn rate here), plus the projected rate, i.e. the
  # churn so far plus the risk-weighted ARR of the contracts still active (as PortfolioSummary#churn_total).
  RISQUE_LABELS = { "Mutuelle" => "Mutuelle (santé)", "Prévoyance" => "Prévoyance" }.freeze

  # Narrowed by the card's own Assureur filter (on top of the page's Équipe/AM filters) when one is set.
  def churn_by_risque
    scoped = @risque_assureurs.present? ? @active_deals.select { |d| @risque_assureurs.include?(d.assureur) } : @active_deals
    ProduitDeal::PRODUITS.map do |produit|
      deals = scoped.select { |d| d.produit == produit }
      total = deals.sum { |d| d.arr.to_f }
      churned = deals.select(&:churned?).sum { |d| d.arr.to_f }
      at_risk = deals.reject(&:churned?).sum { |d| d.arr.to_f * d.risque_churn.to_f / 100 }
      rate = total > 0 ? churned / total * 100 : 0.0
      { label: RISQUE_LABELS.fetch(produit), value: rate, churned: churned, total: total,
        projected: total > 0 ? (churned + at_risk) / total * 100 : 0.0, projected_amount: churned + at_risk,
        count: deals.count(&:churned?), produits_count: deals.size,
        status: rate > PortfolioSummary::CHURN_LIMIT_PCT ? "ko" : "ok" }
    end
  end

  # Churn rate (churned ARR ÷ total ARR) per assureur — spots whether losses concentrate on a particular
  # insurer rather than spreading evenly across the book.
  def churn_rate_by(field)
    @active_deals.group_by { |d| d.public_send(field) }.filter_map do |key, deals|
      next if key.blank?
      total = deals.sum { |d| d.arr.to_f }
      next if total <= 0
      churned = deals.select(&:churned?).sum { |d| d.arr.to_f }
      { label: key, value: (churned / total * 100), status: churned > 0 ? "ko" : "ok" }
    end.sort_by { |r| -r[:value] }
  end

  # Count, montant and % of every upsell at each signature stage, in the funnel's natural order — a
  # stalled pipeline (lots of "En cours", little "Signé") reads very differently from a healthy one even
  # with the same total ARR, and the % share makes that comparison possible independent of book size.
  # In scope by effective ownership (an upsell reassigned to another AM follows that AM, as everywhere).
  def upsell_funnel
    deals = UpsellDeal.includes(:user, company: :user).to_a
    deals = deals.select { |d| @scoped_user_ids.include?(d.effective_user.id) } if @filter_active
    total = deals.size
    UpsellDeal::STATUTS_SIGNATURE.map do |statut|
      matching = deals.select { |d| d.statut_signature == statut }
      { label: statut, value: matching.size, amount: matching.sum(&:upsell_amount),
        pct: total > 0 ? matching.size.to_f / total * 100 : 0 }
    end
  end

  RENEWAL_FUNNEL_STAGES = [
    ["En cours", ["En cours"]],
    ["Renouvelé", ProduitDeal::RENEWED_STATUSES],
    ["Churné", ProduitDeal::CHURNED_STATUSES]
  ].freeze

  # Same idea as upsell_funnel but for produits à renouveler, rolled up into three stages — every status is
  # covered (both churn statuses included) rather than @active_deals' churn_subi-excluded scope, since this
  # is a "where does every deal currently stand" distribution, not an NRR-affecting calculation.
  def renewal_funnel
    deals = ProduitDeal.where(company_id: @company_ids).to_a
    total = deals.size
    RENEWAL_FUNNEL_STAGES.map do |label, statuts|
      matching = deals.select { |d| statuts.include?(d.statut_renouvellement) }
      { label: label, value: matching.size, amount: matching.sum { |d| d.arr.to_f },
        pct: total > 0 ? matching.size.to_f / total * 100 : 0 }
    end
  end

  # How much of the total book (active produits + the manually-tracked non-accompagné figure) each side
  # represents — a quick sense of scale for the business nobody individually manages. The non-accompagné
  # figure isn't tied to any AM, so it drops out as soon as an Équipe/AM filter narrows the page.
  def accompagnement_split
    accompagne = @active_deals.reject(&:churned?).sum { |d| d.arr.to_f }
    slices = [{ label: "Accompagné", value: accompagne, color: "var(--primary)" }]
    unless @filter_active
      slices << { label: "Non accompagné", value: AppSetting.instance.arr_non_accompagne.to_f, color: "var(--burgundy)" }
    end
    slices
  end
end
