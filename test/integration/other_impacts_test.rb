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

  def create_params(overrides = {})
    { other_impact: { company_id: @alpha.id, produit: "Les deux", amount: "-3000", comment: "Avenant", statut: "Validé" }.merge(overrides) }
  end

  test "the pop-up creates the line with everything it was filled with, on that AM's page" do
    sign_in @admin
    assert_difference "OtherImpact.count", 1 do
      post other_impacts_path(redirect_user_id: @am.id), params: create_params
    end
    assert_redirected_to portfolio_path(user_id: @am.id, anchor: "other-impacts")
    impact = OtherImpact.last
    assert_equal [@alpha, "Les deux", "Avenant", "Validé"], [impact.company, impact.produit, impact.comment, impact.statut]
    assert_in_delta(-3000, impact.amount.to_f, 0.001)
    assert_equal AppSetting.instance.annee_en_cours, impact.annee
  end

  test "a pop-up submission with a bad amount creates nothing and says why" do
    sign_in @admin
    assert_no_difference "OtherImpact.count" do
      post other_impacts_path(redirect_user_id: @am.id), params: create_params(amount: "beaucoup")
    end
    assert_match "doit être un nombre", flash[:alert].to_s
  end

  test "KAMs can use it, regular AMs and lecteurs cannot (not even on their own portfolio)" do
    sign_in @kam
    assert_difference "OtherImpact.count", 1 do
      post other_impacts_path(redirect_user_id: @am.id), params: create_params(statut: "En cours", amount: "0")
    end
    impact = OtherImpact.last

    [@am, @reader].each do |user|
      sign_out :user
      sign_in user
      assert_no_difference "OtherImpact.count" do
        post other_impacts_path(redirect_user_id: @am.id), params: create_params
        delete other_impact_path(impact)
      end
      patch other_impact_path(impact), params: { other_impact: { amount: "999", statut: "Validé" } }
      assert_equal 0, impact.reload.amount
      assert_equal "En cours", impact.statut
    end
  end

  test "editing a line in place re-renders it with the KPI cards and the client rows, whatever its status" do
    impact = OtherImpact.create!(company: @alpha, amount: 100, statut: "En cours")
    sign_in @admin

    patch other_impact_path(impact, redirect_user_id: @am.id),
      params: { other_impact: { company_id: @churned.id, produit: "Les deux", amount: "-3 000,5", comment: "Avenant", statut: "Validé" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "portfolio-summary-cards", @response.body
    assert_match "other-impacts-totals", @response.body, "the Autres impacts card is part of the KPI cards"
    assert_match dom_id_for(impact), @response.body
    assert_match dom_id_for(@alpha), @response.body, "the client it left is refreshed"
    assert_match dom_id_for(@churned), @response.body, "and the one it moved to"

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

  test "the page: orange button opening a pop-up with every field, and the editable table at the bottom" do
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    assert_response :success
    assert_match(/<button type="button" class="button primary" onclick="document.getElementById\('other-impact-dialog'\).showModal\(\)">\+ Autre impact<\/button>/, @response.body)

    dialog = @response.body[/<dialog id="other-impact-dialog".*?<\/dialog>/m]
    assert dialog, "the pop-up is on the page"
    assert_match(/action="\/other_impacts\?redirect_user_id=#{@am.id}"/, dialog)
    %w[company_id produit amount comment statut].each { |field| assert_match "other_impact[#{field}]", dialog }
    assert_match "Alpha Impact", dialog
    assert_match "Zeta Churné", dialog, "churned clients are offered too"
    assert_match "Les deux", dialog
    assert_match(/other_impact\[statut\][^>]*><option selected="selected" value="En cours">/, dialog, "statut starts on En cours")
    assert_match(/other_impact\[produit\][^>]*><option selected="selected" value="Mutuelle">/, dialog, "produit starts on Mutuelle")
    amount_input = dialog[/<input[^>]*name="other_impact\[amount\]"[^>]*>/]
    assert_match(/value=""/, amount_input, "the amount starts empty, not at 0.0")
    assert_no_match(/<option value=""><\/option>/, dialog[/other_impact\[produit\].*?<\/select>/m])
    assert_no_match(/<option value=""><\/option>/, dialog[/other_impact\[statut\].*?<\/select>/m])
    assert_match "Choisir un client", dialog
    assert_match "Valider", dialog
    assert_match "Annuler", dialog

    assert_match "Aucun autre impact pour le moment", @response.body
    OtherImpact.create!(company: @alpha, amount: 10)
    get portfolio_path(user_id: @am.id)
    table = @response.body[/id="other-impacts">.*?<\/table>/m]
    assert_match "other_impact[amount]", table
    assert_match "Zeta Churné", table[/<select[^>]*other_impact\[company_id\].*?<\/select>/m]
  end

  test "an AM sees the Autres impacts card, a read-only table only when they have impacts, no button and no pop-up" do
    sign_in @am
    get portfolio_path
    assert_no_match "+ Autre impact", @response.body
    assert_no_match 'id="other-impact-dialog"', @response.body
    assert_match "other-impacts-totals", @response.body, "the card is on every page"
    assert_no_match 'id="other-impacts"', @response.body

    OtherImpact.create!(company: @alpha, amount: "-3000", comment: "Avenant", statut: "Validé")
    get portfolio_path
    assert_match 'id="other-impacts"', @response.body
    assert_match "Avenant", @response.body
    assert_no_match 'name="other_impact[amount]"', @response.body
  end

  test "the KPI card sits in the summary grid after Taux de renouvellement, Actuel (Validé) then Projeté (En cours)" do
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    OtherImpact.create!(company: @alpha, amount: "8000", statut: "En cours")
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    cards = @response.body[/id="portfolio-summary-cards".*?<\/main>/m]
    assert_match(/summary-cards metrics-grid with-other-impacts/, cards)
    assert cards.index("Taux de renouvellement") < cards.index("other-impacts-totals"), "after the Taux card"
    card = cards[/id="other-impacts-totals".*?<\/div>\s*<\/div>\s*<\/div>/m]
    assert_match(/Actuel[\s\S]*?-3,000 €[\s\S]*?Projeté[\s\S]*?8,000 €/, card)
    assert_match(/metric-card--compact/, cards[/<div class="metric-card[^"]*" id="other-impacts-totals"/])
  end

  test "Vue globale has its own Autres impacts card with the global totals, after Taux de renouvellement" do
    other_am = User.create!(email: "am2-impact@example.com", name: "AM Deux Impact", active: true)
    other_company = Company.create!(name: "Client Deux Impact", user: other_am)
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    OtherImpact.create!(company: other_company, amount: "1000", statut: "Validé")
    OtherImpact.create!(company: other_company, amount: "8000", statut: "En cours")
    OtherImpact.create!(company: @alpha, amount: "500", statut: "En cours")

    sign_in @admin
    get pilotage_path
    assert_response :success
    cards = @response.body[/id="global-summary-cards".*?<\/main>/m]
    assert_match(/summary-cards metrics-grid with-other-impacts/, cards)
    assert cards.index("Taux de renouvellement") < cards.index("other-impacts-totals")
    card = cards[/id="other-impacts-totals".*?<\/div>\s*<\/div>\s*<\/div>/m]
    assert_match(/Actuel[\s\S]*?-2,000 €[\s\S]*?Projeté[\s\S]*?8,500 €/, card, "validated -3000 + 1000 across both AMs, pending 8000 + 500")

    # the Équipe/AM filters of the page narrow it too
    get pilotage_path, params: { summary_ams: [@am.name] }
    card = @response.body[/id="other-impacts-totals".*?<\/div>\s*<\/div>\s*<\/div>/m]
    assert_match(/Actuel[\s\S]*?-3,000 €[\s\S]*?Projeté[\s\S]*?500 €/, card)
  end

  test "the impacts are not folded into Upsell or Churn" do
    base_summary = summary
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    OtherImpact.create!(company: @alpha, amount: "-2000", statut: "En cours")
    OtherImpact.create!(company: @alpha, amount: "7000", statut: "Validé")

    s = summary
    assert_in_delta base_summary.churned, s.churned, 0.001
    assert_in_delta base_summary.churn_total, s.churn_total, 0.001
    assert_in_delta base_summary.churn_rate, s.churn_rate, 0.001
    assert_in_delta base_summary.upsold, s.upsold, 0.001
    assert_in_delta base_summary.upsold_actual, s.upsold_actual, 0.001
  end

  test "Évolution de l'ARR par client: an Autre impact column before ARR final, validated amounts only, added to ARR final" do
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    OtherImpact.create!(company: @alpha, amount: "500", statut: "Validé")
    OtherImpact.create!(company: @alpha, amount: "9999", statut: "En cours")
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    table = @response.body[/id="evo-table-frame">.*?<\/turbo-frame>/m]

    headers = table.scan(/<th class="[^"]*">(?:<a[^>]*>)?([^<]+)/).flatten
    assert_equal headers.index("Autre impact") + 1, headers.index("ARR final"), "right before ARR final"

    alpha_row = table[/<tr id="#{dom_id_for(@alpha)}">.*?<\/tr>/m]
    assert_match(/-2,500 €/, alpha_row, "-3000 + 500 validated, the En cours 9999 left out")
    assert_match(/<td class="computed">7,500 €<\/td>/, alpha_row, "10 000 + (-2 500) = 7 500")

    zeta_row = table[/<tr id="#{dom_id_for(@churned)}">.*?<\/tr>/m]
    assert_match(/<td class="numeric" style="color:inherit">0 €<\/td>\s*<td class="computed">0 €<\/td>/, zeta_row)

    assert_in_delta 7_500, @alpha.reload.final_arr, 0.001
    assert_in_delta(-2_500, @alpha.other_impact_arr, 0.001)
  end

  test "the client column is sortable" do
    OtherImpact.create!(company: @alpha, amount: "-3000", statut: "Validé")
    sign_in @admin
    get portfolio_path(user_id: @am.id, evo_sort: "other_impact", evo_dir: "asc")
    assert_response :success
    table = @response.body[/id="evo-table-frame">.*?<\/turbo-frame>/m]
    assert_operator table.index("Alpha Impact"), :<, table.index("Zeta Churné"), "-3000 sorts before 0"
    get portfolio_path(user_id: @am.id, evo_sort: "other_impact", evo_dir: "desc")
    table = @response.body[/id="evo-table-frame">.*?<\/turbo-frame>/m]
    assert_operator table.index("Zeta Churné"), :<, table.index("Alpha Impact")
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
