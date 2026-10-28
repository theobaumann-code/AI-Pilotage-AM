class AddAResilierToDeals < ActiveRecord::Migration[8.1]
  def change
    # "A résilier" box of the produits à renouveler tables: the AM flags a produit the client is going to terminate.
    add_column :deals, :a_resilier, :boolean, default: false, null: false
  end
end
