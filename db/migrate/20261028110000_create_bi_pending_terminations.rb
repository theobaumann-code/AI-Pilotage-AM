# Temporary "Résiliations en attente" rubric: the BO's contract terminations waiting for the client's signature.
# Drop this table along with the rubric.
class CreateBiPendingTerminations < ActiveRecord::Migration[8.1]
  def change
    create_table :bi_pending_terminations do |t|
      t.bigint :bi_id, null: false
      t.string :name
      t.string :terminable_type
      t.bigint :terminable_id
      t.integer :product_type
      t.bigint :user_pro_id
      t.string :social_name
      t.string :account_kind, null: false
      t.bigint :account_bi_id, null: false
      t.date :created_on
      t.date :termination_date
      t.decimal :contract_arr, precision: 12, scale: 2
      t.datetime :synced_at, null: false
    end
    add_index :bi_pending_terminations, :bi_id, unique: true
    add_index :bi_pending_terminations, [ :account_kind, :account_bi_id ]
  end
end
