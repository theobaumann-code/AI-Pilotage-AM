# Split out of Vue globale (which had grown too dense) — open to the same audience Vue globale itself is
# (no before_action here, matching PilotageController's own lack of one), since this is just a different
# slice of the same reporting data, not a rights-management action.
class AutresStatistiquesController < ApplicationController
  # The first five colors are SideCare's brand and semantic tokens; the remaining shades extend them
  # for charts with many categories while keeping enough contrast against a white card.
  PALETTE = ["#ff7b44", "#6d092a", "#3ac26e", "#ffa656", "#3a99ff", "#99536a", "#e85f2a",
             "#1f9c53", "#3f3f3f", "#b97829", "#76618f", "#2f9e8f", "#c94f4f", "#5a7d9a"].freeze

  def show
    # "Subi" churn (liquidation/rachat) is excluded from every stat below exactly as it is everywhere else
    # in the app — it isn't a renewal or portfolio-health outcome anyone here had control over.
    @active_deals = ProduitDeal.includes(company: :user).reject(&:churn_subi?)

    @renewal_am_id = params[:renewal_am_id]
    @renewal_produit = params[:renewal_produit]
    @renewal_donut = renewal_donut_slices

    @arr_by_produit = arr_by(:produit, ProduitDeal::PRODUITS)
    @arr_by_assureur = arr_by(:assureur, ProduitDeal::ASSUREURS)
    @concentration = portfolio_concentration
    @contract_size_buckets = contract_size_distribution
    @nrr_by_year = nrr_by_year
    @churn_by_year = churn_by_year
    @churn_rate_by_assureur = churn_rate_by(:assureur)
    @nrr_by_am = nrr_by_am
    @churn_reasons_by_produit = churn_reasons_by_produit
    @upsell_funnel = upsell_funnel
    @renewal_funnel = renewal_funnel
    @accompagnement_split = accompagnement_split
  end

  private

  # Mirrors the original's "Nouveau contrat vs Augmentation" donut: only produit deals that were actually
  # renewed are in scope — "En cours" and "Churné" fall outside this chart entirely.
  def renewal_donut_slices
    scope = ProduitDeal.joins(:company)
    scope = scope.where(companies: { user_id: @renewal_am_id }) if @renewal_am_id.present?
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

  # How many (and how much ARR) each contract carries — a book of many small contracts behaves very
  # differently, operationally and risk-wise, than one leaning on a few large ones.
  BUCKETS = [
    { label: "< 5 000 €", range: 0...5_000 },
    { label: "5 000 – 20 000 €", range: 5_000...20_000 },
    { label: "20 000 – 50 000 €", range: 20_000...50_000 },
    { label: "≥ 50 000 €", range: 50_000...Float::INFINITY }
  ].freeze

  def contract_size_distribution
    active = @active_deals.reject(&:churned?)
    BUCKETS.map do |bucket|
      matching = active.select { |d| bucket[:range].cover?(d.arr.to_f) }
      { label: bucket[:label], value: matching.sum { |d| d.arr.to_f }, count: matching.size }
    end
  end

  # One NRR% point per year (archived years via ArchiveEntry, the current year live), all produits and AMs
  # combined — reuses HistoriqueQuery::Row (churned?/arr_renouvele/churn_subi?) so this stays consistent
  # with the Historique page's own per-produit series instead of re-deriving the same rules twice.
  def nrr_by_year
    current_year = AppSetting.instance.annee_en_cours
    years = (ArchiveEntry.distinct.pluck(:year) + [current_year]).uniq.sort
    rows = HistoriqueQuery.new(current_year: current_year, years: years).rows.reject(&:churn_subi?)
    by_year = rows.group_by(&:annee)
    points = years.map do |y|
      year_rows = by_year[y] || []
      initial = year_rows.sum { |r| r.arr.to_f }
      final = year_rows.sum { |r| r.arr_renouvele || 0 }
      initial > 0 ? final / initial * 100 : nil
    end
    { years: years, points: points }
  end

  # Same year range, but splitting churned ARR into "classique" (lost to competition/dissatisfaction) vs
  # "subi" (liquidation/rachat) — whether the uncontrollable share is growing is its own signal.
  def churn_by_year
    current_year = AppSetting.instance.annee_en_cours
    years = (ArchiveEntry.distinct.pluck(:year) + [current_year]).uniq.sort
    rows = HistoriqueQuery.new(current_year: current_year, years: years).rows
    by_year = rows.group_by(&:annee)
    years.map do |y|
      year_rows = by_year[y] || []
      classique = year_rows.select { |r| r.statut_renouvellement == ProduitDeal::CHURNED }.sum { |r| r.arr.to_f }
      subi = year_rows.select(&:churn_subi?).sum { |r| r.arr.to_f }
      { year: y, classique: classique, subi: subi }
    end
  end

  # Each active AM's own NRR (actuel and projeté), built exactly like Mon portefeuille's summary cards
  # (PortfolioSummary scoped to the AM) so the figures match what that AM sees. AMs with no initial ARR have
  # no meaningful NRR and are left out.
  def nrr_by_am
    companies_by_user = Company.includes(:produit_deals).group_by(&:user_id)
    User.active.order(:name).filter_map do |am|
      summary = PortfolioSummary.new(companies_by_user[am.id] || [], user: am)
      next if summary.arr_initial <= 0
      { am: am.name, nrr: summary.nrr, nrr_actual: summary.nrr_actual }
    end.sort_by { |r| -r[:nrr] }
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

  # Count, montant and % of every upsell at each signature stage, in the funnel's natural order — a
  # stalled pipeline (lots of "En cours", little "Signé") reads very differently from a healthy one even
  # with the same total ARR, and the % share makes that comparison possible independent of book size.
  def upsell_funnel
    deals = UpsellDeal.all.to_a
    total = deals.size
    UpsellDeal::STATUTS_SIGNATURE.map do |statut|
      matching = deals.select { |d| d.statut_signature == statut }
      { label: statut, value: matching.size, amount: matching.sum(&:upsell_amount),
        pct: total > 0 ? matching.size.to_f / total * 100 : 0 }
    end
  end

  RENEWAL_FUNNEL_STAGES = [
    ["En cours", ["En cours"]],
    ["Renouvelé", ["Augmenté", "Augmentation particulière", "Nouveau contrat"]],
    ["Churné", ProduitDeal::CHURNED_STATUSES]
  ].freeze

  # Same idea as upsell_funnel but for produits à renouveler, rolled up into three stages — every status is
  # covered (both churn statuses included) rather than @active_deals' churn_subi-excluded scope, since this
  # is a "where does every deal currently stand" distribution, not an NRR-affecting calculation.
  def renewal_funnel
    deals = ProduitDeal.all.to_a
    total = deals.size
    RENEWAL_FUNNEL_STAGES.map do |label, statuts|
      matching = deals.select { |d| statuts.include?(d.statut_renouvellement) }
      { label: label, value: matching.size, amount: matching.sum { |d| d.arr.to_f },
        pct: total > 0 ? matching.size.to_f / total * 100 : 0 }
    end
  end

  # How much of the total book (active produits + the manually-tracked non-accompagné figure) each side
  # represents — a quick sense of scale for the business nobody individually manages.
  def accompagnement_split
    accompagne = @active_deals.reject(&:churned?).sum { |d| d.arr.to_f }
    non_accompagne = AppSetting.instance.arr_non_accompagne.to_f
    [
      { label: "Accompagné", value: accompagne, color: "var(--primary)" },
      { label: "Non accompagné", value: non_accompagne, color: "var(--burgundy)" }
    ]
  end
end
