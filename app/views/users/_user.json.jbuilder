# Порт users/_user.json.jbuilder референса (json.cache! + extract!):
# id/name/role (role — строка, как enum Rails и serializeMessage
# эталона: member/administrator/bot) + fresh_user_avatar_url.
json.id user.id
json.name user.name
json.role %w[member administrator bot][(user.role || 0)]? || "member"
json.avatar_url jb_origin + ChatLayout.fresh_user_avatar_path(user.id.not_nil!,
  user.updated_at)
