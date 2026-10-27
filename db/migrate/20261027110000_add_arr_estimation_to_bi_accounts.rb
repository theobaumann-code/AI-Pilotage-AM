class AddArrEstimationToBiAccounts < ActiveRecord::Migration[8.1]
  def change
    # ARR invoiced over Q1 2026 (annualised) and ARR estimated by the Analytics engine, summed over the account's
    # contracts; `arr` keeps the one retained per contract. contracts_estimated = contracts valued at their estimate.
    add_column :bi_accounts, :arr_billed, :decimal, precision: 12, scale: 2, default: "0.0", null: false
    add_column :bi_accounts, :arr_estimated, :decimal, precision: 12, scale: 2, default: "0.0", null: false
    add_column :bi_accounts, :contracts_estimated, :integer, default: 0, null: false
  end
end
