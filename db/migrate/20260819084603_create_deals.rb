class CreateDeals < ActiveRecord::Migration[8.1]
  def change
    create_table :deals do |t|
      t.string :type, null: false # STI discriminator: "ProduitDeal" or "UpsellDeal"
      t.references :company, null: false, foreign_key: true

      t.string :produit, null: false
      t.decimal :arr, precision: 12, scale: 2, null: false, default: 0
      t.decimal :taux, precision: 6, scale: 2, null: false, default: 0

      # ProduitDeal-only columns (nil on UpsellDeal rows)
      t.string :identifiant
      t.string :college
      t.string :assureur
      t.string :statut_renouvellement

      # UpsellDeal-only columns (nil/0 on ProduitDeal rows)
      t.integer :nombre_salaries, null: false, default: 0
      t.integer :probabilite_signature, null: false, default: 0
      t.string :statut_signature

      t.timestamps
    end

    # Rule 1: identifiant unique per produit, ACTIVE data only (never checked against archive_entries,
    # which lives in a completely separate table — so this partial index alone reproduces the original's
    # "same identifiant may legitimately reappear after a company churns out and a new one reuses it" rule).
    add_index :deals, [:produit, :identifiant], unique: true,
      where: "type = 'ProduitDeal' AND identifiant IS NOT NULL",
      name: "index_deals_on_produit_and_identifiant_active"

    # Rule 2: at most one produit+collège combo per company (e.g. "Mutuelle/Cadre" and "Mutuelle/Non cadre"
    # can coexist, but not two "Mutuelle/Cadre" rows for the same company).
    add_index :deals, [:company_id, :produit, :college], unique: true,
      where: "type = 'ProduitDeal'",
      name: "index_deals_on_company_produit_college"
  end
end
