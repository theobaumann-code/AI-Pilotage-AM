class AddRisqueManqueOffresToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :risque_manque_offres, :boolean, null: false, default: false
  end
end
