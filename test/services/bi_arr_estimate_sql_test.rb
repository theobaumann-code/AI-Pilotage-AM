require "test_helper"

# The SQL port of the Analytics ARR estimation engine: its structure, not BigQuery's answers (checked by hand
# against BigQuery when the port was written).
class BiArrEstimateSqlTest < ActiveSupport::TestCase
  setup { @sql = BiPortfolioSync.new.sql }

  test "the estimate CTEs are wired into the portfolio query, with no placeholder left" do
    assert_no_match(/%\{/, @sql)
    %w[est_contracts est_fee_agg est_occurrence_agg est_health_mix_reference est_provident_own est_provident_mass_basis
       est_benchmark est_pricing contract_arr_estimates q1_coverage contract_choice].each do |cte|
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

  test "an estimate replaces the invoice when Q1 is incomplete or 30 per cent away" do
    choice = @sql[/contract_choice AS \(.*?\n\),/m]
    assert_match "NOT IFNULL(q.q1_complete, FALSE)", choice
    assert_match ">= 0.3 * e.estimated_arr", choice
  end

  test "expected affiliates use the business-validated conversion rates" do
    assert_match((0.80 / 0.9885).to_s, @sql)
    assert_match((0.95 / 0.973).to_s, @sql)
    assert_match "STRUCT(2026 AS year, 4005 AS monthly)", @sql
  end
end
