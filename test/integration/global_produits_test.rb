require "test_helper"

# Vue globale's "Produits à renouveler (tous AM)" mirrors "Upsells en cours (tous AM)": same filters, same
# admin-editable-from-anywhere pattern (row_context=global_produit tells DealsController#update to render
# the page-wide summary cards instead of Mon portefeuille's per-AM ones).
class GlobalProduitsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-gprod@example.com", name: "Admin Gprod", admin: true, active: true)
    @am = User.create!(email: "am-gprod@example.com", name: "AM Gprod", admin: false, active: true)
    @company = Company.create!(name: "Client Gprod", user: @am)
    @deal = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "gprod-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 2, statut_renouvellement: "En cours", risque_churn: 10)
  end

  test "everyone can see every AM's produits, filterable by AM/produit/statut" do
    sign_in @am
    get pilotage_path
    assert_response :success
    assert_match "Client Gprod", @response.body
    assert_match "10%", @response.body

    get pilotage_path, params: { produit_ams: [@admin.name] }
    assert_no_match "Client Gprod", @response.body
  end

  test "an admin editing another AM's produit from the global table persists to that AM's real record" do
    sign_in @admin

    patch deal_path(@deal), params: { deal: { risque_churn: 60 }, row_context: "global_produit" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "global-summary-cards", @response.body

    @deal.reload
    assert_equal 60, @deal.risque_churn
  end

  test "a non-admin cannot edit another AM's produit via the global-table path" do
    other_am = User.create!(email: "other-gprod@example.com", name: "Other Gprod", admin: false, active: true)
    sign_in other_am

    patch deal_path(@deal), params: { deal: { risque_churn: 60 }, row_context: "global_produit" }

    @deal.reload
    assert_equal 10, @deal.risque_churn, "a non-admin must not be able to edit another AM's produit"
  end
end
