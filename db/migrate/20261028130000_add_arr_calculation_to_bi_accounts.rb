# How a BI account's ARR was obtained by the Analytics engine: invoiced, estimated or mixed, with the methods,
# reliability and population behind it. The Q1 2026 annualisation it replaces no longer needs its counter.
class AddArrCalculationToBiAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :bi_accounts, :arr_source, :string
    add_column :bi_accounts, :arr_calculation, :jsonb
    remove_column :bi_accounts, :contracts_without_q1, :integer, default: 0, null: false
  end
end
