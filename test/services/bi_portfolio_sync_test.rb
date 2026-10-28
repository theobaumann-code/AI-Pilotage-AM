require "test_helper"

class BiPortfolioSyncTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:rows) do
    attr_reader :sql

    def query(sql)
      @sql = sql
      rows
    end
  end

  def bi_row(id, contract_id = nil, **attrs)
    { "kind" => "set", "account_id" => id, "name" => "Set #{id}", "siren" => nil, "user_pros_count" => 3,
      "am_email" => " AM@SideCare.com ", "am_name" => "Am Bi", "employees_count" => 12,
      "account_contract_id" => contract_id, "risque" => "sante", "standard" => true }
      .merge(contract_id ? engine_row(contract_id) : {}).merge(attrs)
  end

  # A health contract the engine values at its tariff: 100 visibles × 80/98,85 % × 50 € × 12 × 10 %.
  def engine_row(contract_id)
    { "contract_id" => contract_id, "contract_type" => "CompanyHealthMutualInternalContract", "start_date" => "2025-01-01",
      "visible_employees" => 100, "effective_salaries" => 100, "group_risk_visibles" => 100, "group_risk_signed" => 100,
      "total_commission_rate" => 0.1, "source_detail" => "fee", "calculation_confidence" => "medium",
      "pricing_reference" => "Tarif simple du contrat", "monthly_premium_per_employee" => 50.0, "months_invoiced" => 0,
      "has_readiness" => false, "observed_on" => "2026-10-28" }
  end

  test "replaces every account with what the BI returns, its ARR added up contract by contract" do
    BiAccount.create!(kind: "set", bi_id: 999, name: "Ancien", synced_at: 1.day.ago)
    provident = engine_row(11).merge("contract_type" => "CompanyProvidentInsuranceInternalContract", "risque" => "prevoyance",
                                     "source_detail" => "dsn_recent", "monthly_premium_per_employee" => 20.0)
    client = FakeClient.new([ bi_row(1, 10, "standard" => false), bi_row(1, 11).merge(provident),
                              bi_row(2, nil, "kind" => "user_pro", "am_email" => nil, "am_name" => nil) ])

    assert_equal 2, BiPortfolioSync.new(client: client).sync!
    assert_equal [ 1, 2 ], BiAccount.order(:bi_id).pluck(:bi_id), "the stale account is gone"
    first = BiAccount.find_by!(bi_id: 1)
    sante = (100 * 0.80 / 0.9885 * 600 * 0.1 / 1.1532).round(2)
    prevoyance = (100 * 0.95 / 0.973 * 240 * 0.1).round(2)
    assert_equal [ "am@sidecare.com", sante, prevoyance ], [ first.am_email, first.arr_sante.to_f, first.arr_prevoyance.to_f ]
    assert_equal [ 2, 2, "estimation" ], [ first.contracts_count, first.contracts_estimated, first.arr_source ]
    assert_equal %w[fee dsn_recent], first.arr_calculation["source_details"]
    assert first.has_sur_mesure_sante
    assert_not first.has_standard_sante

    second = BiAccount.find_by!(bi_id: 2)
    assert_nil second.am_email
    assert_equal [ 0, nil ], [ second.contracts_count, second.arr_calculation ]
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
