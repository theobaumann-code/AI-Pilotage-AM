require "test_helper"

class ResultatsKamTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "plain-am-rk@example.com", password: "password123", name: "Plain AM", active: true)
    @kam = User.create!(email: "kam-rk@example.com", password: "password123", name: "Some KAM", active: true, kam: true)
    @admin = User.create!(email: "admin-rk@example.com", password: "password123", name: "Some Admin", active: true, admin: true)
  end

  test "a plain AM is redirected away from Résultats KAM" do
    sign_in @am
    get resultats_kam_path
    assert_redirected_to root_path
  end

  test "a KAM can view Résultats KAM" do
    sign_in @kam
    get resultats_kam_path
    assert_response :success
  end

  test "an admin can view Résultats KAM" do
    sign_in @admin
    get resultats_kam_path
    assert_response :success
  end

  test "everyone, including a plain AM, can view Résultats AM" do
    sign_in @am
    get pilotage_path
    assert_response :success
  end

  test "Résultats AM's roster only lists plain AM users, not KAM or admin" do
    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_match @am.name, @response.body

    # The reassign-target dropdown deliberately lists everyone regardless of role, so a bare "does the KAM's
    # name appear anywhere on the page" check would false-positive on it — search the roster specifically.
    get pilotage_path, params: { am_q: @kam.name }
    assert_match "Aucun utilisateur configuré", @response.body
    get pilotage_path, params: { am_q: @admin.name }
    assert_match "Aucun utilisateur configuré", @response.body
  end

  test "Résultats KAM's roster only lists KAM users, not plain AM or admin" do
    sign_in @admin
    get resultats_kam_path
    assert_response :success
    assert_match @kam.name, @response.body

    get resultats_kam_path, params: { am_q: @am.name }
    assert_match "Aucun utilisateur configuré", @response.body
    get resultats_kam_path, params: { am_q: @admin.name }
    assert_match "Aucun utilisateur configuré", @response.body
  end
end
