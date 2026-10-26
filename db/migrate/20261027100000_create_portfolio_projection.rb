class CreatePortfolioProjection < ActiveRecord::Migration[8.1]
  def change
    # AMs of the app who won't be there next campaign: their BO accounts go back to the pool.
    create_table :projection_departures do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.timestamps
    end

    # Fictitious people the projection plans to hire, with the role that sets their account ceiling.
    create_table :projection_recruits do |t|
      t.string :name, null: false
      t.string :role, null: false
      t.timestamps
    end

    # One planned change per BI account: given to someone (user or recruit), put back in the pool, or no longer
    # followed. Keyed like bi_accounts so it survives the daily full replace of that table.
    create_table :projection_moves do |t|
      t.string :kind, null: false
      t.bigint :bi_id, null: false
      t.string :action, null: false
      t.references :user, foreign_key: { on_delete: :cascade }
      t.references :recruit, foreign_key: { to_table: :projection_recruits, on_delete: :cascade }
      t.string :original_am_email
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :projection_moves, [ :kind, :bi_id ], unique: true
  end
end
