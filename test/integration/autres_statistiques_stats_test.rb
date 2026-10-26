require "test_helper"

# Every stat on "Autres statistiques" excludes "subi" churn (liquidation/rachat) the same way the rest of
# the app does - these are the correctness checks for that, plus a spot-check on the trickier aggregations
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
      arr: 7_000, statut_renouvellement: "Churné", churn_reason: "Meilleure offre concurrente")
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rs-2", college: "Non cadre", assureur: "AXA",
      arr: 3_000, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rs-3", college: "Cadre", assureur: "AXA",
      arr: 4_000, statut_renouvellement: "Churné", churn_reason: "Non conformité")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rs-4", college: "Non cadre", assureur: "AXA",
      arr: 8_000, statut_renouvellement: "Churné (subi)", churn_reason: "Autre")

    get autres_statistiques_path
    assert_response :success
    slices = @controller.instance_variable_get(:@churn_reasons_by_produit)
    mutuelle, prevoyance = slices.values_at("Mutuelle", "Prévoyance")
    assert_equal 7_000, mutuelle.find { |s| s[:label] == "Meilleure offre concurrente (1)" }[:value]
    assert_equal 3_000, mutuelle.find { |s| s[:label] == "À qualifier (1)" }[:value]
    assert_equal 4_000, prevoyance.find { |s| s[:label] == "Non conformité (1)" }[:value]
    assert_nil prevoyance.find { |s| s[:label].start_with?("Autre") }, "churn subi and empty reasons are left out"
    section = @response.body[/Raisons de churn par produit.*/m]
    assert_match "Meilleure offre concurrente (1)", section
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
    # Two contracts of 30 000 each: individually in the 20-50k band, but 60 000 together → one company ≥ 50k.
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
    assert_equal({ "< 5 000 €" => 1, "5 000 - 20 000 €" => 0, "20 000 - 50 000 €" => 0, "≥ 50 000 €" => 1 },
      rows.to_h { |r| [ r[:label], r[:value] ] })
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
    assert_no_match "Gan -", section
  end

  test "per-AM performance adds upsell, average renewal rate, churn rate and % of produits renewed" do
    company = Company.create!(name: "Client Perf", user: @am)
    [ [ "perf-1", "Augmenté", 10_000, 10 ], [ "perf-2", "Nouveau contrat", 10_000, 0 ], [ "perf-3", "En cours", 10_000, 0 ],
     [ "perf-4", "Churné", 10_000, 0 ], [ "perf-5", "Churné (subi)", 10_000, 0 ] ].each_with_index do |(id, statut, arr, taux), i|
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

  test "pending forecasts: per AM, the share of produits still En cours at 0%, worst first, suffered churn set aside" do
    lazy = User.create!(email: "lazy-fc@example.com", name: "AM Prévisions Vides", active: true)
    diligent = User.create!(email: "diligent-fc@example.com", name: "AM Prévisions Faites", active: true)
    empty = User.create!(email: "empty-fc@example.com", name: "AM Sans Produit", active: true)
    lazy_co = Company.create!(name: "Client Vide", user: lazy)
    done_co = Company.create!(name: "Client Fait", user: diligent)
    Company.create!(name: "Client Sans Produit FC", user: empty)
    # lazy: 3 of 4 produits untouched (En cours, 0%); the 4th is En cours but has a rate -> not pending
    [ [ "fc-1", "En cours", 0, 1_000 ], [ "fc-2", "En cours", 0, 2_000 ], [ "fc-3", "En cours", 0, 3_000 ], [ "fc-4", "En cours", 3.5, 4_000 ],
     [ "fc-5", "Churné (subi)", 0, 9_000 ] ].each_with_index do |(id, statut, taux, arr), i|
      ProduitDeal.create!(company: lazy_co, produit: "Mutuelle", identifiant: id, college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, taux: taux, statut_renouvellement: statut)
    end
    # diligent: rate set, renewed, and a 0% that is already decided (Churné / Nouveau contrat) -> none pending
    [ [ "fc-6", "En cours", 2, 1_000 ], [ "fc-7", "Nouveau contrat", 0, 1_000 ], [ "fc-8", "Churné", 0, 1_000 ] ].each_with_index do |(id, statut, taux, arr), i|
      ProduitDeal.create!(company: done_co, produit: "Prévoyance", identifiant: id, college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, taux: taux, statut_renouvellement: statut)
    end

    get autres_statistiques_path
    assert_response :success
    rows = @controller.instance_variable_get(:@pending_forecasts)
    lazy_row = rows.find { |r| r[:label] == "AM Prévisions Vides" }
    assert_equal [ 3, 4 ], [ lazy_row[:count], lazy_row[:total] ], "the subi-churned produit is left out of the base"
    assert_in_delta 75.0, lazy_row[:value], 0.001
    assert_equal 6_000, lazy_row[:arr]
    assert_equal "ko", lazy_row[:status]
    done_row = rows.find { |r| r[:label] == "AM Prévisions Faites" }
    assert_equal [ 0, 3 ], [ done_row[:count], done_row[:total] ]
    assert_equal "ok", done_row[:status]
    assert_nil rows.find { |r| r[:label] == "AM Sans Produit" }, "an AM with no produit has nothing to update"
    assert_operator rows.index(lazy_row), :<, rows.index(done_row), "worst first"
    assert_match "Prévisions de renouvellement non mises à jour", @response.body
    assert_match "75.0 % · 3/4 produits", @response.body

    get autres_statistiques_path, params: { ams: [ "AM Prévisions Faites" ] }
    assert_equal [ "AM Prévisions Faites" ], @controller.instance_variable_get(:@pending_forecasts).map { |r| r[:label] }
  end

  test "churn by risque: churned ARR over total ARR for Mutuelle (santé) and Prévoyance, with the projected rate, suffered churn set aside" do
    company = Company.create!(name: "Client Risque", user: @am)
    [ [ "rk-1", "Mutuelle", "Churné", 10_000, 0 ], [ "rk-2", "Mutuelle", "En cours", 30_000, 20 ], [ "rk-3", "Mutuelle", "Churné (subi)", 50_000, 0 ],
     [ "rk-4", "Prévoyance", "En cours", 20_000, 10 ] ].each_with_index do |(id, produit, statut, arr, risque), i|
      ProduitDeal.create!(company: company, produit: produit, identifiant: id, college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, statut_renouvellement: statut, risque_churn: risque)
    end

    get autres_statistiques_path
    assert_response :success
    rows = @controller.instance_variable_get(:@churn_by_risque).index_by { |r| r[:label] }
    assert_equal [ "Mutuelle (santé)", "Prévoyance" ], rows.keys

    sante = rows["Mutuelle (santé)"]
    assert_in_delta 25.0, sante[:value], 0.001, "10 000 churned of 40 000 (the 50 000 subi is outside the base)"
    assert_equal [ 10_000, 40_000 ], [ sante[:churned], sante[:total] ]
    assert_in_delta 40.0, sante[:projected], 0.001, "(10 000 + 30 000 × 20%) / 40 000"
    assert_equal [ 1, 2 ], [ sante[:count], sante[:produits_count] ]
    assert_equal "ko", sante[:status], "above the 5.5% limit"

    prevoyance = rows["Prévoyance"]
    assert_in_delta 0.0, prevoyance[:value], 0.001
    assert_in_delta 10.0, prevoyance[:projected], 0.001
    assert_equal "ok", prevoyance[:status]

    assert_in_delta 16_000, sante[:projected_amount], 0.001

    section = @response.body[/<h2>Churn par risque<\/h2>.*?<h2>Taux de churn par assureur/m]
    # the legend names both series, and each risque gets one clearly labelled bar per series
    assert_match "Churn à date", section[/risque-legend.*?<\/div>/m]
    assert_match "Churn projeté", section[/risque-legend.*?<\/div>/m]
    assert_equal 2, section.scan(/risque-block/).size
    assert_equal 2, section.scan(/<span class="risque-label">Churn à date<\/span>/).size
    assert_equal 2, section.scan(/<span class="risque-label">Churn projeté<\/span>/).size
    sante_block = section[/<div class="risque-block">.*?(?=<div class="risque-block">|\z)/m]
    assert_match "Mutuelle (santé)", sante_block
    assert_match(/ARR total 40,000 €/, sante_block)
    assert_match(/Churn à date[\s\S]*?25\.0 %[\s\S]*?10,000 €[\s\S]*?Churn projeté[\s\S]*?40\.0 %[\s\S]*?16,000 €/, sante_block)
    prevoyance_block = section[/<strong>Prévoyance<\/strong>.*/m]
    assert_match(/Churn à date[\s\S]*?0\.0 %[\s\S]*?0 €[\s\S]*?Churn projeté[\s\S]*?10\.0 %[\s\S]*?2,000 €/, prevoyance_block)
  end

  test "churn by risque can be filtered by assureur, alone or several at once, and only that card is affected" do
    company = Company.create!(name: "Client Risque Assureur", user: @am)
    [ [ "ra-1", "Mutuelle", "AXA", "Churné", 10_000 ], [ "ra-2", "Mutuelle", "AXA", "En cours", 30_000 ],
     [ "ra-3", "Mutuelle", "Gan", "Churné", 20_000 ], [ "ra-4", "Mutuelle", "Gan", "En cours", 20_000 ],
     [ "ra-5", "Prévoyance", "Allianz", "Churné", 5_000 ], [ "ra-6", "Prévoyance", "Allianz", "En cours", 15_000 ] ].each_with_index do |(id, produit, assureur, statut, arr), i|
      ProduitDeal.create!(company: company, produit: produit, identifiant: id, college: i.even? ? "Cadre" : "Non cadre",
        assureur: assureur, arr: arr, statut_renouvellement: statut)
    end

    rows = ->(params = {}) {
      get autres_statistiques_path, params: params
      @controller.instance_variable_get(:@churn_by_risque).index_by { |r| r[:label] }
    }

    all = rows.call
    assert_equal [ 30_000, 80_000 ], [ all["Mutuelle (santé)"][:churned], all["Mutuelle (santé)"][:total] ]

    axa = rows.call(risque_assureurs: [ "AXA" ])
    assert_equal [ 10_000, 40_000 ], [ axa["Mutuelle (santé)"][:churned], axa["Mutuelle (santé)"][:total] ]
    assert_in_delta 25.0, axa["Mutuelle (santé)"][:value], 0.001
    assert_equal [ 0, 0 ], [ axa["Prévoyance"][:total], axa["Prévoyance"][:produits_count] ], "no AXA prévoyance: the bar is empty"

    two = rows.call(risque_assureurs: [ "AXA", "Allianz" ])
    assert_equal 40_000, two["Mutuelle (santé)"][:total]
    assert_equal [ 5_000, 20_000 ], [ two["Prévoyance"][:churned], two["Prévoyance"][:total] ]

    # only this card reacts: the other churn report keeps every assureur
    assert_equal 3, @controller.instance_variable_get(:@churn_rate_by_assureur).size
    assert_equal 6, @controller.instance_variable_get(:@renewal_funnel).sum { |s| s[:value] }
  end

  def renewal_card(body)
    body[%r{<h2>Renouvellement par risque</h2>.*?<h2>Churn par risque</h2>}m]
  end

  test "renewal by risque: ARR gained through renewal rates over the line's ARR, renewed-so-far vs projected, subi churn set aside" do
    company = Company.create!(name: "Client Renouv Risque", user: @am)
    [ [ "rn-1", "Mutuelle", "Augmenté", 40_000, 5 ], [ "rn-2", "Mutuelle", "En cours", 40_000, 3 ],
     [ "rn-3", "Mutuelle", "Churné", 10_000, 0 ], [ "rn-4", "Mutuelle", "Churné (subi)", 50_000, 8 ],
     [ "rn-5", "Prévoyance", "Nouveau contrat", 20_000, 0 ], [ "rn-6", "Prévoyance", "Augmentation particulière", 20_000, 10 ] ].each_with_index do |(id, produit, statut, arr, taux), i|
      ProduitDeal.create!(company: company, produit: produit, identifiant: id, college: i.even? ? "Cadre" : "Non cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, taux: taux, statut_renouvellement: statut)
    end

    get autres_statistiques_path
    assert_response :success
    rows = @controller.instance_variable_get(:@renewal_by_risque).index_by { |r| r[:label] }
    assert_equal [ "Mutuelle (santé)", "Prévoyance" ], rows.keys

    sante = rows["Mutuelle (santé)"]
    assert_equal 90_000, sante[:total], "40 000 + 40 000 + 10 000, the 50 000 subi is outside the base"
    assert_in_delta 2_000, sante[:done_amount], 0.001, "only the renewed one: 40 000 × 5%"
    assert_in_delta 2_000 / 90_000.0 * 100, sante[:value], 0.001
    assert_in_delta 3_200, sante[:projected_amount], 0.001, "40 000 × 5% + 40 000 × 3%, the churned one excluded"
    assert_in_delta 3_200 / 90_000.0 * 100, sante[:projected], 0.001
    assert_equal [ 1, 3 ], [ sante[:count], sante[:produits_count] ]
    assert_equal "ko", sante[:status], "below the 5% objective"

    prevoyance = rows["Prévoyance"]
    assert_in_delta 2_000, prevoyance[:done_amount], 0.001, "Nouveau contrat adds nothing, the particular increase 20 000 × 10%"
    assert_in_delta 5.0, prevoyance[:value], 0.001
    assert_in_delta 5.0, prevoyance[:projected], 0.001
    assert_equal [ 2, 2 ], [ prevoyance[:count], prevoyance[:produits_count] ]
    assert_equal "ok", prevoyance[:status], "5% reaches the objective"

    section = renewal_card(@response.body)
    assert_equal 2, section.scan("risque-block").size
    assert_match "Renouvellement à date", section[/risque-legend.*?<\/div>/m]
    assert_match "Renouvellement projeté", section[/risque-legend.*?<\/div>/m]
    assert_match "Objectif 5.0 %", section[/risque-legend.*?<\/div>/m]
    assert_equal 2, section.scan(/<span class="risque-label">Renouvellement à date<\/span>/).size
    assert_equal 2, section.scan(/<span class="risque-label">Renouvellement projeté<\/span>/).size
    sante_block = section[/<div class="risque-block">.*?(?=<div class="risque-block">|\z)/m]
    assert_match "Mutuelle (santé)", sante_block
    assert_match(/ARR total 90,000 € · 1 produit renouvelé sur 3/, sante_block)
    assert_match(/Renouvellement à date[\s\S]*?2\.2 %[\s\S]*?2,000 €[\s\S]*?Renouvellement projeté[\s\S]*?3\.6 %[\s\S]*?3,200 €/, sante_block)
    prevoyance_block = section[/<strong>Prévoyance<\/strong>.*/m]
    assert_match(/5\.0 %[\s\S]*?2,000 €[\s\S]*?5\.0 %/, prevoyance_block)
  end

  test "the projected renewal weights each increase by the chance the contract stays (1 − risque de churn)" do
    company = Company.create!(name: "Client Renouv Pondere", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rp-1", college: "Cadre", assureur: "AXA",
      arr: 100_000, taux: 10, statut_renouvellement: "En cours", risque_churn: 20)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rp-2", college: "Non cadre", assureur: "Gan",
      arr: 100_000, taux: 10, statut_renouvellement: "En cours", risque_churn: 100)

    get autres_statistiques_path
    sante = @controller.instance_variable_get(:@renewal_by_risque).first
    assert_in_delta 8_000, sante[:projected_amount], 0.001, "100 000 × 10% × 80% - the contract certain to churn adds nothing"
    assert_in_delta 4.0, sante[:projected], 0.001
    assert_in_delta 0.0, sante[:value], 0.001, "nothing renewed yet"
  end

  test "a renewal rate below the objective reads red, at or above it does not" do
    company = Company.create!(name: "Client Renouv Couleur", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rc-1", college: "Cadre", assureur: "AXA",
      arr: 10_000, taux: 2, statut_renouvellement: "Augmenté")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rc-2", college: "Cadre", assureur: "AXA",
      arr: 10_000, taux: 7, statut_renouvellement: "Augmenté")

    get autres_statistiques_path
    blocks = renewal_card(@response.body).split('<div class="risque-block">').drop(1)
    assert_match(/color:var\(--red\)">\s*<strong>2\.0 %/, blocks[0], "2% is under the 5% objective")
    assert_match(/color:var\(--text\)">\s*<strong>7\.0 %/, blocks[1], "7% beats it")
  end

  test "renewal by risque has its own Assureur filter that only moves this card, next to the churn one" do
    company = Company.create!(name: "Client Renouv Assureur", user: @am)
    [ [ "ra-1", "AXA", 4 ], [ "ra-2", "Gan", 8 ] ].each_with_index do |(id, assureur, taux), i|
      ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: id, college: i.zero? ? "Cadre" : "Non cadre",
        assureur: assureur, arr: 10_000, taux: taux, statut_renouvellement: "Augmenté")
    end
    rows = ->(params = {}) {
      get autres_statistiques_path, params: params
      @controller.instance_variable_get(:@renewal_by_risque).first
    }
    assert_equal [ 20_000, 1_200 ], [ rows.call[:total], rows.call[:done_amount] ]
    gan = rows.call(renouv_assureurs: [ "Gan" ])
    assert_equal [ 10_000, 800 ], [ gan[:total], gan[:done_amount] ]
    assert_in_delta 8.0, gan[:value], 0.001

    # the churn card keeps its own filter: a renewal selection doesn't touch it, and vice versa
    get autres_statistiques_path, params: { renouv_assureurs: [ "Gan" ] }
    assert_equal 20_000, @controller.instance_variable_get(:@churn_by_risque).first[:total]
    get autres_statistiques_path, params: { risque_assureurs: [ "Gan" ] }
    assert_equal 20_000, @controller.instance_variable_get(:@renewal_by_risque).first[:total]

    # the card shows its filter with the selection, and carries the other card's selection across (one value at a time)
    get autres_statistiques_path, params: { renouv_assureurs: [ "AXA", "Gan" ], risque_assureurs: [ "Allianz", "Gan" ] }
    card = renewal_card(@response.body)
    assert_match 'name="renouv_assureurs[]"', card
    assert_match "Assureur (2)", card
    assert_match(/value="AXA"[^>]*checked/, card)
    assert_match(/<input type="hidden" name="risque_assureurs\[\]" value="Allianz"/, card)
    assert_match(/<input type="hidden" name="risque_assureurs\[\]" value="Gan"/, card)
  end

  test "the Assureur filter of Churn par risque is in the card, keeps its selection and the page's AM filter" do
    get autres_statistiques_path, params: { risque_assureurs: [ "AXA", "Gan" ], ams: [ "AM Stats" ] }
    card = @response.body[%r{<h2>Churn par risque</h2>.*?class="risque-legend"}m]
    assert_match 'name="risque_assureurs[]"', card
    assert_match(/value="AXA"[^>]*checked/, card)
    assert_match(/value="Gan"[^>]*checked/, card)
    assert_match "Assureur (2)", card
    assert_match(/<input type="hidden" name="ams\[\]" value="AM Stats"/, card, "the page's AM filter is carried by the card's form")
  end

  test "a multi-value filter is carried to other forms one value at a time, not fused into one string" do
    get autres_statistiques_path, params: { ams: [ "AM Stats" ], risque_assureurs: [ "AXA", "Gan" ] }
    # the page-wide Équipe/AM form re-emits the card's selection
    page_form = @response.body[/<div class="toolbar stats-filters">.*?<\/form>/m]
    assert_match(/<input type="hidden" name="risque_assureurs\[\]" value="AXA"/, page_form)
    assert_match(/<input type="hidden" name="risque_assureurs\[\]" value="Gan"/, page_form)
    assert_no_match(/value="AXA Gan"/, @response.body)
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
    assert_equal [ "Accompagné", "Non accompagné" ], @controller.instance_variable_get(:@accompagnement_split).map { |s| s[:label] }

    get autres_statistiques_path, params: { ams: [ "AM Stats" ] }
    assert_equal [ mine.id ], @controller.instance_variable_get(:@company_ids)
    assert_equal [ "AM Stats" ], @controller.instance_variable_get(:@am_performance).map { |r| r[:am] }
    assert_equal 1, @controller.instance_variable_get(:@renewal_funnel).sum { |s| s[:value] }
    assert_equal 1, @controller.instance_variable_get(:@upsell_funnel).sum { |s| s[:value] }
    assert_equal [ "Accompagné" ], @controller.instance_variable_get(:@accompagnement_split).map { |s| s[:label] },
      "the non-accompagné figure belongs to no AM, so it drops out once filtered"
    assert_no_match "Client Filtre Admin", @response.body

    get autres_statistiques_path, params: { roles: [ "Admin" ] }
    assert_equal [ theirs.id ], @controller.instance_variable_get(:@company_ids)
    assert_equal [ "Admin Filtre" ], @controller.instance_variable_get(:@am_performance).map { |r| r[:am] }
  end

  test "the filter bar offers Équipe and AM, never lecteurs, and keeps the selection" do
    User.create!(email: "reader-filter-stats@example.com", name: "Lecteur Masqué", role: "Lecteur", active: true)
    get autres_statistiques_path, params: { ams: [ "AM Stats" ] }
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
    [ [ "En cours", 1_000 ], [ "Augmenté", 2_000 ], [ "Augmentation particulière", 3_000 ], [ "Nouveau contrat", 4_000 ],
     [ "Churné", 5_000 ], [ "Churné (subi)", 6_000 ] ].each_with_index do |(statut, arr), i|
      ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rf-#{i}", college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: arr, taux: 0, statut_renouvellement: statut)
    end

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Entonnoir des produits à renouveler.*?Churn par risque/m]
    labels = section.scan(/bar-label">([^<]+)</).flatten
    assert_equal [ "En cours", "Renouvelé", "Churné" ], labels
    assert_match(/En cours[\s\S]*?bar-value">1 · 16\.7% \(1,000 €\)/, section)
    assert_match(/Renouvelé[\s\S]*?bar-value">3 · 50\.0% \(9,000 €\)/, section)
    # Both churn statuses (subi included) are summed here, unlike every NRR-affecting stat elsewhere.
    assert_match(/Churné[\s\S]*?bar-value">2 · 33\.3% \(11,000 €\)/, section)
  end
end
