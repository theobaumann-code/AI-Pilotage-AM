class AddKamToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :kam, :boolean, null: false, default: false
  end
end
