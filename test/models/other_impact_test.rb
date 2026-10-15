require "test_helper"

class OtherImpactTest < ActiveSupport::TestCase
  setup do
    @am = User.create!(email: "am-impact-model@example.com", name: "AM Impact Model", active: true)
    @company = Company.create!(name: "Client Impact Model", user: @am)
  end

  def build(amount)
    OtherImpact.new(company: @company, amount: amount)
  end

  test "free-text amounts are read as signed euros" do
    { "3000" => 3000, "-3000" => -3000, "  3 000 " => 3000, "3000,50" => 3000.5, "+500 €" => 500,
      "-1 250,75" => -1250.75, "−200" => -200, "0" => 0 }.each do |input, expected|
      impact = build(input)
      assert impact.valid?, "#{input.inspect} should be accepted: #{impact.errors.full_messages}"
      assert_in_delta expected, impact.amount.to_f, 0.001, input.inspect
    end
  end

  test "an amount that isn't a number is refused instead of being read as 0" do
    ["abc", "12abc", "1.2.3", "--5", "", "  ", "3000€€x"].each do |input|
      impact = build(input)
      assert_not impact.valid?, "#{input.inspect} should be refused"
      assert impact.errors[:amount].any?
    end
  end

  test "defaults to Mutuelle, En cours, 0 €, in the current year" do
    impact = OtherImpact.create!(company: @company)
    assert_equal "Mutuelle", impact.produit
    assert_equal "En cours", impact.statut
    assert_equal 0, impact.amount
    assert_equal AppSetting.instance.annee_en_cours, impact.annee
    assert_not impact.validated?
  end

  test "produit and statut are restricted to their lists" do
    assert_not OtherImpact.new(company: @company, amount: 1, produit: "Autre").valid?
    assert_not OtherImpact.new(company: @company, amount: 1, statut: "Annulé").valid?
    OtherImpact::PRODUITS.each { |p| assert OtherImpact.new(company: @company, amount: 1, produit: p).valid? }
    OtherImpact::STATUTS.each { |s| assert OtherImpact.new(company: @company, amount: 1, statut: s).valid? }
  end

  test "a client's impacts go with it when it is deleted" do
    OtherImpact.create!(company: @company, amount: 10)
    assert_difference "OtherImpact.count", -1 do
      @company.destroy
    end
  end
end
