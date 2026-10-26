json.id user.id
json.name HTML.escape(user.name.to_s)
json.label user.name
json.avatar fresh_user_avatar_path(user)
json.avatar_url fresh_user_avatar_url(user)
json.sgid ChatLayout.attachable_sgid(user.id!)
json.value user.id
