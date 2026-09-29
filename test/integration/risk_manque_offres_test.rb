require "test_helper"

# "Manque d'offres" — a per-company flag, checkable only from "Entreprises à risque" on Vue globale, and
# filterable there too. Scoped to exactly this table on purpose (Company#risque_manque_offres isn't shown
# or editable anywhere else).
class RisqueManqueOffresTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "am-manque-offres@example.com", name: "AM Manque Offres", admin: false, active: true)
    @company = Company.create!(name: "Client Manque Offres", user: @am)
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "manque-offres-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 20)
  end

  test "defaults to unchecked" do
    assert_not @company.risque_manque_offres
  end

  test "any signed-in user can check the flag from the risk table" do
    sign_in @am
    patch company_path(@company), params: { company: { risque_manque_offres: "1" } }

    assert @company.reload.risque_manque_offres
  end

  test "and can uncheck it again" do
    @company.update!(risque_manque_offres: true)
    sign_in @am
    patch company_path(@company), params: { company: { risque_manque_offres: "0" } }

    assert_not @company.reload.risque_manque_offres
  end

  test "return_to carries the admin back to the filtered/paginated Vue globale URL" do
    sign_in @am
    filtered_url = "/pilotage?risque_ams%5B%5D=#{@am.name}&rque_page=2"

    patch company_path(@company), params: { company: { risque_manque_offres: "1" }, return_to: filtered_url }
    assert_redirected_to filtered_url
  end

  test "a return_to pointing outside the app is ignored, falling back to Vue globale" do
    sign_in @am
    patch company_path(@company), params: { company: { risque_manque_offres: "1" }, return_to: "//evil.example.com" }
    assert_redirected_to pilotage_path
  end

  test "the risk table can be filtered to only companies flagged as manque d'offres" do
    other_company = Company.create!(name: "Client Sans Manque", user: @am)
    ProduitDeal.create!(company: other_company, produit: "Mutuelle", identifiant: "manque-offres-2",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 15)
    @company.update!(risque_manque_offres: true)

    sign_in @am
    get pilotage_path, params: { risque_manque_offres: "1" }
    assert_response :success
    section = @response.body[/id="rque-table-frame">.*?<\/turbo-frame>/m]
    assert_match "Client Manque Offres", section
    assert_no_match "Client Sans Manque", section

    get pilotage_path
    assert_response :success
    section = @response.body[/id="rque-table-frame">.*?<\/turbo-frame>/m]
    assert_match "Client Manque Offres", section
    assert_match "Client Sans Manque", section
  end
end
