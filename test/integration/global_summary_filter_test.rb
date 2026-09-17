require "test_helper"

# Vue globale's top summary cards (ARR initial, churn, NRR...) default to every AM combined — this filter
# lets an admin narrow that same set of cards down to one or more chosen AMs without leaving the page.
class GlobalSummaryFilterTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-gsum@example.com", name: "Admin Gsum", admin: true, active: true)
    @am_a = User.create!(email: "a-gsum@example.com", name: "AM A Gsum", active: true)
    @am_b = User.create!(email: "b-gsum@example.com", name: "AM B Gsum", active: true)
    ProduitDeal.create!(company: Company.create!(name: "Client A Gsum", user: @am_a), produit: "Mutuelle",
      identifiant: "gsum-a", college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: Company.create!(name: "Client B Gsum", user: @am_b), produit: "Mutuelle",
      identifiant: "gsum-b", college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
  end

  test "no filter shows every AM's ARR combined" do
    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_match(/id="global-summary-cards".*?110,000/m, @response.body)
  end

  test "filtering by one AM narrows the summary cards to just that AM's ARR" do
    sign_in @admin
    get pilotage_path, params: { summary_ams: [@am_a.name] }
    assert_response :success
    global_cards = @response.body[/id="global-summary-cards">.*?(?=<div class="section-card">)/m]
    assert_match "10,000", global_cards
    assert_no_match "100,000", global_cards
  end

  test "filtering by team (role) narrows both the summary cards and the AM roster" do
    kam = User.create!(email: "kam-gsum@example.com", name: "Kam Gsum", kam: true, active: true)
    ProduitDeal.create!(company: Company.create!(name: "Client Kam Gsum", user: kam), produit: "Mutuelle",
      identifiant: "gsum-kam", college: "Cadre", assureur: "AXA", arr: 1_000, taux: 0, statut_renouvellement: "En cours")

    sign_in @admin
    get pilotage_path, params: { summary_roles: ["KAM"] }
    assert_response :success
    global_cards = @response.body[/id="global-summary-cards">.*?(?=<div class="section-card">)/m]
    assert_match "1,000", global_cards
    assert_no_match "10,000", global_cards
    assert_no_match "100,000", global_cards

    # Scoped to the roster table itself, not the whole page — the reassign-target <select> deliberately
    # lists every active AM regardless of this filter, so a whole-body check would false-fail on it.
    roster = @response.body[/id="am-table-frame">.*?<\/table>/m]
    assert_match "Kam Gsum", roster
    assert_no_match "AM A Gsum", roster
    assert_no_match "AM B Gsum", roster
  end
end
