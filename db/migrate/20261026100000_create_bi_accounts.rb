class CreateBiAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :bi_accounts do |t|
      t.string :kind, null: false
      t.bigint :bi_id, null: false
      t.string :name
      t.string :siren
      t.integer :user_pros_count, default: 0, null: false
      t.string :am_email
      t.string :am_name
      t.decimal :arr, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :arr_sante, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :arr_prevoyance, precision: 12, scale: 2, default: "0.0", null: false
      t.boolean :has_sante, default: false, null: false
      t.boolean :has_prevoyance, default: false, null: false
      t.boolean :has_standard_sante, default: false, null: false
      t.integer :contracts_count, default: 0, null: false
      t.integer :contracts_without_q1, default: 0, null: false
      t.integer :employees_count
      t.datetime :synced_at, null: false
      t.timestamps
    end
    add_index :bi_accounts, [ :kind, :bi_id ], unique: true
    add_index :bi_accounts, :am_email
  end
end
