require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "role and role_label reflect admin/kam/plain AM, admin taking priority" do
    admin = User.new(name: "Admin", email: "role-admin@example.com", admin: true, kam: true)
    kam = User.new(name: "Kam", email: "role-kam@example.com", admin: false, kam: true)
    am = User.new(name: "Am", email: "role-am@example.com", admin: false, kam: false)

    assert_equal :admin, admin.role
    assert_equal "Admin", admin.role_label
    assert_equal :kam, kam.role
    assert_equal "KAM", kam.role_label
    assert_equal :am, am.role
    assert_equal "AM", am.role_label
  end

  test "privileged? is true for admin and kam, false for a plain AM" do
    assert User.new(admin: true).privileged?
    assert User.new(kam: true).privileged?
    assert_not User.new(admin: false, kam: false).privileged?
  end

  test "role= sets admin/kam from the Équipe selector's three labels" do
    user = User.new
    user.role = "Admin"
    assert user.admin?
    assert_not user.kam?

    user.role = "KAM"
    assert_not user.admin?
    assert user.kam?

    user.role = "AM"
    assert_not user.admin?
    assert_not user.kam?
  end

  test "role= treats any unrecognized value as AM" do
    user = User.new(admin: true, kam: false)
    user.role = "n'importe quoi"
    assert_not user.admin?
    assert_not user.kam?
  end

  test "renaming an AM enqueues a Google Sheets sync, an unrelated save does not" do
    user = User.create!(email: "sync-name@example.com", name: "Nom Initial", active: true)

    assert_enqueued_with(job: GoogleSheetsSyncJob) { user.update!(name: "Nom Modifié") }
    assert_no_enqueued_jobs(only: GoogleSheetsSyncJob) { user.touch }
  end
end
