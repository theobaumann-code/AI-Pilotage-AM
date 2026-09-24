class AddArrNonAccompagneToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :arr_non_accompagne, :decimal, default: 0, null: false
  end
end
