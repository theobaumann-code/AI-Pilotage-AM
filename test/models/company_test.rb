require "test_helper"

class CompanyTest < ActiveSupport::TestCase
  setup do
    @am1 = User.create!(email: "am1@example.com", name: "AM Un", active: true)
    @am2 = User.create!(email: "am2@example.com", name: "AM Deux", active: true)
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

  test "renaming or reassigning a company enqueues a Google Sheets sync, an unrelated save does not" do
    assert_enqueued_with(job: GoogleSheetsSyncJob) { @company.update!(name: "Cabinet Renommé") }
    assert_enqueued_with(job: GoogleSheetsSyncJob) { @company.reassign_am!(@am2) }
    assert_no_enqueued_jobs(only: GoogleSheetsSyncJob) { @company.touch }
  end

  # Mirrors PortfolioSummary's exclusion: a company liquidated or acquired ("Churné (subi)") must not drag
  # this company's own evolution_pct down either, so its ARR comes out of arr_initial, not just churned_arr.
  test "Churné (subi) is excluded from arr_initial and churned_arr" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    assert_in_delta 100_000, @company.arr_initial, 0.01
    assert_in_delta 0, @company.churned_arr, 0.01
    assert_in_delta 5.0, @company.evolution_pct, 0.01
  end
end
