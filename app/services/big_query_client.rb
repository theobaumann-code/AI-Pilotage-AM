require "net/http"
require "json"
require "cgi"

# Read-only BigQuery access over the REST API (jobs.query + getQueryResults), authenticated with a service
# account - the same hand-rolled approach as GoogleSheetsSync rather than the full google-cloud-bigquery gem.
class BigQueryClient
  class QueryError < StandardError; end

  SCOPE = "https://www.googleapis.com/auth/bigquery".freeze
  POLL_TIMEOUT_MS = 30_000
  MAX_POLLS = 20

  def initialize(credentials_json:, project_id:, location: "EU")
    raise QueryError, "Connexion BigQuery non configurée (identifiants ou projet manquants)" if credentials_json.blank? || project_id.blank?

    @credentials_json = credentials_json
    @project_id = project_id
    @location = location
  end

  # Runs `sql` and returns every row as a Hash keyed by column name, values cast from the result schema.
  def query(sql)
    token = access_token
    response = request(:post, "#{base}/queries", token,
      { query: sql, useLegacySql: false, location: @location, timeoutMs: POLL_TIMEOUT_MS, maxResults: 5_000 })
    job_id = response.dig("jobReference", "jobId")

    polls = 0
    until response["jobComplete"]
      polls += 1
      raise QueryError, "La requête BigQuery n'a pas abouti à temps" if polls > MAX_POLLS
      response = results(job_id, token)
    end

    fields = response.dig("schema", "fields") || []
    rows = parse_rows(response, fields)
    while (page_token = response["pageToken"])
      response = results(job_id, token, page_token: page_token)
      rows.concat(parse_rows(response, fields))
    end
    rows
  end

  private

  def results(job_id, token, page_token: nil)
    params = { location: @location, timeoutMs: POLL_TIMEOUT_MS, maxResults: 5_000, pageToken: page_token }.compact
    request(:get, "#{base}/queries/#{CGI.escape(job_id)}?#{URI.encode_www_form(params)}", token)
  end

  def parse_rows(response, fields)
    (response["rows"] || []).map do |row|
      fields.each_with_index.to_h { |field, i| [ field["name"], cast(row["f"][i]["v"], field["type"]) ] }
    end
  end

  def cast(value, type)
    return nil if value.nil?

    case type
    when "INTEGER", "INT64" then value.to_i
    when "FLOAT", "FLOAT64", "NUMERIC", "BIGNUMERIC" then value.to_f
    when "BOOLEAN", "BOOL" then value == "true"
    else value
    end
  end

  def base
    "https://bigquery.googleapis.com/bigquery/v2/projects/#{@project_id}"
  end

  def request(method, url, token, body = nil)
    uri = URI(url)
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    req["Authorization"] = "Bearer #{token}"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 60) { |http| http.request(req) }
    raise QueryError, "BigQuery a répondu #{response.code} : #{response.body.to_s.first(500)}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise QueryError, "Réponse BigQuery invalide (#{error.message})"
  rescue SocketError, SystemCallError, Timeout::Error => error
    raise QueryError, "BigQuery indisponible (#{error.class})"
  end

  def access_token
    GoogleServiceAccount.access_token(@credentials_json, scope: SCOPE)
  rescue GoogleServiceAccount::Error => error
    raise QueryError, error.message
  end
end
