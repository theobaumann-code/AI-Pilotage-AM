require "test_helper"

class HistoriqueQueryTest < ActiveSupport::TestCase
  setup do
    @am = User.create!(email: "am-hq@example.com", name: "AM HQ", active: true)
    @company = Company.create!(name: "Client HQ", user: @am)
  end

  def query(years: [2026])
    HistoriqueQuery.new(current_year: 2026, years: years)
  end

  test "Churné (subi) counts as churned? on a Row, distinct from churn_subi?" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "subi",
      college: "Cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    row = query.rows.first
    assert row.churned?
    assert row.churn_subi?
  end

  test "nrr_series excludes Churné (subi) rows from both the numerator and the denominator" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "kept",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "subi",
      college: "Non cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    series = query.nrr_series([2026]).find { |s| s[:label] == "Mutuelle" }
    # If the 50_000 "subi" deal were included, the mix of its 0 contribution against a 150_000 base would
    # pull this below 100%; excluded, it's exactly the untouched 100_000/100_000 renewal.
    assert_in_delta 100.0, series[:points].first, 0.01
  end
end
