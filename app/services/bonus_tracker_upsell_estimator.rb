require "net/http"
require "json"

# Calls Bonus Tracker's BO-backed estimator and stores an auditable snapshot on
# the upsell. The endpoint owns the pricing rules; this app only supplies the BO
# identifier, target risk and population, preventing the two products from
# drifting as the estimation model evolves.
class BonusTrackerUpsellEstimator
  class EstimationError < StandardError; end

  Result = Data.define(:arr, :source, :reference, :formula_version, :calculated_at)

  def self.refresh!(deal)
    result = new(deal).estimate
    deal.update_columns(
      arr: result.arr,
      arr_estimation_source: result.source,
      arr_estimation_reference: result.reference,
      arr_estimation_formula_version: result.formula_version,
      arr_estimated_at: result.calculated_at
    )
    result
  rescue EstimationError => error
    deal.update_columns(
      arr: 0,
      arr_estimation_source: "unavailable",
      arr_estimation_reference: error.message,
      arr_estimation_formula_version: nil,
      arr_estimated_at: Time.current
    )
    nil
  end

  def initialize(deal, endpoint: ENV["BONUS_TRACKER_UPSELL_ESTIMATOR_URL"], token: ENV["BONUS_TRACKER_INTERNAL_TOKEN"])
    @deal = deal
    @endpoint = endpoint
    @token = token
  end

  def estimate
    identifiers = @deal.company.produit_deals.filter_map { |product| normalize_identifier(product.identifiant) }.uniq
    raise EstimationError, "Aucun identifiant BO exploitable pour ce client" if identifiers.empty?
    raise EstimationError, "Estimateur Bonus Tracker non configuré" if @endpoint.blank? || @token.blank?

    uri = URI(@endpoint)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      identifiers: identifiers,
      product: @deal.produit,
      employees: @deal.nombre_salaries.to_i
    )

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 25) do |http|
      http.request(request)
    end
    raise EstimationError, "Bonus Tracker a répondu #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    raise EstimationError, payload["reason"].presence || "Rattachement BO introuvable" unless payload["estimable"]

    Result.new(
      arr: BigDecimal(payload.fetch("estimated_arr").to_s).round(2),
      source: payload.fetch("source"),
      reference: payload["reference"],
      formula_version: payload.fetch("formula_version"),
      calculated_at: Time.iso8601(payload.fetch("calculated_at"))
    )
  rescue JSON::ParserError, KeyError, ArgumentError => error
    raise EstimationError, "Réponse Bonus Tracker invalide (#{error.message})"
  rescue SocketError, SystemCallError, Timeout::Error => error
    raise EstimationError, "Bonus Tracker indisponible (#{error.class})"
  end

  private

  def normalize_identifier(value)
    digits = value.to_s.gsub(/\D/, "")
    return if digits.length < 9

    digits.first(14)
  end
end
