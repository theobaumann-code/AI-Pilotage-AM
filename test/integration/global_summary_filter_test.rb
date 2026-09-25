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

  test "filtering by team (role) narrows the summary cards" do
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
  end

  test "the non-accompagné book counts toward the total by default (no filter at all)" do
    AppSetting.instance.update!(arr_non_accompagne: 5_000, churn_non_accompagne: 0, taux_renouvellement_non_accompagne: 0)

    sign_in @admin
    get pilotage_path
    assert_response :success
    global_cards = @response.body[/id="global-summary-cards">.*?(?=<div class="section-card">)/m]
    assert_match "115,000", global_cards # 10_000 + 100_000 + 5_000
  end

  test "narrowing to a specific role drops the non-accompagné book unless it's re-checked" do
    AppSetting.instance.update!(arr_non_accompagne: 5_000, churn_non_accompagne: 0, taux_renouvellement_non_accompagne: 0)

    sign_in @admin
    get pilotage_path, params: { summary_roles: ["AM"] }
    assert_response :success
    global_cards = @response.body[/id="global-summary-cards">.*?(?=<div class="section-card">)/m]
    assert_match "110,000", global_cards # both AMs, no non-accompagné
    assert_no_match "115,000", global_cards

    get pilotage_path, params: { summary_roles: ["AM", "Non accompagné"] }
    assert_response :success
    global_cards = @response.body[/id="global-summary-cards">.*?(?=<div class="section-card">)/m]
    assert_match "115,000", global_cards # both AMs plus non-accompagné, explicitly re-checked
  end

  test "checking only Non accompagné isolates it from every AM's own book" do
    AppSetting.instance.update!(arr_non_accompagne: 5_000, churn_non_accompagne: 0, taux_renouvellement_non_accompagne: 0)

    sign_in @admin
    get pilotage_path, params: { summary_roles: ["Non accompagné"] }
    assert_response :success
    global_cards = @response.body[/id="global-summary-cards">.*?(?=<div class="section-card">)/m]
    assert_match "5,000", global_cards
    assert_no_match "10,000", global_cards
    assert_no_match "100,000", global_cards
  end
end
