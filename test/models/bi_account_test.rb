require "test_helper"

class BiAccountTest < ActiveSupport::TestCase
  def account(**attrs)
    @n = (@n || 0) + 1
    BiAccount.create!({ kind: "user_pro", bi_id: @n, name: "Compte #{@n}", synced_at: Time.current }.merge(attrs))
  end

  test "comptes sans AM: over 2 000 €, and over 5 000 € unless they hold a standard health product" do
    big = account(arr: 6_000)
    standard = account(arr: 3_000, has_sante: true, has_standard_sante: true)
    account(arr: 3_000, has_sante: true)                         # sur mesure only, under 5 000: out
    account(arr: 2_000, has_standard_sante: true)                # not over 2 000: out
    account(arr: 9_000, am_email: "am@sidecare.com")             # has an AM: out

    assert_equal [ big, standard ].sort, BiAccount.sans_am.to_a.sort
  end

  test "risk covered and the upsell is the risk not held yet, valued on headcount" do
    sante = account(has_sante: true, employees_count: 10)
    prev = account(has_prevoyance: true, employees_count: 10)
    both = account(has_sante: true, has_prevoyance: true, employees_count: 10)

    assert_equal [ "Santé", "Prévoyance", "Double risque" ], [ sante.risque, prev.risque, both.risque ]
    assert_equal [ "Prévoyance", "Mutuelle", nil ], [ sante.upsell_produit, prev.upsell_produit, both.upsell_produit ]
    assert_in_delta UpsellDeal.rate_per_employee_for("Prévoyance") * 10, sante.upsell_amount, 0.01
    assert_in_delta UpsellDeal.rate_per_employee_for("Mutuelle") * 10, prev.upsell_amount, 0.01
    assert_equal 0.0, both.upsell_amount
  end

  test "an account is active while it holds an active contract" do
    assert account(contracts_count: 2).active?
    assert_not account(contracts_count: 0).active?
  end
end
