class CreateCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :companies do |t|
      t.string :name, null: false
      # Single FK — not a per-deal AM field — is what makes "one company = one AM" structurally
      # guaranteed rather than validated ad hoc (see original app.html's isDuplicateIdentifiant/
      # resolveCreateAM/findCompanyAmConflict checks, all replaced by this constraint).
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :companies, "lower(name)", unique: true, name: "index_companies_on_lower_name"
  end
end
