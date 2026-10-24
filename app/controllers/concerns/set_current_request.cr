module SetCurrentRequest
  def set_current_request : Nil
    Current.request = request
    nil
  end
end
