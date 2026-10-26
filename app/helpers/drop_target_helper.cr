# DropTargetHelper (oracle app/helpers/drop_target_helper.rb): the
# drag-and-drop Stimulus wiring shared by the composer data-action and
# the message area.
module DropTargetHelper
  def drop_target_actions : String
    "dragenter->drop-target#dragenter dragover->drop-target#dragover drop->drop-target#drop"
  end
end
