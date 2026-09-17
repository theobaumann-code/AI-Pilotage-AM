require "test_helper"

class CsvExportTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-csv@example.com", name: "Admin CSV", admin: true, active: true)
    @am = User.create!(email: "am-csv@example.com", name: "AM CSV", admin: false, active: true)

    @company = Company.create!(name: "Client Accentué", user: @am)
    @produit = ProduitDeal.create!(company: @company, produit: "Mutuelle", college: "Cadre", assureur: "AXA",
      identifiant: "csv-1", arr: 10_000, taux: 2, statut_renouvellement: "En cours")
    @upsell = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 20,
      probabilite_signature: 50, statut_signature: "En cours")
  end

  test "Mon portefeuille's export includes a UTF-8 BOM so Excel renders accents correctly" do
    sign_in @am
    get export_produits_portfolio_path
    assert_response :success
    assert @response.body.b.start_with?("\xEF\xBB\xBF".b), "expected a UTF-8 BOM at the start of the CSV"
    assert_match "Cadre", @response.body
  end

  test "Mon portefeuille's export omits the ID externe column for a non-admin AM" do
    sign_in @am
    get export_produits_portfolio_path
    assert_response :success
    assert_no_match "ID externe", @response.body
    assert_no_match "csv-1", @response.body
  end

  test "Mon portefeuille's export includes the ID externe column for an admin" do
    sign_in @admin
    get export_produits_portfolio_path(user_id: @am.id)
    assert_response :success
    assert_match "ID externe", @response.body
    assert_match "csv-1", @response.body
  end

  test "Vue globale's upsells export lists every AM's upsells with a BOM" do
    sign_in @admin
    get export_upsells_pilotage_path
    assert_response :success
    assert @response.body.b.start_with?("\xEF\xBB\xBF".b)
    assert_match "Client Accentué", @response.body
    assert_match "AM CSV", @response.body
    assert_match "Prévoyance", @response.body
  end

  test "Vue globale's produits export lists every AM's produits with a BOM" do
    sign_in @admin
    get export_produits_pilotage_path
    assert_response :success
    assert @response.body.b.start_with?("\xEF\xBB\xBF".b)
    assert_match "Client Accentué", @response.body
    assert_match "AM CSV", @response.body
    assert_match "csv-1", @response.body
  end
end
