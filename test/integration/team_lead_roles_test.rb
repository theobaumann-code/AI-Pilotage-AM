require "test_helper"

# TL AM (admin rights) and TL Customer Care (user rights) as roles one can pick in Gestion des droits.
class TeamLeadRolesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-tl@example.com", name: "Admin TL", admin: true, active: true)
    @second_admin = User.create!(email: "admin2-tl@example.com", name: "Admin Deux TL", admin: true, active: true)
    @am = User.create!(email: "am-tl@example.com", name: "AM TL", active: true)
    sign_in @admin
  end

  test "an admin creates a TL AM (admin rights) and a TL Customer Care (user rights)" do
    post users_path, params: { user: { name: "Nouveau TL AM", email: "nouveau-tlam@example.com", role: "TL AM" } }
    tl_am = User.find_by!(email: "nouveau-tlam@example.com")
    assert_equal [true, "TL AM", :tl_am], [tl_am.admin?, tl_am.poste, tl_am.role]

    post users_path, params: { user: { name: "Nouveau TL CC", email: "nouveau-tlcc@example.com", role: "TL Customer Care" } }
    tl_cc = User.find_by!(email: "nouveau-tlcc@example.com")
    assert_equal [false, false, "TL Customer Care"], [tl_cc.admin?, tl_cc.kam?, tl_cc.poste]
  end

  test "an existing user is switched to a team-lead role from the edit panel, and back" do
    patch user_path(@am), params: { user: { name: @am.name, email: @am.email, role: "TL Customer Care" } }
    assert_equal "TL Customer Care", @am.reload.poste

    patch user_path(@am), params: { user: { name: @am.name, email: @am.email, role: "TL AM" } }
    assert_equal [true, "TL AM"], [@am.reload.admin?, @am.poste]

    patch user_path(@am), params: { user: { name: @am.name, email: @am.email, role: "AM" } }
    assert_equal [false, nil], [@am.reload.admin?, @am.poste]
  end

  test "a TL AM counts as an admin for the last-admin safeguard" do
    @second_admin.update!(role: "TL AM")
    patch user_path(@admin), params: { user: { name: @admin.name, email: @admin.email, role: "AM" } }
    assert_equal :am, @admin.reload.role, "another admin (the TL AM) remains, so the first can step down"

    # now the TL AM is the only admin left: they can't be demoted
    sign_out :user
    sign_in @second_admin
    patch user_path(@second_admin), params: { user: { name: @second_admin.name, email: @second_admin.email, role: "AM" } }
    assert_equal :tl_am, @second_admin.reload.role
    assert_match "au moins un administrateur", flash[:alert].to_s

    # switching to another admin-keeping role is fine
    patch user_path(@second_admin), params: { user: { name: @second_admin.name, email: @second_admin.email, role: "Admin" } }
    assert_equal :admin, @second_admin.reload.role
  end

  test "rights follow the role: a TL AM reaches admin-only pages, a TL Customer Care does not" do
    tl_am = User.create!(email: "tlam-rights@example.com", name: "TL AM Rights", role: "TL AM", active: true)
    tl_cc = User.create!(email: "tlcc-rights@example.com", name: "TL CC Rights", role: "TL Customer Care", active: true)

    sign_out :user
    sign_in tl_am
    get attribution_portefeuille_path
    assert_response :success
    get gestion_droits_path
    assert_response :success

    sign_out :user
    sign_in tl_cc
    get attribution_portefeuille_path
    assert_response :redirect
    get gestion_droits_path
    assert_response :redirect
  end

  test "Gestion des droits offers the new roles, shows them as badges, and sorts them" do
    User.create!(email: "tlam-badge@example.com", name: "TL AM Badge", role: "TL AM", active: true)
    User.create!(email: "tlcc-badge@example.com", name: "TL CC Badge", role: "TL Customer Care", active: true)
    get gestion_droits_path
    assert_response :success
    assert_match(/<option value="TL AM">TL AM<\/option>/, @response.body[/id="edit-am-role".*?<\/select>/m])
    assert_match(/<option value="TL Customer Care">TL Customer Care<\/option>/, @response.body[/id="edit-am-role".*?<\/select>/m])
    assert_match(/badge tl">TL AM</, @response.body)
    assert_match(/badge tl">TL Customer Care</, @response.body)

    get gestion_droits_path, params: { am_sort: "role", am_dir: "asc" }
    assert_response :success
  end

  test "the Équipe filters of Vue globale and Autres statistiques include the team-lead roles" do
    tl = User.create!(email: "tlam-filter@example.com", name: "TL AM Filter", role: "TL AM", active: true)
    Company.create!(name: "Client TL Filter", user: tl)

    get pilotage_path
    assert_response :success
    assert_match(/name="summary_roles\[\]" value="TL AM"/, @response.body)
    assert_match(/name="summary_roles\[\]" value="TL Customer Care"/, @response.body)

    get autres_statistiques_path, params: { roles: ["TL AM"] }
    assert_response :success
    assert_equal [tl.id], @controller.instance_variable_get(:@scoped_user_ids)
    assert_equal 1, @controller.instance_variable_get(:@company_ids).size
  end

  test "the sidebar shows a team lead's role" do
    tl = User.create!(email: "tlam-side@example.com", name: "TL AM Side", role: "TL AM", active: true)
    sign_out :user
    sign_in tl
    get pilotage_path
    assert_match(/<small>TL AM<\/small>/, @response.body)
  end
end
