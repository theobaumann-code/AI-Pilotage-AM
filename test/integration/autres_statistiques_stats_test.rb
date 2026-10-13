require "test_helper"

# Every stat on "Autres statistiques" excludes "subi" churn (liquidation/rachat) the same way the rest of
# the app does — these are the correctness checks for that, plus a spot-check on the trickier aggregations
# (concentration, contract-size buckets, churn rate by segment).
class AutresStatistiquesStatsTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "am-stats@example.com", name: "AM Stats", admin: false, active: true)
    sign_in @am
  end

  test "ARR répartition by produit excludes churned and churn subi deals" do
    company = Company.create!(name: "Client Stats Produit", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "st-1",
      college: "Cadre", assureur: "AXA", arr: 40_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "st-2",
      college: "Non cadre", assureur: "AXA", arr: 9_000, taux: 0, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "st-3",
      college: "Cadre", assureur: "AXA", arr: 5_000, taux: 0, statut_renouvellement: "Churné (subi)")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Répartition de l'ARR par produit.*?Total/m]
    assert_match "40,000", section
    assert_no_match "9,000", section
    assert_no_match "45,000", section
  end

  test "churn reasons are split per produit, weighted by churned ARR, with blanks as À qualifier" do
    company = Company.create!(name: "Client Raisons", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rs-1", college: "Cadre", assureur: "AXA",
      arr: 7_000, statut_renouvellement: "Churné", churn_reason: "Offre concurrente")
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rs-2", college: "Non cadre", assureur: "AXA",
      arr: 3_000, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rs-3", college: "Cadre", assureur: "AXA",
      arr: 4_000, statut_renouvellement: "Churné", churn_reason: "Tarif / hausse de prix")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rs-4", college: "Non cadre", assureur: "AXA",
      arr: 8_000, statut_renouvellement: "Churné (subi)", churn_reason: "Autre")

    get autres_statistiques_path
    assert_response :success
    slices = @controller.instance_variable_get(:@churn_reasons_by_produit)
    mutuelle, prevoyance = slices.values_at("Mutuelle", "Prévoyance")
    assert_equal 7_000, mutuelle.find { |s| s[:label] == "Offre concurrente (1)" }[:value]
    assert_equal 3_000, mutuelle.find { |s| s[:label] == "À qualifier (1)" }[:value]
    assert_equal 4_000, prevoyance.find { |s| s[:label] == "Tarif / hausse de prix (1)" }[:value]
    assert_nil prevoyance.find { |s| s[:label].start_with?("Autre") }, "churn subi and empty reasons are left out"
    section = @response.body[/Raisons de churn par produit.*/m]
    assert_match "Offre concurrente (1)", section
  end

  test "NRR par AM matches each AM's own portfolio summary, and the college churn chart is gone" do
    other = User.create!(email: "other-nrr@example.com", name: "Autre AM NRR", admin: false, active: true)
    mine = Company.create!(name: "Client NRR Mien", user: @am)
    ProduitDeal.create!(company: mine, produit: "Mutuelle", identifiant: "nrr-1", college: "Cadre", assureur: "AXA",
      arr: 10_000, taux: 5, statut_renouvellement: "Augmenté")
    theirs = Company.create!(name: "Client NRR Autre", user: other)
    ProduitDeal.create!(company: theirs, produit: "Mutuelle", identifiant: "nrr-2", college: "Cadre", assureur: "AXA",
      arr: 10_000, taux: 0, statut_renouvellement: "Churné")
    Company.create!(name: "Client sans produit", user: User.create!(email: "none-nrr@example.com", name: "Sans ARR NRR", admin: false, active: true))

    get autres_statistiques_path
    assert_response :success
    rows = @controller.instance_variable_get(:@am_performance)
    mine_row = rows.find { |r| r[:am] == "AM Stats" }
    expected = PortfolioSummary.new(@am.companies.includes(:produit_deals), user: @am)
    assert_in_delta expected.nrr, mine_row[:nrr], 0.001
    assert_in_delta 105.0, mine_row[:nrr_actual], 0.001
    assert_in_delta 0.0, rows.find { |r| r[:am] == "Autre AM NRR" }[:nrr], 0.001
    assert_nil rows.find { |r| r[:am] == "Sans ARR NRR" }, "AMs without initial ARR are left out"
    assert_equal rows.map { |r| r[:nrr] }.sort.reverse, rows.map { |r| r[:nrr] }
    assert_match "Performance des AM", @response.body
    assert_no_match "Taux de churn par collège", @response.body
  end

  test "portfolio concentration ranks by current ARR and reports the top-10 share" do
    big = Company.create!(name: "Client Concentration Gros", user: @am)
    ProduitDeal.create!(company: big, produit: "Mutuelle", identifiant: "conc-1",
      college: "Cadre", assureur: "AXA", arr: 90_000, taux: 0, statut_renouvellement: "En cours")
    small = Company.create!(name: "Client Concentration Petit", user: @am)
    ProduitDeal.create!(company: small, produit: "Mutuelle", identifiant: "conc-2",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Concentration du portefeuille.*?<\/table>/m]
    big_index = section.index("Client Concentration Gros")
    small_index = section.index("Client Concentration Petit")
    assert big_index < small_index, "the bigger client must rank first"
  end

  test "the distribution counts companies by their total active ARR across contracts, not contracts" do
    split = Company.create!(name: "Client Stats Taille", user: @am)
    # Two contracts of 30 000 each: individually in the 20–50k band, but 60 000 together → one company ≥ 50k.
    ProduitDeal.create!(company: split, produit: "Mutuelle", identifiant: "size-1",
      college: "Cadre", assureur: "AXA", arr: 30_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: split, produit: "Prévoyance", identifiant: "size-2",
      college: "Cadre", assureur: "AXA", arr: 30_000, taux: 0, statut_renouvellement: "En cours")
    small = Company.create!(name: "Client Stats Petit", user: @am)
    ProduitDeal.create!(company: small, produit: "Mutuelle", identifiant: "size-3",
      college: "Cadre", assureur: "AXA", arr: 1_000, taux: 0, statut_renouvellement: "En cours")

    get autres_statistiques_path
    assert_response :success
    assert_no_match "Distribution de la taille des contrats", @response.body
    rows = @controller.instance_variable_get(:@company_distribution)
    assert_equal({ "< 5 000 €" => 1, "5 000 – 20 000 €" => 0, "20 000 – 50 000 €" => 0, "≥ 50 000 €" => 1 },
      rows.to_h { |r| [r[:label], r[:value]] })
    assert_equal 60_000, rows.last[:arr]
    assert_match "Distribution des entreprises", @response.body
  end

  test "the two historical reports are gone" do
    get autres_statistiques_path
    assert_response :success
    assert_no_match "Évolution du NRR global", @response.body
    assert_no_match "Évolution du churn subi", @response.body
  end

  test "the assureur répartition hides assureurs without ARR from its legend" do
    company = Company.create!(name: "Client Légende", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "leg-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours")

    get autres_statistiques_path
    section = @response.body[/Répartition de l'ARR par assureur.*?Portefeuille accompagné/m]
    assert_match "AXA", section
    assert_no_match "Allianz", section
    assert_no_match "Gan —", section
  end

  test "per-AM performance adds upsell, average renewal rate, churn rate and % of produits renewed" do
    company = Company.create!(name: "Client Perf", user: @am)
    [["perf-1", "Augmenté", 10_000, 10], ["perf-2", "Nouveau contrat", 10_000, 0], ["perf-3", "En cours", 10_000, 0],
     ["perf-4", "Churné", 10_000, 0], ["perf-5", "Churné (subi)", 10_000, 0]].each_with_index do |(id, statut, arr, taux), i|
      ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: id, college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, taux: taux, statut_renouvellement: statut)
    end
    UpsellDeal.create!(company: company, produit: "Mutuelle", nombre_salaries: 10, probabilite_signature: 100, statut_signature: "Signé")

    get autres_statistiques_path
    assert_response :success
    row = @controller.instance_variable_get(:@am_performance).find { |r| r[:am] == "AM Stats" }
    summary = PortfolioSummary.new(@am.companies.includes(:produit_deals), user: @am)
    assert_in_delta summary.upsold, row[:upsold], 0.01
    assert_in_delta summary.upsold_actual, row[:upsold_actual], 0.01
    assert_in_delta summary.renewal_rate, row[:renewal_rate], 0.001
    assert_in_delta summary.churn_rate, row[:churn_rate], 0.001
    # 2 renewed (Augmenté, Nouveau contrat) out of 4 produits once the subi churn is set aside.
    assert_equal 2, row[:renewed_count]
    assert_equal 4, row[:produits_count]
    assert_in_delta 50.0, row[:renewed_pct], 0.001
    assert_match "Taux de renouvellement moyen", @response.body
    assert_match "% de produits renouvelés", @response.body
  end

  test "the Équipe and AM filters narrow every report to the chosen AMs" do
    admin = User.create!(email: "admin-filter-stats@example.com", name: "Admin Filtre", admin: true, active: true)
    mine = Company.create!(name: "Client Filtre Mien", user: @am)
    theirs = Company.create!(name: "Client Filtre Admin", user: admin)
    { mine => "ft-1", theirs => "ft-2" }.each do |c, id|
      ProduitDeal.create!(company: c, produit: "Mutuelle", identifiant: id, college: "Cadre", assureur: "AXA",
        arr: 10_000, taux: 0, statut_renouvellement: "Churné", churn_reason: "Autre")
      UpsellDeal.create!(company: c, produit: "Mutuelle", nombre_salaries: 4, probabilite_signature: 50, statut_signature: "En cours")
    end

    get autres_statistiques_path
    assert_equal 2, @controller.instance_variable_get(:@company_ids).size
    assert_equal 2, @controller.instance_variable_get(:@am_performance).size
    assert_equal ["Accompagné", "Non accompagné"], @controller.instance_variable_get(:@accompagnement_split).map { |s| s[:label] }

    get autres_statistiques_path, params: { ams: ["AM Stats"] }
    assert_equal [mine.id], @controller.instance_variable_get(:@company_ids)
    assert_equal ["AM Stats"], @controller.instance_variable_get(:@am_performance).map { |r| r[:am] }
    assert_equal 1, @controller.instance_variable_get(:@renewal_funnel).sum { |s| s[:value] }
    assert_equal 1, @controller.instance_variable_get(:@upsell_funnel).sum { |s| s[:value] }
    assert_equal ["Accompagné"], @controller.instance_variable_get(:@accompagnement_split).map { |s| s[:label] },
      "the non-accompagné figure belongs to no AM, so it drops out once filtered"
    assert_no_match "Client Filtre Admin", @response.body

    get autres_statistiques_path, params: { roles: ["Admin"] }
    assert_equal [theirs.id], @controller.instance_variable_get(:@company_ids)
    assert_equal ["Admin Filtre"], @controller.instance_variable_get(:@am_performance).map { |r| r[:am] }
  end

  test "the filter bar offers Équipe and AM, never lecteurs, and keeps the selection" do
    User.create!(email: "reader-filter-stats@example.com", name: "Lecteur Masqué", role: "Lecteur", active: true)
    get autres_statistiques_path, params: { ams: ["AM Stats"] }
    assert_match 'name="roles[]"', @response.body
    assert_match 'name="ams[]"', @response.body
    assert_match(/value="AM Stats"[^>]*checked/, @response.body)
    assert_no_match "Lecteur Masqué", @response.body
    assert_match "Réinitialiser", @response.body
  end

  test "churn rate by assureur excludes subi churn from both the rate and its base" do
    company = Company.create!(name: "Client Stats Taux", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rate-1",
      college: "Cadre", assureur: "Gan", arr: 10_000, taux: 0, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rate-2",
      college: "Cadre", assureur: "Gan", arr: 10_000, taux: 0, statut_renouvellement: "En cours")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Taux de churn par assureur.*?Raisons de churn par produit/m]
    assert_match(/Gan.*?50\.0%/m, section)
  end

  test "the upsell funnel counts each stage independently and shows its % share of every upsell" do
    company = Company.create!(name: "Client Stats Funnel", user: @am)
    UpsellDeal.create!(company: company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé")
    UpsellDeal.create!(company: company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 30, statut_signature: "En cours")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Entonnoir des upsells.*/m]
    # 1 of 2 upsells is "Signé" -> 50.0%
    assert_match(/Signé[\s\S]*?bar-value">1 · 50\.0%/, section)
  end

  test "the renewal funnel rolls every produit up into En cours / Renouvelé / Churné, with its % share" do
    company = Company.create!(name: "Client Stats Renewal Funnel", user: @am)
    [["En cours", 1_000], ["Augmenté", 2_000], ["Augmentation particulière", 3_000], ["Nouveau contrat", 4_000],
     ["Churné", 5_000], ["Churné (subi)", 6_000]].each_with_index do |(statut, arr), i|
      ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rf-#{i}", college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, taux: 0, statut_renouvellement: statut)
    end

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Entonnoir des produits à renouveler.*?Entonnoir des upsells/m]
    labels = section.scan(/bar-label">([^<]+)</).flatten
    assert_equal ["En cours", "Renouvelé", "Churné"], labels
    assert_match(/En cours[\s\S]*?bar-value">1 · 16\.7% \(1,000 €\)/, section)
    assert_match(/Renouvelé[\s\S]*?bar-value">3 · 50\.0% \(9,000 €\)/, section)
    # Both churn statuses (subi included) are summed here, unlike every NRR-affecting stat elsewhere.
    assert_match(/Churné[\s\S]*?bar-value">2 · 33\.3% \(11,000 €\)/, section)
  end
end
