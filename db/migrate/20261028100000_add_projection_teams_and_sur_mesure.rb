class AddProjectionTeamsAndSurMesure < ActiveRecord::Migration[8.1]
  def change
    # At least one "sur mesure" health contract (offer_kind 3) among the account's contracts.
    add_column :bi_accounts, :has_sur_mesure_sante, :boolean, default: false, null: false

    # Teams the projection can give accounts to instead of an AM (e.g. "CSM Juniors").
    create_table :projection_teams do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :projection_teams, "lower(name)", unique: true

    add_reference :projection_moves, :team, foreign_key: { to_table: :projection_teams, on_delete: :cascade }
  end
end
