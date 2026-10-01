require "test_helper"

class RenewalUpliftsExportTest < ActionDispatch::IntegrationTest
  parallelize(workers: 1)
  setup do
    @previous_token = ENV["ANALYTICS_RENEWAL_UPLIFTS_TOKEN"]
    ENV["ANALYTICS_RENEWAL_UPLIFTS_TOKEN"] = "test-read-token"
    AppSetting.create!(annee_en_cours: 2026)
    user = User.create!(name: "Export reader", email: "export-reader@example.com")
    @company = Company.create!(name: "Export test", user: user)
    @deal = @company.produit_deals.create!(produit: "Mutuelle", college: "Ensemble du personnel",
      assureur: "AXA", identifiant: "test-export", statut_renouvellement: "Augmenté", taux: 8.5, arr: 100)
    @company.produit_deals.create!(produit: "Prévoyance", college: "Cadre", assureur: "AXA",
      statut_renouvellement: "Nouveau contrat", taux: 15, arr: 200)
  end

  teardown { ENV["ANALYTICS_RENEWAL_UPLIFTS_TOKEN"] = @previous_token }

  test "requires the dedicated token and fails closed without configuration" do
    get "/api/internal/renewal-uplifts", params: { campaign_year: 2026 }
    assert_response :unauthorized
    get "/api/internal/renewal-uplifts", params: { campaign_year: 2026 }, headers: { "Authorization" => "Bearer wrong" }
    assert_response :unauthorized
    ENV.delete("ANALYTICS_RENEWAL_UPLIFTS_TOKEN")
    get "/api/internal/renewal-uplifts", params: { campaign_year: 2026 }, headers: auth
    assert_response :unauthorized
  end

  test "exports only confirmed increases with the campaign and percent unit" do
    assert_no_difference "Deal.count" do
      get "/api/internal/renewal-uplifts", params: { campaign_year: 2026 }, headers: auth
    end
    assert_response :success
    data = response.parsed_body
    assert_equal 2027, data["priceYear"]
    assert_equal 2026, data["campaignYear"]
    assert_equal [ @deal.id.to_s ], data["rows"].map { |row| row["id"] }
    assert_equal 8.5, data["rows"].first["ratePercent"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not data["rows"].first.key?("arr")
  end

  test "rejects a different campaign and exposes no mutation route" do
    get "/api/internal/renewal-uplifts", params: { campaign_year: 2027 }, headers: auth
    assert_response :conflict
    assert_equal "campaign_mismatch", response.parsed_body["error"]
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/api/internal/renewal-uplifts", method: :post)
    end
  end

  private

  def auth
    { "Authorization" => "Bearer test-read-token" }
  end
end
