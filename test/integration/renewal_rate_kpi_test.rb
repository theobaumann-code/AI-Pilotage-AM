require "test_helper"

# The "Taux de renouvellement" KPI card shows Actuel and Projeté, like the other cards, on Mon portefeuille
# (each user's own) and on Vue globale.
class RenewalRateKpiTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-rrk@example.com", name: "Admin RRK", admin: true, active: true)
    @am = User.create!(email: "am-rrk@example.com", name: "AM RRK", active: true)
    company = Company.create!(name: "Client RRK", user: @am)
    # actual: (10 000 + 4 000) / 200 000 = 7.0% ; projected: (10 000 × 50% + 4 000) / 200 000 = 4.5%
    ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rrk-1", college: "Cadre", assureur: "AXA",
      arr: 100_000, taux: 10, statut_renouvellement: "En cours", risque_churn: 50)
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rrk-2", college: "Cadre", assureur: "AXA",
      arr: 100_000, taux: 4, statut_renouvellement: "En cours", risque_churn: 0)
  end

  def card(body, dom_id)
    block = body[/id="#{dom_id}".*?<\/main>/m]
    block[/<div class="metric-card[^"]*">\s*<div class="metric-card-title">Taux de renouvellement<\/div>.*?<\/div>\s*<\/div>\s*<\/div>\s*<\/div>/m]
  end

  test "Mon portefeuille shows the actual and the projected renewal rate, each with its objective badge" do
    sign_in @am
    get portfolio_path
    assert_response :success
    html = card(@response.body, "portfolio-summary-cards")
    assert_match(/Actuel[\s\S]*?7\.0%[\s\S]*?✓ Objectif 5\.0%[\s\S]*?Projeté[\s\S]*?4\.5%[\s\S]*?✗ Objectif 5\.0%/, html)
  end

  test "an admin viewing another user's portfolio sees that user's rates" do
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    html = card(@response.body, "portfolio-summary-cards")
    assert_match(/7\.0%[\s\S]*?4\.5%/, html)
  end

  test "Vue globale shows both rates too, and they follow its Équipe/AM filters" do
    sign_in @admin
    get pilotage_path
    html = card(@response.body, "global-summary-cards")
    assert_match(/Actuel[\s\S]*?Projeté/, html)
    summary = @controller.instance_variable_get(:@global_summary)
    assert_match "#{ActionController::Base.helpers.number_with_precision(summary.renewal_rate_projected, precision: 1)}%", html

    get pilotage_path, params: { summary_ams: [ @am.name ] }
    html = card(@response.body, "global-summary-cards")
    assert_match(/7\.0%[\s\S]*?4\.5%/, html)
  end

  test "an inline edit re-renders the card with both rates" do
    sign_in @admin
    deal = ProduitDeal.find_by!(identifiant: "rrk-2")
    patch deal_path(deal, redirect_user_id: @am.id), params: { deal: { taux: 10 } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    # (10 000 + 10 000) / 200 000 = 10.0% actual ; (10 000 × 50% + 10 000) / 200 000 = 7.5% projected
    assert_match(/Taux de renouvellement[\s\S]*?10\.0%[\s\S]*?Projeté[\s\S]*?7\.5%/, @response.body)
  end
end
