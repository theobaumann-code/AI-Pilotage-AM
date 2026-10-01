module Internal
  # Narrow server-to-server export. Session users cannot access it without the
  # dedicated read token; it cannot update deals or expose other portfolio data.
  class RenewalUpliftsController < ActionController::API
    include ActionController::HttpAuthentication::Token::ControllerMethods
    before_action :authenticate_reader!

    def index
      year = AppSetting.first&.annee_en_cours
      return head :service_unavailable unless year
      return render json: { error: "campaign_mismatch" }, status: :conflict unless params[:campaign_year].to_s == year.to_s

      deals = ProduitDeal.includes(:company).where(statut_renouvellement: "Augmenté").order(:id)
      response.headers["Cache-Control"] = "no-store"
      render json: {
        schemaVersion: 1, campaignYear: year, priceYear: year + 1,
        fetchedAt: Time.current.iso8601,
        rows: deals.map { |deal|
          { id: deal.id.to_s, clientName: deal.company.name, product: deal.produit,
            college: deal.college, insurer: deal.assureur, externalId: deal.identifiant,
            status: deal.statut_renouvellement, ratePercent: deal.taux.to_f,
            updatedAt: deal.updated_at.iso8601 }
        }
      }
    end

    private

    def authenticate_reader!
      expected = ENV["ANALYTICS_RENEWAL_UPLIFTS_TOKEN"].to_s
      authorized = expected.present? && authenticate_with_http_token { |token, _|
        ActiveSupport::SecurityUtils.secure_compare(token, expected)
      }
      head :unauthorized unless authorized
    end
  end
end
