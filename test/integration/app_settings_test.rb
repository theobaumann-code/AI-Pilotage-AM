require "test_helper"

class AppSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-settings@example.com", name: "Admin Settings", admin: true, active: true)
    @am = User.create!(email: "am-settings@example.com", name: "AM Settings", admin: false, active: true)
  end

  test "an admin can update arr_non_accompagne" do
    sign_in @admin
    patch app_setting_path, params: { arr_non_accompagne: "12345.67" }
    assert_redirected_to pilotage_path
    assert_in_delta 12_345.67, AppSetting.instance.arr_non_accompagne, 0.01
  end

  test "a non-admin cannot update arr_non_accompagne" do
    sign_in @am
    patch app_setting_path, params: { arr_non_accompagne: "999" }
    assert_not_equal 999, AppSetting.instance.arr_non_accompagne
  end

  test "an admin can still update annee_en_cours through the same action" do
    sign_in @admin
    patch app_setting_path, params: { annee_en_cours: "2030" }
    assert_redirected_to historique_path
    assert_equal 2030, AppSetting.instance.annee_en_cours
  end

  test "Vue globale shows the current arr_non_accompagne figure" do
    AppSetting.instance.update!(arr_non_accompagne: 54_000)
    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_match "ARR non accompagné", @response.body
    assert_match "54,000", @response.body
  end

  test "only an admin sees the edit control for arr_non_accompagne on Vue globale" do
    sign_in @am
    get pilotage_path
    assert_response :success
    assert_no_match app_setting_path, @response.body
  end
end
