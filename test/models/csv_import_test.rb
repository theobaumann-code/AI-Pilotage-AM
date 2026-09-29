require "test_helper"

class CsvImportTest < ActiveSupport::TestCase
  setup do
    @am = User.create!(email: "am-csvimport@example.com", name: "AM CsvImport", active: true)
  end

  test "an upsell import row with a recognized Collège column uses it" do
    csv = "Nom;Produit;Collège;Nb salariés;% de chance;Statut;AM\n" \
          "Client Import;Mutuelle;Cadre;20;50;En cours;#{@am.name}"
    result = CsvImport.new(text: csv, deal_type: "upsell").analyze

    assert result.to_create.any?
    assert_equal "Cadre", result.to_create.first.attrs[:college]
  end

  test "an upsell import row without a Collège column defaults to Ensemble du personnel" do
    csv = "Nom;Produit;Nb salariés;% de chance;Statut;AM\n" \
          "Client Import Sans College;Mutuelle;20;50;En cours;#{@am.name}"
    result = CsvImport.new(text: csv, deal_type: "upsell").analyze

    assert result.to_create.any?
    assert_equal "Ensemble du personnel", result.to_create.first.attrs[:college]
  end

  test "an unrecognized Collège value falls back to the default with a warning, not rejected outright" do
    csv = "Nom;Produit;Collège;Nb salariés;% de chance;Statut;AM\n" \
          "Client Import Bogus;Mutuelle;PasUnCollege;20;50;En cours;#{@am.name}"
    result = CsvImport.new(text: csv, deal_type: "upsell").analyze

    assert result.to_create.any?
    assert_equal "Ensemble du personnel", result.to_create.first.attrs[:college]
    assert result.warnings.any? { |w| w.include?("collège") }
  end
end
