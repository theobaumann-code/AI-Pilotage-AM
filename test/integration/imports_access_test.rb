require "test_helper"

class ImportsAccessTest < ActionDispatch::IntegrationTest
  test "a plain AM cannot reach the CSV import page" do
    plain_am = User.create!(email: "plain-am-import@example.com", password: "password123", name: "Plain AM Import", active: true)
    sign_in plain_am
    get new_import_path
    assert_redirected_to root_path
  end

  test "a KAM (not admin) can reach the CSV import page" do
    kam = User.create!(email: "kam-import@example.com", password: "password123", name: "KAM Import", active: true, kam: true)
    sign_in kam
    get new_import_path
    assert_response :success
  end

  test "an admin can reach the CSV import page" do
    admin = User.create!(email: "admin-import@example.com", password: "password123", name: "Admin Import", active: true, admin: true)
    sign_in admin
    get new_import_path
    assert_response :success
  end
end
