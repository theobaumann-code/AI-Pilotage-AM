# Ports computeDealHistoryRows and its derived chart series from the original app: one row per produit
# contract-year, drawn from archived years (ArchiveEntry) plus the current, not-yet-closed year (live
# ProduitDeal records) when it's in the selected years. A row from an archived year is admin-editable
# after the fact (nothing else in the tool still holds that data); a live row is only editable from
# "Mon portefeuille".
class HistoriqueQuery
  Row = Struct.new(:id, :nom, :am, :produit, :identifiant, :assureur, :annee, :arr, :taux,
    :statut_renouvellement, :is_live, keyword_init: true) do
    def churned?
      statut_renouvellement == ProduitDeal::CHURNED
    end

    def arr_renouvele
      churned? ? nil : arr.to_f * (1 + taux.to_f / 100)
    end
  end

  STATUT_COLORS = {
    "Nouveau contrat" => "var(--primary)",
    "En cours" => "var(--amber)",
    "Augmenté" => "var(--green)",
    "Augmentation particulière" => "var(--burgundy)",
    "Churné" => "var(--red)"
  }.freeze

  def initialize(current_year:, produit: nil, noms: [], statuts: [], ams: [], assureurs: [], years: [])
    @current_year = current_year
    @produit = produit.presence
    @noms = Array(noms).reject(&:blank?)
    @statuts = Array(statuts).reject(&:blank?)
    @ams = Array(ams).reject(&:blank?)
    @assureurs = Array(assureurs).reject(&:blank?)
    @years = Array(years).map(&:to_i)
  end

  def rows
    @rows ||= (archived_rows + live_rows).sort_by { |r| [r.nom, r.produit, r.annee] }
  end

  # ARR-weighted average per produit+year, always — including with a single entreprise selected. A
  # company can hold several contracts for the same produit (different collèges and/or, since the
  # collège+assureur rule change, different assureurs too), so picking just one row's taux by
  # overwriting the others (the original app's behavior, ported and then "fixed" here once already) was
  # never correct even before that rule change; weighting degenerates cleanly to a single row's own taux
  # when there's only one.
  def taux_series(years)
    agg = Hash.new { |h, k| h[k] = {} }
    rows.each do |r|
      a = (agg[r.produit][r.annee] ||= { sum_taux_arr: 0.0, sum_arr: 0.0 })
      a[:sum_taux_arr] += r.taux.to_f * r.arr.to_f
      a[:sum_arr] += r.arr.to_f
    end
    ProduitDeal::PRODUITS.map do |p|
      points = years.map do |y|
        a = agg[p][y]
        a && a[:sum_arr] > 0 ? a[:sum_taux_arr] / a[:sum_arr] : nil
      end
      { label: p, points: points }
    end
  end

  def nrr_series(years)
    agg = Hash.new { |h, k| h[k] = {} }
    rows.each do |r|
      a = (agg[r.produit][r.annee] ||= { sum_final: 0.0, sum_initial: 0.0 })
      a[:sum_final] += (r.arr_renouvele || 0)
      a[:sum_initial] += r.arr.to_f
    end
    ProduitDeal::PRODUITS.map do |p|
      points = years.map do |y|
        a = agg[p][y]
        a && a[:sum_initial] > 0 ? a[:sum_final] / a[:sum_initial] * 100 : nil
      end
      { label: p, points: points }
    end
  end

  def assureur_chart
    agg = Hash.new { |h, k| h[k] = { sum: 0.0, count: 0 } }
    rows.each do |r|
      next unless ProduitDeal::ASSUREURS.include?(r.assureur)
      a = agg[r.assureur]
      a[:sum] += r.taux.to_f
      a[:count] += 1
    end
    ProduitDeal::ASSUREURS.map do |assureur|
      a = agg[assureur]
      { assureur: assureur, avg: a[:count] > 0 ? a[:sum] / a[:count] : nil, count: a[:count] }
    end
  end

  def statut_donut
    counts = Hash.new(0)
    rows.each { |r| counts[r.statut_renouvellement] += 1 }
    ProduitDeal::STATUTS_RENOUVELLEMENT.map { |s| { label: s, value: counts[s], color: STATUT_COLORS[s] } }
  end

  private

  def archived_rows
    scope = ArchiveEntry.where(deal_type: "ProduitDeal")
    scope = scope.where(year: @years) if @years.any?
    scope = scope.where(produit: @produit) if @produit
    scope = scope.where(company_name: @noms) if @noms.any?
    scope = scope.where(statut_renouvellement: @statuts) if @statuts.any?
    scope = scope.where(am_name: @ams) if @ams.any?
    scope = scope.where(assureur: @assureurs) if @assureurs.any?
    scope.map do |a|
      Row.new(id: a.id, nom: a.company_name, am: a.am_name, produit: a.produit, identifiant: a.identifiant,
        assureur: a.assureur, annee: a.year, arr: a.arr, taux: a.taux,
        statut_renouvellement: a.statut_renouvellement, is_live: false)
    end
  end

  def live_rows
    return [] unless @years.include?(@current_year)
    scope = ProduitDeal.includes(company: :user)
    scope = scope.where(produit: @produit) if @produit
    scope = scope.where(statut_renouvellement: @statuts) if @statuts.any?
    scope.filter_map do |d|
      next if @noms.any? && !@noms.include?(d.company.name)
      next if @ams.any? && !@ams.include?(d.company.user.name)
      next if @assureurs.any? && !@assureurs.include?(d.assureur)
      Row.new(id: d.id, nom: d.company.name, am: d.company.user.name, produit: d.produit,
        identifiant: d.identifiant, assureur: d.assureur, annee: @current_year, arr: d.arr, taux: d.taux,
        statut_renouvellement: d.statut_renouvellement, is_live: true)
    end
  end
end
