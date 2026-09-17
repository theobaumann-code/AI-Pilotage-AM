require "test_helper"

# KAM has the exact same rights as admin everywhere (User#privileged?) — only the NRR/portfolio
# calculations stay identical for AM and KAM. This exercises a few representative admin-gated actions to
# confirm KAM passes require_admin! just like a real admin, while a plain AM is still blocked.
class KamPrivilegesTest < ActionDispatch::IntegrationTest
  setup do
    @kam = User.create!(email: "kam-priv@example.com", name: "Kam Priv", kam: true, active: true)
    @am = User.create!(email: "am-priv@example.com", name: "Am Priv", active: true)
  end

  test "a KAM can reach an admin-only page (import)" do
    sign_in @kam
    get new_import_path
    assert_response :success
  end

  test "a plain AM cannot reach an admin-only page (import)" do
    sign_in @am
    get new_import_path
    assert_redirected_to root_path
  end

  test "a KAM can create a new AM, same as an admin" do
    sign_in @kam
    assert_difference "User.count", 1 do
      post users_path, params: { user: { name: "New Hire", email: "new-hire@example.com" } }
    end
  end

  test "a KAM can edit another AM's contract-of-record fields (admin-only for a plain AM)" do
    company = Company.create!(name: "Client Kam Priv", user: @am)
    deal = ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "kam-priv-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours")

    sign_in @kam
    patch deal_path(deal), params: { deal: { arr: 20_000 }, redirect_user_id: @am.id }
    deal.reload
    assert_in_delta 20_000, deal.arr, 0.01
  end

  test "a KAM can toggle another user's KAM status, same as an admin" do
    sign_in @kam
    other = User.create!(email: "other-priv@example.com", name: "Other Priv", active: true)
    patch user_path(other), params: { kam: "1" }
    other.reload
    assert other.kam?
  end
end
