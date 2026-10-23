# ApplicationJob (application_job.rb оракула). ActiveJob в порте нет —
# джобы диспетчеризуются Campfire::JobQueue по kind; база — общая
# сигнатура perform(data).
class ApplicationJob
  def self.perform(data : JSON::Any) : Nil
    raise NotImplementedError.new("#{self}.perform")
  end
end
