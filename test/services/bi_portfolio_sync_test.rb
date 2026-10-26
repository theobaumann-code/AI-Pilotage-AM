require "test_helper"

class BiPortfolioSyncTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:rows) do
    attr_reader :sql

    def query(sql)
      @sql = sql
      rows
    end
  end

  def bi_row(id, **attrs)
    { "kind" => "set", "account_id" => id, "name" => "Set #{id}", "siren" => nil, "user_pros_count" => 3,
      "am_email" => " AM@SideCare.com ", "am_name" => "Am Bi", "arr" => 1234.567, "arr_sante" => 1000.0, "arr_prevoyance" => 234.567,
      "has_sante" => true, "has_prevoyance" => true, "has_standard_sante" => true, "contracts_count" => 2,
      "contracts_without_q1" => 0, "employees_count" => 12 }.merge(attrs)
  end

  test "replaces every account with what the BI returns, e-mails normalised" do
    BiAccount.create!(kind: "set", bi_id: 999, name: "Ancien", synced_at: 1.day.ago)
    client = FakeClient.new([ bi_row(1), bi_row(2, "kind" => "user_pro", "am_email" => nil, "am_name" => nil) ])

    assert_equal 2, BiPortfolioSync.new(client: client).sync!
    assert_equal [ 1, 2 ], BiAccount.order(:bi_id).pluck(:bi_id), "the stale account is gone"
    first = BiAccount.find_by!(bi_id: 1)
    assert_equal [ "am@sidecare.com", 1234.57 ], [ first.am_email, first.arr.to_f ]
    assert_nil BiAccount.find_by!(bi_id: 2).am_email
    assert_match "`dogwood-method-256009.BI_EU`.s_company_sets", client.sql
  end

  test "an empty answer raises and keeps the accounts already there" do
    BiAccount.create!(kind: "set", bi_id: 1, name: "Garde", synced_at: 1.day.ago)
    assert_raises(BigQueryClient::QueryError) { BiPortfolioSync.new(client: FakeClient.new([])).sync! }
    assert_equal 1, BiAccount.count
  end

  test "the BigQuery client refuses to run unconfigured" do
    error = assert_raises(BigQueryClient::QueryError) { BigQueryClient.new(credentials_json: nil, project_id: "p") }
    assert_match(/non configurée/, error.message)
  end
end
