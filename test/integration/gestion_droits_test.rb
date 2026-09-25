require "test_helper"

# The AM roster and role-management actions moved off Vue globale onto their own page — gated to whoever
# can add an AM in the first place (current_user.privileged?), since everything here is a rights-editing
# action, not a reporting view.
class GestionDroitsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-droits@example.com", name: "Admin Droits", admin: true, active: true)
    @kam = User.create!(email: "kam-droits@example.com", name: "Kam Droits", kam: true, active: true)
    @am = User.create!(email: "am-droits@example.com", name: "AM Droits", admin: false, active: true)
  end

  test "an admin can see the AM roster and the + Nouvel AM button" do
    sign_in @admin
    get gestion_droits_path
    assert_response :success
    assert_match "AM Droits", @response.body
    assert_match "+ Nouvel AM", @response.body
    assert_match "Rendre admin", @response.body
  end

  test "a KAM can also access it" do
    sign_in @kam
    get gestion_droits_path
    assert_response :success
  end

  test "a plain AM is redirected away" do
    sign_in @am
    get gestion_droits_path
    assert_redirected_to root_path
  end

  test "a plain AM does not see the nav link" do
    sign_in @am
    get pilotage_path
    assert_no_match "Gestion des droits", @response.body
  end

  test "a privileged user sees the nav link" do
    sign_in @admin
    get pilotage_path
    assert_match "Gestion des droits", @response.body
  end
end
