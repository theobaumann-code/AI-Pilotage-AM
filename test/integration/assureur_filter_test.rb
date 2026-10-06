require "test_helper"

# Every table listing produits (Mon portefeuille's renewal table, Vue globale's renewal / at-risk / churned
# tables) can be narrowed by assureur, CSV exports included.
class AssureurFilterTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-assureur@example.com", name: "Admin Assureur", admin: true, active: true)
    @axa_company = Company.create!(name: "Client Chez AXA", user: @admin)
    @gan_company = Company.create!(name: "Client Chez Gan", user: @admin)
    ProduitDeal.create!(company: @axa_company, produit: "Mutuelle", identifiant: "as-1", college: "Cadre",
      assureur: "AXA", arr: 10_000, statut_renouvellement: "En cours", risque_churn: 20)
    ProduitDeal.create!(company: @gan_company, produit: "Mutuelle", identifiant: "as-2", college: "Cadre",
      assureur: "Gan", arr: 10_000, statut_renouvellement: "En cours", risque_churn: 20)
    ProduitDeal.create!(company: @axa_company, produit: "Prévoyance", identifiant: "as-3", college: "Cadre",
      assureur: "AXA", arr: 5_000, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: @gan_company, produit: "Prévoyance", identifiant: "as-4", college: "Cadre",
      assureur: "Gan", arr: 5_000, statut_renouvellement: "Churné")
    sign_in @admin
  end

  def frame(body, id)
    body[/id="#{id}">.*?<\/turbo-frame>/m]
  end

  test "Mon portefeuille's renewal table and its CSV export filter by assureur" do
    get portfolio_path
    assert_match "Client Chez AXA", frame(@response.body, "ren-table-frame")
    assert_match "Client Chez Gan", frame(@response.body, "ren-table-frame")

    get portfolio_path, params: { ren_assureurs: ["Gan"] }
    assert_no_match "Client Chez AXA", frame(@response.body, "ren-table-frame")
    assert_match "Client Chez Gan", frame(@response.body, "ren-table-frame")

    get export_produits_portfolio_path, params: { ren_assureurs: ["Gan"] }
    assert_no_match "Client Chez AXA", @response.body
    assert_match "Client Chez Gan", @response.body
  end

  test "Vue globale's renewal table and its CSV export filter by assureur" do
    get pilotage_path, params: { produit_assureurs: ["AXA"] }
    assert_match "Client Chez AXA", frame(@response.body, "gprod-table-frame")
    assert_no_match "Client Chez Gan", frame(@response.body, "gprod-table-frame")

    get export_produits_pilotage_path, params: { produit_assureurs: ["AXA"] }
    assert_match "Client Chez AXA", @response.body
    assert_no_match "Client Chez Gan", @response.body
  end

  test "Vue globale's at-risk table and its CSV export filter by assureur" do
    get pilotage_path, params: { risque_assureurs: ["Gan"] }
    assert_no_match "Client Chez AXA", frame(@response.body, "rque-table-frame")
    assert_match "Client Chez Gan", frame(@response.body, "rque-table-frame")

    get export_risque_pilotage_path, params: { risque_assureurs: ["Gan"] }
    assert_no_match "Client Chez AXA", @response.body
    assert_match "Client Chez Gan", @response.body
  end

  test "Vue globale's churned-produits table and its CSV export filter by assureur" do
    get pilotage_path, params: { churn_assureurs: ["AXA"] }
    assert_match "Client Chez AXA", frame(@response.body, "gchurn-table-frame")
    assert_no_match "Client Chez Gan", frame(@response.body, "gchurn-table-frame")

    get export_churn_pilotage_path, params: { churn_assureurs: ["AXA"] }
    assert_match "Client Chez AXA", @response.body
    assert_no_match "Client Chez Gan", @response.body
  end

  test "each filter shows up as an Assureur checklist in its table's toolbar" do
    get pilotage_path
    %w[produit_assureurs risque_assureurs churn_assureurs].each do |param|
      assert_match %(name="#{param}[]"), @response.body
    end
    get portfolio_path
    assert_match %(name="ren_assureurs[]"), @response.body
  end
end
