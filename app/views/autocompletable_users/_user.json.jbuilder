# Порт autocompletable/users/_user.json.jbuilder референса
# (routes.js registerUsers): HTML-экранированное имя, подпись,
# signed-avatar, sgid.
json.id user.id
json.name HTML.escape(user.name.to_s)
json.label user.name
json.avatar ChatLayout.fresh_user_avatar_path(user.id.not_nil!, user.updated_at)
json.avatar_url ChatLayout.fresh_user_avatar_path(user.id.not_nil!, user.updated_at)
json.sgid ChatLayout.attachable_sgid(user.id.not_nil!)
json.value user.id
