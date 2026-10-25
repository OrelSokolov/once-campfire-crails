json.cache! user do
  json.extract! user, :id, :name, :role

  json.avatar_url jb_origin + ChatLayout.fresh_user_avatar_path(user.id.not_nil!,
  user.updated_at)
end
