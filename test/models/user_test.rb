require "test_helper"

class UserTest < ActiveSupport::TestCase
  def build_user(overrides = {})
    User.new({ email: "role-test-#{rand(1_000_000)}@example.com", password: "password123", name: "Role Test", active: true }.merge(overrides))
  end

  test "role and role_label default to :am for a plain user" do
    user = build_user
    assert_equal :am, user.role
    assert_equal "AM", user.role_label
    assert_not user.kam_or_admin?
  end

  test "role and role_label reflect kam" do
    user = build_user(kam: true)
    assert_equal :kam, user.role
    assert_equal "KAM", user.role_label
    assert user.kam_or_admin?
  end

  test "admin takes priority over kam if both flags are set" do
    user = build_user(kam: true, admin: true)
    assert_equal :admin, user.role
    assert_equal "Admin", user.role_label
    assert user.kam_or_admin?
  end

  test "ams and kams scopes partition active non-admin users by the kam flag" do
    am = User.create!(email: "scope-am@example.com", password: "password123", name: "Scope AM", active: true, kam: false)
    kam = User.create!(email: "scope-kam@example.com", password: "password123", name: "Scope KAM", active: true, kam: true)
    admin = User.create!(email: "scope-admin@example.com", password: "password123", name: "Scope Admin", active: true, admin: true)
    kam_admin = User.create!(email: "scope-kam-admin@example.com", password: "password123", name: "Scope KAM Admin", active: true, kam: true, admin: true)

    assert_includes User.ams, am
    assert_not_includes User.ams, kam
    assert_not_includes User.ams, admin
    assert_not_includes User.ams, kam_admin

    assert_includes User.kams, kam
    assert_not_includes User.kams, am
    assert_not_includes User.kams, admin
    assert_not_includes User.kams, kam_admin, "an admin who also has kam:true is still excluded — admin wins"
  end
end
