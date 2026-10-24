module Authorization
  private def ensure_can_administer : Nil
    head :forbidden unless Current.user.not_nil!.can_administer?
  end
end
