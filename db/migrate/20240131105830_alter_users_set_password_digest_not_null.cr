# Ported 1:1 from ~/once-campfire (Rails).
class AlterUsersSetPasswordDigestNotNull < ActiveRecord::Migration
  def change
    execute <<-SQL
      update users set password_digest = '' where password_digest is null;
    SQL

    change_column_null :users, :password_digest, false
  end
end
