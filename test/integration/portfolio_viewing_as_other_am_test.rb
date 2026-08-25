require "test_helper"

# Regression test for a real production bug: an admin viewing another AM's portfolio (Mon portefeuille,
# switched via the AM selector) edits a deal, and the summary cards at the top flip to the *admin's own*
# portfolio numbers instead of staying on the AM being viewed. Root cause was ApplicationController#viewed_user
# only checking params[:user_id] (present on the page's initial GET) while the inline-edit turbo_stream
# response re-renders the row's own next edit-form URL by calling viewed_user again — but that PATCH request
# only carries params[:redirect_user_id], so it silently fell back to current_user (the admin).
class PortfolioViewingAsOtherAmTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-int@example.com", password: "password123", name: "Admin Int", admin: true, active: true)
    # A distinctive ARR on the admin's own portfolio: if the bug regresses and the summary cards fall back
    # to computing from the admin instead of the viewed AM, this exact value would leak into the response.
    admin_company = Company.create!(name: "Admin Own Client", user: @admin)
    ProduitDeal.create!(company: admin_company, produit: "Mutuelle", college: "Cadre", assureur: "AXA",
      identifiant: "admin-1", arr: 99_000, taux: 0, statut_renouvellement: "En cours")

    @other_am = User.create!(email: "other-int@example.com", password: "password123", name: "Other AM", admin: false, active: true)
    @company = Company.create!(name: "Client Other AM", user: @other_am)
    @deal = ProduitDeal.create!(company: @company, produit: "Mutuelle", college: "Cadre", assureur: "AXA",
      identifiant: "int-1", arr: 10_000, taux: 2, statut_renouvellement: "En cours")

    sign_in @admin
  end

  test "repeated inline edits while viewing another AM's portfolio never leak the admin's own numbers" do
    patch deal_path(@deal), params: { deal: { taux: 3 }, redirect_user_id: @other_am.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "10,300", @response.body
    assert_no_match "99,000", @response.body

    # The second edit is the one that used to break: the first response's row re-render had already baked
    # the wrong redirect_user_id into the row's next form action.
    patch deal_path(@deal), params: { deal: { statut_renouvellement: "Augmenté" }, redirect_user_id: @other_am.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "10,300", @response.body
    assert_no_match "99,000", @response.body
  end
end
