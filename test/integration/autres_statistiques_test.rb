require "test_helper"

# The "Renouvellements : nouveau contrat vs augmentation" chart moved off Vue globale onto its own page —
# open to the same audience Vue globale itself is (no restriction), since it's just a different slice of
# the same reporting data, not a rights-management action.
class AutresStatistiquesTest < ActionDispatch::IntegrationTest
  test "any signed-in user can see it, including a plain AM" do
    am = User.create!(email: "am-autres@example.com", name: "AM Autres", admin: false, active: true)
    sign_in am
    get autres_statistiques_path
    assert_response :success
    assert_match "Renouvellements : nouveau contrat vs augmentation", @response.body
  end
end
