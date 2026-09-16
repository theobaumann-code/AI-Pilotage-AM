class AddArrEstimationMetadataToDeals < ActiveRecord::Migration[8.1]
  def up
    add_column :deals, :arr_estimation_source, :string
    add_column :deals, :arr_estimation_reference, :text
    add_column :deals, :arr_estimation_formula_version, :string
    add_column :deals, :arr_estimated_at, :datetime

    execute <<~SQL.squish
      UPDATE deals
      SET arr = 0,
          arr_estimation_source = 'unavailable',
          arr_estimation_reference = 'Estimation BO à recalculer'
      WHERE type = 'UpsellDeal'
    SQL
  end

  def down
    remove_column :deals, :arr_estimated_at
    remove_column :deals, :arr_estimation_formula_version
    remove_column :deals, :arr_estimation_reference
    remove_column :deals, :arr_estimation_source
  end
end
