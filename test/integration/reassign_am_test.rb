require "test_helper"

class ReassignAmTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-reassign@example.com", password: "password123", name: "Admin Reassign", admin: true, active: true)
    @original_am = User.create!(email: "orig-reassign@example.com", password: "password123", name: "Orig AM", active: true)
    @new_am = User.create!(email: "new-reassign@example.com", password: "password123", name: "New AM", active: true)
    @company = Company.create!(name: "Client Reassign", user: @original_am)
  end

  test "reassigning a produit deal moves the whole company, taking every produit and any non-overridden upsell with it" do
    produit1 = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours")
    produit2 = ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours")
    plain_upsell = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    sign_in @admin
    patch reassign_am_deal_path(produit1), params: { user_id: @new_am.id }
    assert_redirected_to portfolio_path

    assert_equal @new_am, @company.reload.user
    assert_equal @new_am, produit1.reload.effective_user
    assert_equal @new_am, produit2.reload.effective_user
    assert_equal @new_am, plain_upsell.reload.effective_user
  end

  test "reassigning an upsell moves only that upsell, leaving the company and its produits with the original AM" do
    produit = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours")
    upsell = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    sign_in @admin
    patch reassign_am_deal_path(upsell), params: { user_id: @new_am.id }
    assert_redirected_to portfolio_path

    assert_equal @new_am, upsell.reload.effective_user
    assert_equal @original_am, @company.reload.user
    assert_equal @original_am, produit.reload.effective_user
  end

  test "a non-admin cannot reassign anything" do
    non_admin = User.create!(email: "regular-reassign@example.com", password: "password123", name: "Regular AM", active: true)
    upsell = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    sign_in non_admin
    patch reassign_am_deal_path(upsell), params: { user_id: non_admin.id }

    assert_nil upsell.reload.user
  end
end
