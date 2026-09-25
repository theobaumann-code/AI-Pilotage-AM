# Split out of Vue globale (which had grown too dense) — open to the same audience Vue globale itself is
# (no before_action here, matching PilotageController's own lack of one), since this is just a different
# slice of the same reporting data, not a rights-management action.
class AutresStatistiquesController < ApplicationController
  PALETTE = ["#ff7b44", "#6d092a", "#1fa25e", "#b8720a", "#7c6b63", "#3b6fb6", "#a63d8f",
             "#2f9e8f", "#c94f4f", "#8a6bd1", "#d4a017", "#4f8a8b", "#b85c8a", "#5a7d9a"].freeze

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
    @churn_rate_by_college = churn_rate_by(:college)
    @upsell_funnel = upsell_funnel
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

  # Churn rate (churned ARR ÷ total ARR) per assureur or collège — spots whether losses concentrate on a
  # particular insurer or population segment rather than spreading evenly across the book.
  def churn_rate_by(field)
    @active_deals.group_by { |d| d.public_send(field) }.filter_map do |key, deals|
      next if key.blank?
      total = deals.sum { |d| d.arr.to_f }
      next if total <= 0
      churned = deals.select(&:churned?).sum { |d| d.arr.to_f }
      { label: key, value: (churned / total * 100), status: churned > 0 ? "ko" : "ok" }
    end.sort_by { |r| -r[:value] }
  end

  # Count and montant at each signature stage, in the funnel's natural order — a stalled pipeline (lots of
  # "En cours", little "Signé") reads very differently from a healthy one even with the same total ARR.
  def upsell_funnel
    deals = UpsellDeal.all.to_a
    UpsellDeal::STATUTS_SIGNATURE.map do |statut|
      matching = deals.select { |d| d.statut_signature == statut }
      { label: statut, value: matching.size, amount: matching.sum(&:upsell_amount) }
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
