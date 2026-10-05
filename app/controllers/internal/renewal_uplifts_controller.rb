module Internal
  # Narrow server-to-server export. Session users cannot access it without the
  # dedicated read token; it cannot update deals. Cross-sell exposes totals only.
  class RenewalUpliftsController < ActionController::API
    include ActionController::HttpAuthentication::Token::ControllerMethods
    before_action :authenticate_reader!

    def index
      year = AppSetting.first&.annee_en_cours
      return head :service_unavailable unless year
      return render json: { error: "campaign_mismatch" }, status: :conflict unless params[:campaign_year].to_s == year.to_s

      include_in_progress = params[:include_in_progress] == "true"
      deals = ProduitDeal.includes(:company).order(:id)
      deals = deals.where(statut_renouvellement: "Augmenté") unless include_in_progress
      deals = deals.to_a
      response.headers["Cache-Control"] = "no-store"
      data = {
        schemaVersion: 1, campaignYear: year, priceYear: year + 1,
        fetchedAt: Time.current.iso8601,
        rows: deals.select { |deal| deal.statut_renouvellement == "Augmenté" }.map { |deal| renewal_row(deal) }
      }
      if include_in_progress
        data[:inProgressRows] = deals.select { |deal| deal.statut_renouvellement == "En cours" }.map { |deal| renewal_row(deal) }
        # Same weights as the unfiltered product table. Other statuses are only
        # aggregate reference figures: they never become confirmed renewals.
        data[:weighting] = {
          annualArr: deals.sum { |deal| deal.arr.to_f },
          gain: deals.sum { |deal| deal.arr.to_f * deal.taux.to_f / 100 },
          byStatus: deals.group_by(&:statut_renouvellement).map { |status, group|
            { status: status, rows: group.size, annualArr: group.sum { |deal| deal.arr.to_f },
              gain: group.sum { |deal| deal.arr.to_f * deal.taux.to_f / 100 } }
          }
        }
      end
      render json: data
    end

    def cross_sell
      year = AppSetting.first&.annee_en_cours
      return head :service_unavailable unless year
      return render json: { error: "campaign_mismatch" }, status: :conflict unless params[:campaign_year].to_s == year.to_s

      summary = PortfolioSummary.new(Company.includes(:upsell_deals))
      response.headers["Cache-Control"] = "no-store"
      render json: { schemaVersion: 1, campaignYear: year, fetchedAt: Time.current.iso8601,
        projectedArr: summary.upsold.to_f, signedArr: summary.upsold_actual.to_f }
    end

    private

    def renewal_row(deal)
      { id: deal.id.to_s, clientName: deal.company.name, product: deal.produit,
        college: deal.college, insurer: deal.assureur, externalId: deal.identifiant,
        status: deal.statut_renouvellement, ratePercent: deal.taux.to_f,
        updatedAt: deal.updated_at.iso8601 }
    end

    def authenticate_reader!
      expected = ENV["ANALYTICS_RENEWAL_UPLIFTS_TOKEN"].to_s
      authorized = expected.present? && authenticate_with_http_token { |token, _|
        ActiveSupport::SecurityUtils.secure_compare(token, expected)
      }
      head :unauthorized unless authorized
    end
  end
end
