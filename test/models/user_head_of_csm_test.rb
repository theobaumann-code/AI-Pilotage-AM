require "test_helper"

# "Head of CSM": admin rights plus the poste, with a ceiling of 4 accounts.
class UserHeadOfCsmTest < ActiveSupport::TestCase
  def user(attrs = {})
    @i = (@i || 0) + 1
    User.create!({ email: "head#{@i}@example.com", name: "Head #{@i}", active: true }.merge(attrs))
  end

  test "Head of CSM = admin rights plus the poste, 4 accounts max, sits with the AMs" do
    head = user(role: "Head of CSM")
    assert head.admin?
    assert head.privileged?
    assert_not head.kam?
    assert_equal "Head of CSM", head.poste
    assert_equal [ :head_csm, "Head of CSM", 4 ], [ head.role, head.role_label, head.account_limit ]
    assert_equal "AM", head.team_label
  end

  test "moving away from Head of CSM, or losing admin rights, drops the poste" do
    head = user(role: "Head of CSM")
    head.update!(role: "AM")
    assert_nil head.poste
    assert_not head.admin?

    other = user(role: "Head of CSM")
    other.update!(admin: false)
    assert_nil other.reload.poste
    assert_equal :am, other.role
  end
end
