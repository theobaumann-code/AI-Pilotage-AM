require "net/http"
require "json"
require "openssl"
require "base64"
require "cgi"

# Mirrors every ProduitDeal into a Google Sheet so Sarra has a live, field-by-field export she can keep
# open outside the app — no gem needed, just a service-account JWT exchanged for a Sheets API access token
# (same hand-rolled Net::HTTP style as BonusTrackerUpsellEstimator, rather than pulling in the full
# google-apis-sheets_v4 client for two REST calls).
class GoogleSheetsSync
  class SyncError < StandardError; end

  HEADERS = ["Nom", "AM", "Produit", "Collège", "Assureur", "ID externe", "ARR (€)",
             "Taux négocié (%)", "Statut de renouvellement", "% risque churn", "ARR final (€)"].freeze

  def self.sync_produits!
    new.sync_produits!
  end

  def initialize(credentials_json: ENV["GOOGLE_SHEETS_CREDENTIALS_JSON"],
                 spreadsheet_id: ENV["GOOGLE_SHEETS_SPREADSHEET_ID"],
                 sheet_name: ENV.fetch("GOOGLE_SHEETS_PRODUITS_SHEET_NAME", "Produits"))
    @credentials_json = credentials_json
    @spreadsheet_id = spreadsheet_id
    @sheet_name = sheet_name
  end

  def sync_produits!
    raise SyncError, "Synchronisation Google Sheets non configurée (identifiants ou ID de feuille manquants)" if @credentials_json.blank? || @spreadsheet_id.blank?

    rows = [HEADERS] + ProduitDeal.includes(company: :user).order(:id).map { |deal| row_for(deal) }
    write_rows(rows)
  end

  private

  def row_for(deal)
    [
      deal.company.name, deal.company.user.name, deal.produit, deal.college, deal.assureur,
      deal.identifiant, deal.arr.to_f, deal.taux.to_f, deal.statut_renouvellement,
      deal.risque_churn, deal.final_arr.to_f
    ]
  end

  # Clears the whole tab first, then rewrites it in one shot — simplest way to guarantee the sheet exactly
  # matches the DB (no stale trailing rows from a shrinking dataset) for a dataset this size.
  def write_rows(rows)
    token = access_token
    encoded_sheet = CGI.escape(@sheet_name)

    request(:post, "#{sheets_base}/values/#{encoded_sheet}:clear", token, {})
    request(:put, "#{sheets_base}/values/#{encoded_sheet}!A1?valueInputOption=RAW", token, { values: rows })
  end

  def sheets_base
    "https://sheets.googleapis.com/v4/spreadsheets/#{@spreadsheet_id}"
  end

  def request(method, url, token, body)
    uri = URI(url)
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Put).new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 30) { |http| http.request(req) }
    raise SyncError, "Google Sheets a répondu #{response.code} : #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    response
  rescue SocketError, SystemCallError, Timeout::Error => error
    raise SyncError, "Google Sheets indisponible (#{error.class})"
  end

  # Service-account JWT Bearer flow (RFC 7523): sign a short-lived claim with the account's private key,
  # exchange it for an OAuth2 access token — no user consent screen, no refresh token to store.
  def access_token
    credentials = JSON.parse(@credentials_json)
    now = Time.now.to_i
    segments = [
      { alg: "RS256", typ: "JWT" },
      { iss: credentials.fetch("client_email"), scope: "https://www.googleapis.com/auth/spreadsheets",
        aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }
    ].map { |segment| Base64.urlsafe_encode64(JSON.generate(segment), padding: false) }

    signing_input = segments.join(".")
    private_key = OpenSSL::PKey::RSA.new(credentials.fetch("private_key"))
    signature = Base64.urlsafe_encode64(private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input), padding: false)

    uri = URI("https://oauth2.googleapis.com/token")
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: "#{signing_input}.#{signature}")

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |http| http.request(req) }
    raise SyncError, "Authentification Google a échoué (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("access_token")
  rescue JSON::ParserError, KeyError, OpenSSL::PKey::RSAError => error
    raise SyncError, "Identifiants Google Sheets invalides (#{error.message})"
  rescue SocketError, SystemCallError, Timeout::Error => error
    raise SyncError, "Google indisponible (#{error.class})"
  end
end
