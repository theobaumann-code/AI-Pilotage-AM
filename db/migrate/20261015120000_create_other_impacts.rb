class CreateOtherImpacts < ActiveRecord::Migration[8.1]
  def change
    create_table :other_impacts do |t|
      t.references :company, null: false, foreign_key: true
      t.string :produit, null: false, default: "Mutuelle"
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0
      t.text :comment
      t.string :statut, null: false, default: "En cours"
      t.integer :annee, null: false
      t.timestamps
    end
  end
end
