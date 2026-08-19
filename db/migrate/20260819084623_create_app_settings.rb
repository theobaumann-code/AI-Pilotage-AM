class CreateAppSettings < ActiveRecord::Migration[8.1]
  def change
    # Single-row singleton table (see AppSetting.instance) holding the "année en cours" the whole app
    # pivots around — simplest possible design, no gem needed for a single global integer.
    create_table :app_settings do |t|
      t.integer :annee_en_cours, null: false, default: Date.current.year

      t.timestamps
    end
  end
end
