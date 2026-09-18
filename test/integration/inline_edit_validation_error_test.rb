require "test_helper"

# Regression test for a real production bug: clearing a produit's "Taux négocié" field (or otherwise
# submitting an inline edit that fails validation) made the whole "Taux de renouvellement et churn" table
# disappear, replaced by Turbo's "Content missing" placeholder. Root cause: the invalid-update branch
# responded with `head :unprocessable_entity` — a 422 with an empty body — but the inline-edit form lives
# inside a turbo-frame, so Turbo tried to extract that frame's content from the (empty) response and, finding
# none, blanked the whole frame instead of just the row. The fix re-renders the row (reverted to its last
# valid value) plus a flash message, so Turbo always has real content to work with.
class InlineEditValidationErrorTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "am-inline-error@example.com", name: "AM Inline Error", active: true)
    @company = Company.create!(name: "Client Inline Error", user: @am)
    @deal = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "inline-err-1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 2, statut_renouvellement: "En cours")
    sign_in @am
  end

  test "an invalid inline edit returns a real turbo_stream body instead of an empty 422" do
    patch deal_path(@deal), params: { deal: { taux: "" }, redirect_user_id: @am.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_not @response.body.blank?, "an empty body leaves Turbo with nothing to swap into the row's frame"
    assert_match "turbo-stream", @response.body
    assert_match ActionView::RecordIdentifier.dom_id(@deal), @response.body

    @deal.reload
    assert_equal 2, @deal.taux.to_i, "the persisted value must be untouched by the rejected edit"
  end

  test "the row shown after a rejected edit reverts to the last valid value, not the invalid attempt" do
    patch deal_path(@deal), params: { deal: { taux: "" }, redirect_user_id: @am.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_match "value=\"2.0\"", @response.body
  end

  test "the flash area is updated with the validation error" do
    patch deal_path(@deal), params: { deal: { taux: "" }, redirect_user_id: @am.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_match "flash", @response.body
    assert_match(/not a number/i, @response.body)
  end
end
