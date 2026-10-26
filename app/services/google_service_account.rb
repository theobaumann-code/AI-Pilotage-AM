require "net/http"
require "json"
require "openssl"
require "base64"

# Service-account JWT Bearer flow (RFC 7523): sign a short-lived claim with the account's private key,
# exchange it for an OAuth2 access token - no user consent screen, no refresh token to store. Shared by every
# Google API this app calls by hand (Sheets, BigQuery) instead of pulling in the google-apis client gems.
module GoogleServiceAccount
  class Error < StandardError; end

  def self.access_token(credentials_json, scope:)
    credentials = JSON.parse(credentials_json)
    now = Time.now.to_i
    segments = [
      { alg: "RS256", typ: "JWT" },
      { iss: credentials.fetch("client_email"), scope: scope,
        aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }
    ].map { |segment| Base64.urlsafe_encode64(JSON.generate(segment), padding: false) }

    signing_input = segments.join(".")
    private_key = OpenSSL::PKey::RSA.new(credentials.fetch("private_key"))
    signature = Base64.urlsafe_encode64(private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input), padding: false)

    uri = URI("https://oauth2.googleapis.com/token")
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: "#{signing_input}.#{signature}")

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |http| http.request(req) }
    raise Error, "Authentification Google a échoué (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("access_token")
  rescue JSON::ParserError, KeyError, TypeError, OpenSSL::PKey::RSAError => error
    raise Error, "Identifiants Google invalides (#{error.message})"
  rescue SocketError, SystemCallError, Timeout::Error => error
    raise Error, "Google indisponible (#{error.class})"
  end
end
