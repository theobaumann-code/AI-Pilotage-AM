require "test_helper"

class NonAccompagneChurnEntriesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-naentries@example.com", name: "Admin Entries", admin: true, active: true)
    @am = User.create!(email: "am-naentries@example.com", name: "AM Entries", admin: false, active: true)
  end

  test "an admin can create an entry, which is reflected in AppSetting#churn_non_accompagne" do
    sign_in @admin
    post non_accompagne_churn_entries_path, params: { non_accompagne_churn_entry: { company_name: "Acme", amount: "1200.5" } }
    assert_redirected_to pilotage_path

    entry = NonAccompagneChurnEntry.find_by(company_name: "Acme")
    assert_in_delta 1200.5, entry.amount, 0.01
    assert_in_delta 1200.5, AppSetting.instance.churn_non_accompagne, 0.01
  end

  test "an admin can update an entry" do
    entry = NonAccompagneChurnEntry.create!(company_name: "Acme", amount: 100)
    sign_in @admin
    patch non_accompagne_churn_entry_path(entry), params: { non_accompagne_churn_entry: { company_name: "Autre", amount: "250" } }
    assert_redirected_to pilotage_path

    entry.reload
    assert_equal "Autre", entry.company_name
    assert_in_delta 250, entry.amount, 0.01
  end

  test "an admin can delete an entry" do
    entry = NonAccompagneChurnEntry.create!(company_name: "Acme", amount: 100)
    sign_in @admin
    assert_difference "NonAccompagneChurnEntry.count", -1 do
      delete non_accompagne_churn_entry_path(entry)
    end
    assert_redirected_to pilotage_path
  end

  test "invalid params redirect back with an alert instead of raising" do
    sign_in @admin
    post non_accompagne_churn_entries_path, params: { non_accompagne_churn_entry: { company_name: "", amount: "100" } }
    assert_redirected_to pilotage_path
    assert_equal 0, NonAccompagneChurnEntry.count
  end

  test "a non-admin cannot create, update or delete entries" do
    entry = NonAccompagneChurnEntry.create!(company_name: "Acme", amount: 100)
    sign_in @am

    assert_no_difference "NonAccompagneChurnEntry.count" do
      post non_accompagne_churn_entries_path, params: { non_accompagne_churn_entry: { company_name: "Autre", amount: "50" } }
    end

    patch non_accompagne_churn_entry_path(entry), params: { non_accompagne_churn_entry: { amount: "999" } }
    assert_in_delta 100, entry.reload.amount, 0.01

    assert_no_difference "NonAccompagneChurnEntry.count" do
      delete non_accompagne_churn_entry_path(entry)
    end
  end
end
