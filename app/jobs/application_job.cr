# Port replacement for application_job.rb: no ActiveJob in the port, jobs
# are dispatched by Campfire::JobQueue by kind; shared perform(data) signature.
class ApplicationJob
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  def self.perform(data : JSON::Any) : Nil
    raise NotImplementedError.new("#{self}.perform")
  end
end
