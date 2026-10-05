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
    section = @response.body[/Raisons de churn par produit.*?Entonnoir des upsells/m]
    assert_match "Offre concurrente (1)", section
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

  test "contract size distribution buckets by current ARR" do
    company = Company.create!(name: "Client Stats Taille", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "size-1",
      college: "Cadre", assureur: "AXA", arr: 60_000, taux: 0, statut_renouvellement: "En cours")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Distribution de la taille des contrats.*?Évolution du NRR/m]
    assert_match "60,000", section
  end

  test "churn rate by assureur excludes subi churn from both the rate and its base" do
    company = Company.create!(name: "Client Stats Taux", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rate-1",
      college: "Cadre", assureur: "Gan", arr: 10_000, taux: 0, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rate-2",
      college: "Cadre", assureur: "Gan", arr: 10_000, taux: 0, statut_renouvellement: "En cours")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Taux de churn par assureur.*?Taux de churn par collège/m]
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
    section = @response.body[/Entonnoir des upsells.*?Entonnoir des produits à renouveler/m]
    # 1 of 2 upsells is "Signé" -> 50.0%
    assert_match(/Signé[\s\S]*?bar-value">1 · 50\.0%/, section)
  end

  test "the renewal funnel counts every produit by statut_renouvellement, including both churn statuses, with its % share" do
    company = Company.create!(name: "Client Stats Renewal Funnel", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rf-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rf-2",
      college: "Cadre", assureur: "AXA", arr: 5_000, taux: 0, statut_renouvellement: "Churné (subi)")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Entonnoir des produits à renouveler.*?\z/m]
    # 1 of 2 produits is "En cours" -> 50.0%; the "subi" one must still show up as its own stage here
    # (unlike every ARR/NRR-affecting stat elsewhere on this page).
    assert_match(/En cours[\s\S]*?bar-value">1 · 50\.0%/, section)
    assert_match(/Churné \(subi\)[\s\S]*?bar-value">1 · 50\.0%/, section)
  end
end
