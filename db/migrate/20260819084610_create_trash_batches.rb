class CreateTrashBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :trash_batches do |t|
      t.integer :year, null: false
      t.datetime :deleted_at, null: false
      t.references :deleted_by, null: true, foreign_key: { to_table: :users } # nullable: the admin who deleted it may later be deactivated

      t.timestamps
    end
  end
end
