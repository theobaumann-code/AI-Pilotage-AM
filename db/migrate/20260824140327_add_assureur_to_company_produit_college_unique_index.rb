class AddAssureurToCompanyProduitCollegeUniqueIndex < ActiveRecord::Migration[8.1]
  # Business rule change: a company may now hold several contracts for the same produit+collège as long
  # as each is with a different insurer — only an exact produit+collège+assureur duplicate is rejected.
  def change
    remove_index :deals, name: "index_deals_on_company_produit_college"
    add_index :deals, [:company_id, :produit, :college, :assureur], unique: true,
      where: "type = 'ProduitDeal'",
      name: "index_deals_on_company_produit_college_assureur"
  end
end
