require "test_helper"

# Both the "+ Nouvel AM" creation form and the "Modifier les identifiants" edit panel offer a single
# "Équipe" selector (AM/KAM/Admin) instead of separate admin/kam checkboxes.
class UserRoleManagementTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-role@example.com", name: "Admin Role", admin: true, active: true)
  end

  test "creating an AM with role KAM sets kam true and admin false" do
    sign_in @admin
    post users_path, params: { user: { name: "New Kam", email: "new-kam@example.com", role: "KAM" } }

    user = User.find_by!(email: "new-kam@example.com")
    assert user.kam?
    assert_not user.admin?
  end

  test "editing an AM's role through the credentials panel changes their team" do
    am = User.create!(email: "role-edit@example.com", name: "Role Edit", active: true)
    sign_in @admin

    patch user_path(am), params: { user: { name: am.name, email: am.email, role: "Admin" } }
    am.reload
    assert am.admin?
  end

  test "the last active admin cannot be demoted away from Admin through the credentials panel" do
    sign_in @admin

    patch user_path(@admin), params: { user: { name: @admin.name, email: @admin.email, role: "AM" } }
    @admin.reload
    assert @admin.admin?, "the last admin must stay admin even via the role selector"
  end

  test "Head of CSM can be picked in the Équipe selector and keeps admin rights, so the last admin may take it" do
    sign_in @admin
    get gestion_droits_path
    assert_match "Head of CSM", @response.body

    post users_path, params: { user: { name: "New Head", email: "new-head@example.com", role: "Head of CSM" } }
    head = User.find_by!(email: "new-head@example.com")
    assert_equal [ true, :head_csm, 4 ], [ head.admin?, head.role, head.account_limit ]

    head.destroy!
    patch user_path(@admin), params: { user: { name: @admin.name, email: @admin.email, role: "Head of CSM" } }
    assert_equal :head_csm, @admin.reload.role, "becoming Head of CSM keeps the last admin an admin"
  end
end
