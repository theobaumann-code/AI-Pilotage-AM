require "test_helper"

# Every renewal table (Mon portefeuille, Vue globale's produits à renouveler, Historique) can be narrowed to a
# numeric range of negotiated renewal rate (taux, %), either bound optional, inclusive, CSV exports included.
class TauxFilterTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-taux@example.com", name: "Admin Taux", admin: true, active: true)
    { "Client Taux Zero" => 0, "Client Taux Cinq" => 5, "Client Taux Dix" => 10 }.each_with_index do |(name, taux), i|
      company = Company.create!(name: name, user: @admin)
      ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "tx-#{i}", college: "Cadre",
        assureur: "AXA", arr: 10_000, taux: taux, statut_renouvellement: "En cours")
    end
    sign_in @admin
  end

  def frame(id)
    @response.body[/id="#{id}">.*?<\/turbo-frame>/m]
  end

  def assert_only(section, *present)
    all = ["Client Taux Zero", "Client Taux Cinq", "Client Taux Dix"]
    present.each { |n| assert_match n, section }
    (all - present).each { |n| assert_no_match n, section }
  end

  test "Mon portefeuille: min only, max only, inclusive range, and CSV export" do
    get portfolio_path, params: { ren_taux_min: "5" }
    assert_only frame("ren-table-frame"), "Client Taux Cinq", "Client Taux Dix"

    get portfolio_path, params: { ren_taux_max: "5" }
    assert_only frame("ren-table-frame"), "Client Taux Zero", "Client Taux Cinq"

    get portfolio_path, params: { ren_taux_min: "1", ren_taux_max: "9" }
    assert_only frame("ren-table-frame"), "Client Taux Cinq"

    get export_produits_portfolio_path, params: { ren_taux_min: "5", ren_taux_max: "5" }
    assert_match "Client Taux Cinq", @response.body
    assert_no_match "Client Taux Zero", @response.body
    assert_no_match "Client Taux Dix", @response.body
  end

  test "Vue globale: produits à renouveler and its CSV export" do
    get pilotage_path, params: { produit_taux_min: "2,5", produit_taux_max: "7" }
    assert_only frame("gprod-table-frame"), "Client Taux Cinq"

    get export_produits_pilotage_path, params: { produit_taux_min: "6" }
    assert_match "Client Taux Dix", @response.body
    assert_no_match "Client Taux Cinq", @response.body
  end

  test "Historique filters live rows and archived rows by taux" do
    ArchiveEntry.create!(deal_type: "ProduitDeal", year: 2025, company_name: "Client Archive Bas", am_name: "Admin Taux",
      produit: "Mutuelle", assureur: "AXA", college: "Cadre", arr: 1_000, taux: 1, statut_renouvellement: "Augmenté")
    ArchiveEntry.create!(deal_type: "ProduitDeal", year: 2025, company_name: "Client Archive Haut", am_name: "Admin Taux",
      produit: "Mutuelle", assureur: "AXA", college: "Cadre", arr: 1_000, taux: 8, statut_renouvellement: "Augmenté")
    year = AppSetting.instance.annee_en_cours

    get historique_path, params: { years: [year, 2025], taux_min: "4" }
    assert_response :success
    table = @response.body[/Historique par contrat.*?<\/table>/m]
    assert_match "Client Archive Haut", table
    assert_match "Client Taux Cinq", table
    assert_match "Client Taux Dix", table
    assert_no_match "Client Archive Bas", table
    assert_no_match "Client Taux Zero", table
  end

  test "a non-numeric bound is ignored instead of raising" do
    get portfolio_path, params: { ren_taux_min: "abc", ren_taux_max: "" }
    assert_response :success
    assert_only frame("ren-table-frame"), "Client Taux Zero", "Client Taux Cinq", "Client Taux Dix"
  end

  test "the range inputs show up in each toolbar and keep their value" do
    get portfolio_path, params: { ren_taux_min: "2.5", ren_taux_max: "7" }
    assert_match(/name="ren_taux_min"[^>]*value="2\.5"/, @response.body)
    assert_match(/name="ren_taux_max"[^>]*value="7"/, @response.body)

    get pilotage_path
    assert_match 'name="produit_taux_min"', @response.body

    get historique_path
    assert_match 'name="taux_min"', @response.body
  end
end
