require "test_helper"

class CompanyTest < ActiveSupport::TestCase
  setup do
    @am1 = User.create!(email: "am1@example.com", password: "password123", name: "AM Un", active: true)
    @am2 = User.create!(email: "am2@example.com", password: "password123", name: "AM Deux", active: true)
    @company = Company.create!(name: "Cabinet Reassign", user: @am1)
  end

  test "reassign_am! moves the company (and structurally, all its deals) to the new AM" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours")
    UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    @company.reassign_am!(@am2)

    assert_equal @am2, @company.reload.user
    # Deals never carry their own AM field — they belong to the company, which now belongs to am2.
    # There is no per-deal reassignment step to forget, unlike the original's manual walk over state.clients.
    assert_equal [@am2], @company.deals.map { |d| d.company.user }.uniq
  end

  test "company names must be unique case-insensitively" do
    Company.create!(name: "Unique Corp", user: @am1)
    dup = Company.new(name: "unique corp", user: @am2)
    assert_not dup.valid?
  end
end
