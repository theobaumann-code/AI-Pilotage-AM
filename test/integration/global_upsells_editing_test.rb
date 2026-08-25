require "test_helper"

# Vue globale's "Upsells en cours (tous AM)" table lets an admin edit another AM's upsell directly
# (row_context=global tells DealsController#update to render the page-wide summary cards instead of
# Mon portefeuille's per-AM ones). The edit must be a real write to that AM's own record — not a
# global-view-only copy — so it shows up unchanged the next time that AM opens Mon portefeuille.
class GlobalUpsellsEditingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-gups@example.com", password: "password123", name: "Admin Gups", admin: true, active: true)
    @other_am = User.create!(email: "other-gups@example.com", password: "password123", name: "Other AM", admin: false, active: true)
    @company = Company.create!(name: "Client Other AM", user: @other_am)
    @deal = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 50, statut_signature: "En cours")
  end

  test "an admin editing another AM's upsell from the global table persists to that AM's real record" do
    sign_in @admin

    patch deal_path(@deal), params: { deal: { statut_signature: "Signé" }, row_context: "global" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "global-summary-cards", @response.body

    @deal.reload
    assert_equal "Signé", @deal.statut_signature
    assert_equal 100, @deal.probabilite_signature
  end

  test "a non-admin cannot edit another AM's upsell via the global-table path" do
    other_regular_am = User.create!(email: "third-gups@example.com", password: "password123", name: "Third AM", admin: false, active: true)
    sign_in other_regular_am

    patch deal_path(@deal), params: { deal: { statut_signature: "Signé" }, row_context: "global" }

    @deal.reload
    assert_equal "En cours", @deal.statut_signature, "a non-admin must not be able to edit another AM's upsell"
  end
end
