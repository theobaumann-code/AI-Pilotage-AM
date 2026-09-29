class CreateRiskNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :risk_notes do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :content, null: false

      t.timestamps
    end
  end
end
