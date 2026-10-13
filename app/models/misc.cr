class Account < ActiveRecord::Base
end

class Ban < ActiveRecord::Base
  belongs_to :user
end

class Boost < ActiveRecord::Base
  belongs_to :message
  belongs_to :booster, class_name: "User"
end

class Search < ActiveRecord::Base
  belongs_to :user
end

class Webhook < ActiveRecord::Base
  belongs_to :user
end

class PushSubscription < ActiveRecord::Base
  belongs_to :user
end
