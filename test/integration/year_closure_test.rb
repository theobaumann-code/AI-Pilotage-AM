require "test_helper"

class YearClosureTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-yc@example.com", name: "Admin YC", admin: true, active: true)
    @company = Company.create!(name: "Client YC", user: @admin)
    AppSetting.instance.update!(annee_en_cours: 2026)
  end

  # A "subi" churn (company liquidated/acquired) must drop out at year-end exactly like ordinary churn —
  # not get reconducted as a zombie €0 "En cours" contract, which is what happened before this status
  # existed as its own value the closure's exact-match query recognized.
  test "both ordinary and subi churn are dropped, active deals are reconducted" do
    kept = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "kept",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")
    churned = ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "churned",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 0, statut_renouvellement: "Churné")
    subi = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "subi",
      college: "Non cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    sign_in @admin
    post year_closure_path

    assert_not ProduitDeal.exists?(churned.id), "ordinary churn must not survive the closure"
    assert_not ProduitDeal.exists?(subi.id), "subi churn must not survive the closure either"

    kept.reload
    assert_equal "En cours", kept.statut_renouvellement
    assert_in_delta 105_000, kept.arr, 0.01
    assert_equal 0, kept.taux.to_i

    assert_equal 2027, AppSetting.instance.annee_en_cours
  end
end
