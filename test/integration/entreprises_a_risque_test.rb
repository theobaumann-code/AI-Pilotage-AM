require "test_helper"

# A company is "at risk" once at least one of its still-active (non-churned) produits carries a nonzero
# risque_churn. Filters mirror the produits table (Équipe/AM/Produit/Statut), independently namespaced
# (risque_*) so they never collide with that table's own AM/Produit/Statut filter state.
class EntreprisesARisqueTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "am-risque@example.com", name: "AM Risque", admin: false, active: true)
    @admin = User.create!(email: "admin-risque@example.com", name: "Admin Risque", admin: true, active: true)
  end

  def risque_table(body)
    body[/id="rque-table-frame">.*?<\/turbo-frame>/m]
  end

  test "a company with a nonzero risque_churn on an active produit shows up" do
    company = Company.create!(name: "Client À Risque", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "risk-1",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 15)

    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_match "Client À Risque", risque_table(@response.body)
    assert_match "3,000", risque_table(@response.body) # arr_at_risk = 20_000 * 15% = 3_000
    assert_match "15%", risque_table(@response.body)
  end

  test "a company with only risque_churn 0 across its produits does not show up" do
    company = Company.create!(name: "Client Sans Risque", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "risk-2",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 0)

    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_no_match "Client Sans Risque", risque_table(@response.body)
  end

  test "a churned produit's risque_churn (forced to 100) does not count — it's no longer à renouveler" do
    company = Company.create!(name: "Client Churne", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "risk-3",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 0, statut_renouvellement: "Churné")

    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_no_match "Client Churne", risque_table(@response.body)
  end

  test "filterable by AM, independently of the produits table's own AM filter" do
    other_am = User.create!(email: "other-risque@example.com", name: "Other Risque", admin: false, active: true)
    company = Company.create!(name: "Client Filtré", user: @am)
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "risk-4",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 10)

    sign_in @admin
    get pilotage_path, params: { risque_ams: [other_am.name] }
    assert_no_match "Client Filtré", risque_table(@response.body)

    get pilotage_path, params: { risque_ams: [@am.name] }
    assert_match "Client Filtré", risque_table(@response.body)
  end
end
