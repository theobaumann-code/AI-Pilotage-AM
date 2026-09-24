require "test_helper"

class AppSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-settings@example.com", name: "Admin Settings", admin: true, active: true)
    @am = User.create!(email: "am-settings@example.com", name: "AM Settings", admin: false, active: true)
  end

  test "an admin can update the non accompagné figures together" do
    sign_in @admin
    patch app_setting_path, params: { arr_non_accompagne: "12345.67", churn_non_accompagne: "678.9", taux_renouvellement_non_accompagne: "3.5" }
    assert_redirected_to pilotage_path
    AppSetting.instance.tap do |s|
      assert_in_delta 12_345.67, s.arr_non_accompagne, 0.01
      assert_in_delta 678.9, s.churn_non_accompagne, 0.01
      assert_in_delta 3.5, s.taux_renouvellement_non_accompagne, 0.01
    end
  end

  test "a non-admin cannot update the non accompagné figures" do
    sign_in @am
    patch app_setting_path, params: { arr_non_accompagne: "999", churn_non_accompagne: "999", taux_renouvellement_non_accompagne: "99" }
    AppSetting.instance.tap do |s|
      assert_not_equal 999, s.arr_non_accompagne
      assert_not_equal 999, s.churn_non_accompagne
      assert_not_equal 99, s.taux_renouvellement_non_accompagne
    end
  end

  test "an admin can still update annee_en_cours through the same action" do
    sign_in @admin
    patch app_setting_path, params: { annee_en_cours: "2030" }
    assert_redirected_to historique_path
    assert_equal 2030, AppSetting.instance.annee_en_cours
  end

  test "Vue globale shows the current non accompagné figures" do
    AppSetting.instance.update!(arr_non_accompagne: 54_000, churn_non_accompagne: 3_000, taux_renouvellement_non_accompagne: 2.5)
    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_match "Portefeuille non accompagné", @response.body
    assert_match "54,000", @response.body
    assert_match "3,000", @response.body
    assert_match "2.5%", @response.body
  end

  test "only an admin sees the edit control for the non accompagné figures on Vue globale" do
    sign_in @am
    get pilotage_path
    assert_response :success
    assert_no_match app_setting_path, @response.body
  end
end
