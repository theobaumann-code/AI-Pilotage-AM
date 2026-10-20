class AddPosteToUsers < ActiveRecord::Migration[8.1]
  # "poste" = the team-lead function a user holds on top of their rights ("TL AM" → admin rights,
  # "TL Customer Care" → plain user rights; see User). Only the two team leads known today are assigned here.
  def up
    add_column :users, :poste, :string

    execute "UPDATE users SET poste = 'TL AM' WHERE admin = TRUE AND email = 'sarra.bachar@sidecare.com'"
    execute <<~SQL
      UPDATE users SET poste = 'TL Customer Care'
      WHERE admin = FALSE AND kam = FALSE AND reader = FALSE
        AND (name ILIKE 'Zakariaa Jirrari%' OR name ILIKE 'Louis Billard%')
    SQL
  end

  def down
    remove_column :users, :poste
  end
end
