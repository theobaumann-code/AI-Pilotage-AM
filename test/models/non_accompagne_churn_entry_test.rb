require "test_helper"

class NonAccompagneChurnEntryTest < ActiveSupport::TestCase
  test "requires a company name and a non-negative amount" do
    entry = NonAccompagneChurnEntry.new(company_name: "", amount: 100)
    assert_not entry.valid?
    assert_includes entry.errors[:company_name], "can't be blank"

    entry = NonAccompagneChurnEntry.new(company_name: "Autre", amount: nil)
    assert_not entry.valid?
    assert_includes entry.errors[:amount], "can't be blank"

    entry = NonAccompagneChurnEntry.new(company_name: "Autre", amount: -1)
    assert_not entry.valid?
    assert_includes entry.errors[:amount], "must be greater than or equal to 0"

    entry = NonAccompagneChurnEntry.new(company_name: "Autre", amount: 0)
    assert entry.valid?
  end

  test "entries are ordered alphabetically by company name" do
    NonAccompagneChurnEntry.create!(company_name: "Zeta", amount: 100)
    NonAccompagneChurnEntry.create!(company_name: "Autre", amount: 50)
    NonAccompagneChurnEntry.create!(company_name: "Acme", amount: 25)

    assert_equal ["Acme", "Autre", "Zeta"], NonAccompagneChurnEntry.all.map(&:company_name)
  end
end
