require "test_helper"

# "Upsells en cours (tous AM)" mirrors the produits table's filters: AM, produit, statut, and — like the
# top summary cards — team (role), so an admin can narrow it down to just the AMs, just the KAMs, etc.
class GlobalUpsellsFilterTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-gups-filter@example.com", name: "Admin Gups Filter", admin: true, active: true)
    @am = User.create!(email: "am-gups-filter@example.com", name: "AM Gups Filter", admin: false, active: true)
    @company = Company.create!(name: "Client Gups Filter", user: @am)
    UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 50, statut_signature: "En cours")
  end

  test "the upsells table is filterable by team (role)" do
    sign_in @admin
    get pilotage_path, params: { upsell_roles: ["Admin"] }
    assert_response :success
    assert_no_match "Client Gups Filter", @response.body

    get pilotage_path, params: { upsell_roles: ["AM"] }
    assert_match "Client Gups Filter", @response.body
  end
end
