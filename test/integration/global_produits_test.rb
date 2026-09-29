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

  # Scoped to the produits table's own frame, not the whole page — "Client Gprod" also has a nonzero
  # risque_churn on this same deal, so it legitimately shows up in the separate "Entreprises à risque"
  # table too (a different, independent set of risque_* filters) regardless of this filter.
  def produits_table(body)
    body[/id="gprod-table-frame">.*?<\/turbo-frame>/m]
  end

  test "everyone can see every AM's produits, filterable by AM/produit/statut" do
    sign_in @am
    get pilotage_path
    assert_response :success
    assert_match "Client Gprod", produits_table(@response.body)
    assert_match "10%", produits_table(@response.body)

    get pilotage_path, params: { produit_ams: [@admin.name] }
    assert_no_match "Client Gprod", produits_table(@response.body)
  end

  test "the produits table is also filterable by team (role), not just by named AM" do
    sign_in @am
    get pilotage_path, params: { produit_roles: ["Admin"] }
    assert_response :success
    assert_no_match "Client Gprod", produits_table(@response.body)

    get pilotage_path, params: { produit_roles: ["AM"] }
    assert_match "Client Gprod", produits_table(@response.body)
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

  test "an admin can also edit the contract-of-record fields (collège, produit, assureur, ID externe, ARR) from the global table" do
    sign_in @admin

    patch deal_path(@deal), params: { deal: { college: "Non cadre", produit: "Prévoyance",
      assureur: "Gan", identifiant: "gprod-1-bis", arr: 25_000 }, row_context: "global_produit" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success

    @deal.reload
    assert_equal "Non cadre", @deal.college
    assert_equal "Prévoyance", @deal.produit
    assert_equal "Gan", @deal.assureur
    assert_equal "gprod-1-bis", @deal.identifiant
    assert_in_delta 25_000, @deal.arr, 0.01
  end

  test "a non-admin cannot edit the contract-of-record fields via the global-table path either" do
    other_am = User.create!(email: "other-contract-gprod@example.com", name: "Other Contract Gprod", admin: false, active: true)
    sign_in other_am

    patch deal_path(@deal), params: { deal: { college: "Non cadre", arr: 99_999 }, row_context: "global_produit" }

    @deal.reload
    assert_equal "Cadre", @deal.college
    assert_in_delta 10_000, @deal.arr, 0.01
  end

  test "the non-Turbo (plain HTML) fallback redirects back to Vue globale, not to the admin's own portefeuille" do
    sign_in @admin

    # No Accept header for turbo-stream here — simulates a submission Turbo never intercepted (JS didn't
    # load/run in time, etc.), which falls through to the format.html branch.
    patch deal_path(@deal), params: { deal: { risque_churn: 60 }, row_context: "global_produit" }
    assert_redirected_to pilotage_path

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
