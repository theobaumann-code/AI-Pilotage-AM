class AddRisqueChurnToDeals < ActiveRecord::Migration[8.1]
  def change
    add_column :deals, :risque_churn, :integer, default: 0, null: false
  end
end
