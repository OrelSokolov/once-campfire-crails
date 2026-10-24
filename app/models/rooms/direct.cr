require "../application_record"
# Rooms for direct message chats between users. These act as a singleton, so a single set of users will
# always refer to the same direct room.
class Rooms::Direct < Room
  def default_involvement : String
    "everything"
  end
end
