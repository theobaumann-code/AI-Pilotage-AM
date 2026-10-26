require "test_helper"
require Rails.root.join("db/migrate/20261020100000_rename_churn_reasons")

class RenameChurnReasonsMigrationTest < ActiveSupport::TestCase
  test "existing reasons move to their closest new equivalent and unmatched ones go back to À qualifier" do
    am = User.create!(email: "am-rename-reasons@example.com", name: "AM Reasons", active: true)
    company = Company.create!(name: "Client Reasons", user: am)
    old_to_expected = {
      "Offre concurrente" => "Meilleure offre concurrente",
      "Insatisfaction (service, gestion)" => "Qualité de la gestion",
      "Cessation d'activité / fusion" => "Rachat/Fusion",
      "Autre" => "Autre",
      "Tarif / hausse de prix" => nil,
      "Offre inadaptée" => nil,
      "Non conformité" => "Non conformité"
    }
    ids = old_to_expected.keys.each_with_index.to_h do |old_reason, i|
      deal = ProduitDeal.create!(company: company, produit: "Mutuelle", identifiant: "rr-#{i}", college: "Cadre",
        assureur: ProduitDeal::ASSUREURS[i], arr: 1_000, statut_renouvellement: "Churné", churn_comment: "garde #{i}")
      deal.update_columns(churn_reason: old_reason)
      [ old_reason, deal.id ]
    end
    untouched = ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "rr-none", college: "Cadre",
      assureur: "AXA", arr: 1, statut_renouvellement: "En cours")

    ActiveRecord::Migration.suppress_messages { RenameChurnReasons.new.up }

    old_to_expected.each do |old_reason, expected|
      deal = ProduitDeal.find(ids[old_reason])
      if expected.nil?
        assert_nil deal.churn_reason, "#{old_reason.inspect} has no counterpart"
      else
        assert_equal expected, deal.churn_reason, "#{old_reason.inspect} → #{expected.inspect}"
      end
      assert_match(/\Agarde/, deal.churn_comment, "the comment is kept")
    end
    assert_nil untouched.reload.churn_reason
    assert ProduitDeal.where.not(churn_reason: nil).all?(&:valid?), "every remaining reason is one of the new list"
  end

  test "the new list is the one requested" do
    assert_equal [ "Meilleure offre concurrente", "Qualité de la gestion", "Non conformité", "Conseil apporté",
                  "Expérience client", "Rachat/Fusion", "Autre" ], ProduitDeal::CHURN_REASONS
    assert_equal ProduitDeal::CHURN_REASONS, RenameChurnReasons::NEW_REASONS
  end
end
