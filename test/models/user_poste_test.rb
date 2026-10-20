require "test_helper"

# "TL AM" (team lead, admin rights) and "TL Customer Care" (team lead, plain user rights): a poste carried on
# top of the rights, with its own ceiling of accounts.
class UserPosteTest < ActiveSupport::TestCase
  def user(attrs = {})
    @i = (@i || 0) + 1
    User.create!({ email: "poste#{@i}@example.com", name: "Poste #{@i}", active: true }.merge(attrs))
  end

  test "TL AM = admin rights plus the poste" do
    tl = user(role: "TL AM")
    assert tl.admin?
    assert tl.privileged?
    assert_not tl.kam?
    assert_equal "TL AM", tl.poste
    assert_equal [:tl_am, "TL AM"], [tl.role, tl.role_label]
  end

  test "TL Customer Care = plain user rights plus the poste" do
    tl = user(role: "TL Customer Care")
    assert_not tl.admin?
    assert_not tl.privileged?
    assert_equal "TL Customer Care", tl.poste
    assert_equal [:tl_csm, "TL Customer Care"], [tl.role, tl.role_label]
    assert_not tl.read_only?
  end

  test "any other role clears the poste, so a team lead can be moved back" do
    tl = user(role: "TL AM")
    tl.update!(role: "AM")
    assert_nil tl.poste
    assert_equal :am, tl.role

    cc = user(role: "TL Customer Care")
    cc.update!(role: "KAM")
    assert_nil cc.poste
    assert_equal :kam, cc.role
  end

  test "the poste follows the rights: taking admin away from a TL AM, or promoting a TL Customer Care, drops it" do
    tl_am = user(role: "TL AM")
    tl_am.update!(admin: false)
    assert_nil tl_am.reload.poste
    assert_equal :am, tl_am.role

    cc = user(role: "TL Customer Care")
    cc.update!(admin: true)
    assert_nil cc.reload.poste
    assert_equal :admin, cc.role

    cc2 = user(role: "TL Customer Care")
    cc2.update!(kam: true)
    assert_nil cc2.reload.poste
  end

  test "an unknown poste is ignored" do
    assert_nil user(poste: "Chef de tribu").poste
  end

  test "ceilings of accounts by role" do
    assert_equal 54, user.account_limit
    assert_equal 35, user(role: "KAM").account_limit
    assert_equal 9, user(role: "TL AM").account_limit
    assert_equal 24, user(role: "TL Customer Care").account_limit
    assert_equal 54, user(role: "Admin").account_limit, "an admin without a poste has the default"
  end

  test "a lecteur is never a team lead" do
    reader = user(role: "Lecteur")
    assert reader.read_only?
    assert_nil reader.poste
  end

  test "the migration gave the poste to the three known people" do
    require Rails.root.join("db/migrate/20261021100000_add_poste_to_users")
    sarra = user(email: "sarra.bachar@sidecare.com", name: "Sarra Bachar", admin: true)
    zak = user(name: "Zakariaa Jirrari")
    louis = user(name: "Louis Billard")
    other = user(name: "Antoine Reby")
    boss = user(name: "Louis Billard Admin", admin: true) # an admin with a similar name is not a TL Customer Care

    ActiveRecord::Migration.suppress_messages do
      migration = AddPosteToUsers.new
      migration.remove_column :users, :poste if User.column_names.include?("poste")
      migration.up
    end
    User.reset_column_information

    assert_equal "TL AM", sarra.reload.poste
    assert_equal "TL Customer Care", zak.reload.poste
    assert_equal "TL Customer Care", louis.reload.poste
    assert_nil other.reload.poste
    assert_nil boss.reload.poste
    assert sarra.admin?, "Sarra keeps her admin rights"
    assert_not zak.privileged?
  end
end
