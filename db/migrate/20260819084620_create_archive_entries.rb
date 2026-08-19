class CreateArchiveEntries < ActiveRecord::Migration[8.1]
  def change
    # Denormalized, frozen snapshot of a (contract × year) row — not FK-live to companies/deals, since the
    # original explicitly never re-checks archived years against anything (identifiant reuse rule) and a
    # closed year's data must stay exactly as it was even if the live company/deal is later renamed or deleted.
    create_table :archive_entries do |t|
      t.integer :year, null: false
      t.references :user, null: true, foreign_key: true # nullable: deactivating/removing an AM must never break history
      t.string :am_name, null: false # snapshot of the AM's display name at closing time, belt-and-suspenders

      t.string :company_name, null: false
      t.string :deal_type, null: false # "ProduitDeal" or "UpsellDeal", mirrors Deal STI type at snapshot time

      t.string :produit, null: false
      t.decimal :arr, precision: 12, scale: 2, null: false, default: 0
      t.decimal :taux, precision: 6, scale: 2, null: false, default: 0
      t.string :identifiant
      t.string :college
      t.string :assureur
      t.string :statut_renouvellement
      t.integer :nombre_salaries, null: false, default: 0
      t.integer :probabilite_signature, null: false, default: 0
      t.string :statut_signature
      t.decimal :upsell_amount, precision: 12, scale: 2, null: false, default: 0 # frozen at snapshot time (unlike Deal, never recomputed)

      # Null = visible in Historique; set = sitting in the corbeille (trash), hidden from all calculations/
      # charts until an explicit restore. Restoring must never happen implicitly — see TrashBatch.
      t.references :trash_batch, null: true, foreign_key: true

      t.timestamps
    end

    add_index :archive_entries, :year
  end
end
