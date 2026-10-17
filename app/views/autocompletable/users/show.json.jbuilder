# Порт autocompletable/users/index.json.jbuilder референса: коллекция
# подсказок через autocompletable/users/_user (as: → as_local: — порт).
json.array! @users, partial: "autocompletable/users/user", as_local: :user
