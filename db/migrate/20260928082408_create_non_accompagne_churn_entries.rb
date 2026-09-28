class CreateNonAccompagneChurnEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :non_accompagne_churn_entries do |t|
      t.string :company_name, null: false
      t.decimal :amount, precision: 12, scale: 2, default: 0, null: false

      t.timestamps
    end
  end
end
