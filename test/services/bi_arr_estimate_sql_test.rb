require "test_helper"

# The SQL port of the Analytics ARR engine: its structure, not BigQuery's answers.
class BiArrEstimateSqlTest < ActiveSupport::TestCase
  setup { @sql = BiPortfolioSync.new.sql }

  test "the engine CTEs are wired into the portfolio query, with no placeholder left" do
    assert_no_match(/%\{/, @sql)
    %w[est_contracts est_selected_invoices est_invoice_agg est_census est_fee_agg est_occurrence_agg est_health_mix_reference
       est_provident_own est_provident_mass_basis est_benchmark est_pricing contract_arr_engine].each do |cte|
      assert_match(/\b#{cte} AS \(/, @sql, "#{cte} is defined")
    end
  end

  test "pricing follows the engine's order of sources" do
    order = %w[dsn_recent dsn_group fee_occurrence fee_price_unique mix_monthly_primes_per_employee benchmark_mut]
    pricing = @sql[/est_pricing AS \(.*?\n\),/m]
    positions = order.map { |source| pricing.index(source) }
    assert positions.all?, "every source is priced"
    assert_equal positions.sort, positions
  end

  test "only signed contracts sent to the insurer and handled by ops make up an account" do
    contracts = @sql[/\ncontracts AS \(.*?\n\),/m]
    assert_match "ic.subscription_status = 5", contracts
    assert_match "ic.operation_status IN (2, 3, 4, 7)", contracts
  end

  test "invoices are read from January 1st of the ARR year, as in Analytics" do
    sql = BiArrEstimateSql.ctes("`p.d`", year: 2026)
    assert_match "i.end_date >= DATE '2026-01-01'", sql
    assert_match "LEAST(CURRENT_DATE('Europe/Paris'), DATE '2027-01-01')", sql
    assert_match "STRUCT(2026 AS year, 4005 AS monthly)", sql
  end
end
