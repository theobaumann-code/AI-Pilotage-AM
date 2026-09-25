require "test_helper"

# The shared checklist-filter dropdown submits on every checkbox change (see onchange in the partial),
# which reloads the whole page — a plain <details> defaults back to closed on that reload, forcing a
# re-click before the next box could be checked. It must render <details open> whenever something is
# already selected, so picking several options in a row doesn't require reopening the filter each time.
class ChecklistFilterTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-checklist@example.com", name: "Admin Checklist", admin: true, active: true)
    sign_in @admin
  end

  def equipe_filter_block(body)
    block = body[/<details class="checklist-filter"[^>]*>.*?Équipe.*?<\/details>/m]
    assert block, "expected to find the Équipe filter block in the response"
    block[/<details class="checklist-filter"[^>]*>/]
  end

  test "a filter with no selection renders its <details> closed" do
    get pilotage_path
    assert_response :success
    assert_no_match(/\bopen\b/, equipe_filter_block(@response.body))
  end

  test "a filter with an active selection renders its <details> open" do
    get pilotage_path, params: { summary_roles: ["KAM"] }
    assert_response :success
    assert_match(/\bopen\b/, equipe_filter_block(@response.body))
  end
end
