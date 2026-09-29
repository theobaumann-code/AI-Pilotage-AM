require "test_helper"

# Mon portefeuille's upsell fields (produit, nombre_salaries, probabilite_signature, statut_signature) are
# unconditionally editable by the owning AM — collège joins that list the same way, and unlike a produit
# deal's collège it isn't an admin-only contract field (see DealsController#admin_only_fields).
class UpsellCollegeTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "am-upsell-college@example.com", name: "AM Upsell College", active: true)
    @company = Company.create!(name: "Client Upsell College", user: @am)
    @deal = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 50, statut_signature: "En cours")
    sign_in @am
  end

  test "a new upsell defaults to Ensemble du personnel when no collège is chosen" do
    assert_equal "Ensemble du personnel", @deal.college
  end

  test "the owning AM can edit their own upsell's collège from Mon portefeuille, unconditionally" do
    patch deal_path(@deal), params: { deal: { college: "Cadre" }, redirect_user_id: @am.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success

    @deal.reload
    assert_equal "Cadre", @deal.college
  end

  test "creating an upsell with an explicit collège persists that value" do
    post deals_path(type: "upsell", redirect_user_id: @am.id),
      params: { company_id: @company.id, deal: { produit: "Prévoyance", college: "Non cadre",
        nombre_salaries: 5, probabilite_signature: 20, statut_signature: "Non démarré" } }

    created = UpsellDeal.order(:created_at).last
    assert_equal "Non cadre", created.college
  end
end
