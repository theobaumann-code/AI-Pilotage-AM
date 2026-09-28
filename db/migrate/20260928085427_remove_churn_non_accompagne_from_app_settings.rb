class RemoveChurnNonAccompagneFromAppSettings < ActiveRecord::Migration[8.1]
  # "Churn non accompagné" is now tracked company by company (plus a catch-all "Autre" entry for small
  # accounts) in non_accompagne_churn_entries instead of one lump AppSetting figure — see
  # AppSetting#churn_non_accompagne, now computed as that table's sum. Any value already sitting in the
  # column being dropped here is preserved as a single starting entry rather than silently discarded.
  def up
    existing = execute('SELECT churn_non_accompagne FROM app_settings LIMIT 1').to_a.first&.fetch('churn_non_accompagne')&.to_f
    if existing && existing > 0
      execute <<~SQL
        INSERT INTO non_accompagne_churn_entries (company_name, amount, created_at, updated_at)
        VALUES ('Autre (import initial)', #{existing}, NOW(), NOW())
      SQL
    end

    remove_column :app_settings, :churn_non_accompagne
  end

  def down
    add_column :app_settings, :churn_non_accompagne, :decimal, default: 0, null: false
  end
end
