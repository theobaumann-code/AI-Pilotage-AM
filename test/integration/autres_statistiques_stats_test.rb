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

  test "the upsell funnel counts each stage independently" do
    company = Company.create!(name: "Client Stats Funnel", user: @am)
    UpsellDeal.create!(company: company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé")

    get autres_statistiques_path
    assert_response :success
    section = @response.body[/Entonnoir des upsells.*?Portefeuille accompagné/m]
    assert_match(/Signé[\s\S]*?bar-value">1 /, section)
  end
end
