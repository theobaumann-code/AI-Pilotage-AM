require "test_helper"

class BonusTrackerUpsellEstimatorTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "estimate@example.com", name: "Estimate AM", active: true)
    company = Company.create!(name: "Estimate Client", user: user)
    ProduitDeal.create!(company: company, produit: "Prévoyance", identifiant: "123 456 789 00012",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours")
    @deal = UpsellDeal.create!(company: company, produit: "Mutuelle", nombre_salaries: 20,
      probabilite_signature: 50, statut_signature: "En cours")
  end

  test "sends normalized BO identifiers and reads the auditable estimate" do
    response = Struct.new(:body) do
      def is_a?(klass) = klass == Net::HTTPSuccess
    end.new(JSON.generate(
      estimable: true, estimated_arr: 2345.67, source: "fee_group",
      reference: "Tarifs du groupe BO", formula_version: "2026.09.16",
      calculated_at: "2026-09-16T12:00:00Z"
    ))
    captured_request = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      captured_request = request
      response
    end

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(fake_http) }) do
      result = BonusTrackerUpsellEstimator.new(@deal,
        endpoint: "https://bonus.example/api/internal/upsell-arr-estimate", token: "secret").estimate
      assert_in_delta 2345.67, result.arr, 0.01
    end

    assert_equal "Bearer secret", captured_request["Authorization"]
    assert_equal({"identifiers" => ["12345678900012"], "company_name" => "Estimate Client", "product" => "Mutuelle", "employees" => 20}, JSON.parse(captured_request.body))
  end

  test "marks an upsell unavailable instead of using a fixed fallback" do
    BonusTrackerUpsellEstimator.refresh!(@deal)
    @deal.reload
    assert_equal 0, @deal.arr
    assert_equal "unavailable", @deal.arr_estimation_source
    assert_match(/non configuré/i, @deal.arr_estimation_reference)
  end
end
