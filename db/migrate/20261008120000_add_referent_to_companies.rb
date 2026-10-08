class AddReferentToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_reference :companies, :referent, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
