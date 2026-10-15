require "test_helper"

# "Autres impacts": manual one-off ARR impacts per client on Mon portefeuille, admin/KAM only. Validé lines
# feed the KPIs (ARR final, NRR); En cours lines only feed the section's own Projeté total.
class OtherImpactsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-impact@example.com", name: "Admin Impact", admin: true, active: true)
    @kam = User.create!(email: "kam-impact@example.com", name: "KAM Impact", kam: true, active: true)
    @am = User.create!(email: "am-impact@example.com", name: "AM Impact", active: true)
    @reader = User.create!(email: "reader-impact@example.com", name: "Lecteur Impact", role: "Lecteur", active: true)
    @alpha = Company.create!(name: "Alpha Impact", user: @am)
    @churned = Company.create!(name: "Zeta Churné", user: @am)
    ProduitDeal.create!(company: @alpha, produit: "Mutuelle", identifiant: "oi-1", college: "Cadre", assureur: "AXA",
      arr: 10_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: @churned, produit: "Prévoyance", identifiant: "oi-2", college: "Cadre", assureur: "AXA",
      arr: 5_000, taux: 0, statut_renouvellement: "Churné")
  end

  def summary
    PortfolioSummary.new(@am.companies.includes(:produit_deals, :upsell_deals, :current_other_impacts), user: @am)
  end

  test "Validé lines move only the actual KPIs, En cours lines only the projected ones" do
    base = summary
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    OtherImpact.create!(company: @alpha, amount: "1000", statut: "Validé")
    OtherImpact.create!(company: @churned, amount: "7000", statut: "En cours")

    s = summary
    assert_in_delta(-2000, s.other_impacts_validated, 0.001)
    assert_in_delta 7000, s.other_impacts_pending, 0.001

    # actual side: Validé only (-2000), the En cours 7000 stays out
    assert_in_delta base.arr_final_actual - 2000, s.arr_final_actual, 0.001
    assert_in_delta base.nrr_actual - 2000.0 / base.arr_initial * 100, s.nrr_actual, 0.001
    # projected side: En cours only (+7000), the Validé -2000 stays out
    assert_in_delta base.arr_final + 7000, s.arr_final, 0.001
    assert_in_delta base.nrr + 7000.0 / base.arr_initial * 100, s.nrr, 0.001
    assert_in_delta base.arr_initial, s.arr_initial, 0.001, "the starting ARR is untouched"
  end

  test "a line only ever counts on one side: switching its status moves it from projected to actual" do
    base = summary
    impact = OtherImpact.create!(company: @alpha, amount: "4000", statut: "En cours")
    assert_in_delta base.nrr_actual, summary.nrr_actual, 0.001
    assert_in_delta base.arr_final + 4000, summary.arr_final, 0.001

    impact.update!(statut: "Validé")
    assert_in_delta base.nrr, summary.nrr, 0.001
    assert_in_delta base.arr_final, summary.arr_final, 0.001
    assert_in_delta base.arr_final_actual + 4000, summary.arr_final_actual, 0.001
  end

  test "impacts from a previous year no longer count once the year has been closed" do
    OtherImpact.create!(company: @alpha, amount: "5000", statut: "Validé")
    assert_in_delta 5000, summary.other_impacts_validated, 0.001

    setting = AppSetting.instance
    setting.update!(annee_en_cours: setting.annee_en_cours + 1)
    assert_in_delta 0, summary.other_impacts_validated, 0.001
    assert_equal 1, OtherImpact.count, "nothing is deleted, the line just belongs to the closed year"
  end

  test "an admin adds a ready-to-edit line with the button, on that AM's page" do
    sign_in @admin
    assert_difference "OtherImpact.count", 1 do
      post other_impacts_path(redirect_user_id: @am.id)
    end
    assert_redirected_to portfolio_path(user_id: @am.id, anchor: "other-impacts")
    impact = OtherImpact.last
    assert_equal @alpha, impact.company, "first client alphabetically"
    assert_equal ["Mutuelle", "En cours", 0], [impact.produit, impact.statut, impact.amount]
  end

  test "an AM with no client can't get a line" do
    sign_in @admin
    empty = User.create!(email: "empty-impact@example.com", name: "AM Vide", active: true)
    assert_no_difference "OtherImpact.count" do
      post other_impacts_path(redirect_user_id: empty.id)
    end
    assert_match "aucun client", flash[:alert].to_s
  end

  test "KAMs can use it, regular AMs and lecteurs cannot (not even on their own portfolio)" do
    sign_in @kam
    assert_difference "OtherImpact.count", 1 do
      post other_impacts_path(redirect_user_id: @am.id)
    end
    impact = OtherImpact.last

    [@am, @reader].each do |user|
      sign_out :user
      sign_in user
      assert_no_difference "OtherImpact.count" do
        post other_impacts_path(redirect_user_id: @am.id)
        delete other_impact_path(impact)
      end
      patch other_impact_path(impact), params: { other_impact: { amount: "999", statut: "Validé" } }
      assert_equal 0, impact.reload.amount
      assert_equal "En cours", impact.statut
    end
  end

  test "editing a line in place re-renders it with the KPI cards and the totals, whatever its status" do
    impact = OtherImpact.create!(company: @alpha, amount: 100, statut: "En cours")
    sign_in @admin

    patch other_impact_path(impact, redirect_user_id: @am.id),
      params: { other_impact: { company_id: @churned.id, produit: "Les deux", amount: "-3 000,5", comment: "Avenant", statut: "Validé" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "portfolio-summary-cards", @response.body
    assert_match "other-impacts-totals", @response.body
    assert_match dom_id_for(impact), @response.body

    impact.reload
    assert_equal [@churned, "Les deux", "Avenant", "Validé"], [impact.company, impact.produit, impact.comment, impact.statut]
    assert_in_delta(-3000.5, impact.amount.to_f, 0.001)

    # a Validé line stays freely editable — back to En cours, a different amount
    patch other_impact_path(impact, redirect_user_id: @am.id), params: { other_impact: { statut: "En cours", amount: "42" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_equal ["En cours", 42], [impact.reload.statut, impact.amount.to_i]
  end

  def dom_id_for(record)
    ActionView::RecordIdentifier.dom_id(record)
  end

  test "an invalid amount is refused with a message and leaves the line as it was" do
    impact = OtherImpact.create!(company: @alpha, amount: 250)
    sign_in @admin
    patch other_impact_path(impact, redirect_user_id: @am.id), params: { other_impact: { amount: "beaucoup" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :unprocessable_entity
    assert_match "doit être un nombre", @response.body
    assert_equal 250, impact.reload.amount
  end

  test "an admin deletes a line" do
    impact = OtherImpact.create!(company: @alpha, amount: 1, statut: "Validé")
    sign_in @admin
    assert_difference "OtherImpact.count", -1 do
      delete other_impact_path(impact, redirect_user_id: @am.id)
    end
    assert_redirected_to portfolio_path(user_id: @am.id, anchor: "other-impacts")
  end

  test "the page: orange button and editable table for admins, with every client (churned too) in the select" do
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    assert_response :success
    assert_match(/<button class="button primary" type="submit">\+ Autre impact<\/button>/, @response.body)
    assert_match "Autres impacts", @response.body
    assert_match "Aucun autre impact pour le moment", @response.body

    OtherImpact.create!(company: @alpha, amount: 10)
    get portfolio_path(user_id: @am.id)
    select = @response.body[/<select[^>]*other_impact\[company_id\].*?<\/select>/m]
    assert_match "Alpha Impact", select
    assert_match "Zeta Churné", select
    assert_match "Mutuelle", @response.body[/other_impact\[produit\].*?<\/select>/m]
    assert_match "Les deux", @response.body[/other_impact\[produit\].*?<\/select>/m]
  end

  test "an AM sees their totals, and a read-only table only when they have impacts, but no button" do
    sign_in @am
    get portfolio_path
    assert_no_match "Autre impact</button>", @response.body
    assert_match "other-impacts-totals", @response.body, "the totals section is on every page"
    assert_no_match 'id="other-impacts"', @response.body

    OtherImpact.create!(company: @alpha, amount: "-3000", comment: "Avenant", statut: "Validé")
    get portfolio_path
    assert_match 'id="other-impacts"', @response.body
    assert_match "Avenant", @response.body
    assert_no_match 'name="other_impact[amount]"', @response.body
    assert_no_match "Autre impact</button>", @response.body
  end

  test "the totals card shows Projeté (En cours) and Actuel (Validé)" do
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    OtherImpact.create!(company: @alpha, amount: "8000", statut: "En cours")
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    card = @response.body[/id="other-impacts-totals".*?<\/div>\s*<\/div>\s*<\/div>/m]
    assert_match(/Projeté[\s\S]*?8,000 €/, card)
    assert_match(/Actuel[\s\S]*?-3,000 €/, card)
  end

  test "Vue globale's KPIs include Validé impacts too, as every AM's figures do" do
    sign_in @admin
    get pilotage_path
    before = @controller.instance_variable_get(:@global_summary).arr_final_actual
    OtherImpact.create!(company: @alpha, amount: "4000", statut: "Validé")
    get pilotage_path
    assert_in_delta before + 4000, @controller.instance_variable_get(:@global_summary).arr_final_actual, 0.001
  end
end
