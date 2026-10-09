class AddReaderToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :reader, :boolean, null: false, default: false
  end
end
