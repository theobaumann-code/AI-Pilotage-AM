require "test_helper"

class DealTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "owner-deal@example.com", password: "password123", name: "Owner AM", active: true)
    @other = User.create!(email: "other-deal@example.com", password: "password123", name: "Other AM", active: true)
    @company = Company.create!(name: "Cabinet Deal", user: @owner)
  end

  test "effective_user falls back to the company's AM when no override is set" do
    deal = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")
    assert_equal @owner, deal.effective_user
  end

  test "effective_user is the override once one is set, independent of the company's own AM" do
    deal = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours", user: @other)
    assert_equal @other, deal.effective_user
    assert_equal @owner, @company.reload.user, "reassigning one upsell must not touch the company's own AM"
  end

  test "a produit deal's effective_user always tracks the company (never gets its own override in practice)" do
    deal = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours")
    assert_equal @owner, deal.effective_user

    @company.reassign_am!(@other)
    assert_equal @other, deal.reload.effective_user
  end
end
