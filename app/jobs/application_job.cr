require "json"

# ActiveJob surface used by the app (globalid-style): job arguments serialize
# AR records as gid params (to_gid_param) resolved back via GlobalID::Locator
# at perform time; primitives pass through. A record that vanished before the
# job runs raises ActiveJob::DeserializationError — discarded via discard_on.
module ActiveJob
  class DeserializationError < Exception
  end
end

class ApplicationJob
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  discard_on ActiveJob::DeserializationError

  # discard_on registrations keyed by declaring class name. A constant (not a
  # class var): Crystal class vars are per-type, not shared down the hierarchy.
  DISCARD_REGISTRY = {} of String => Array(Exception.class)

  def self.discard_on(exception : Exception.class) : Nil
    (DISCARD_REGISTRY[name] ||= [] of Exception.class) << exception
  end

  # discard_on registers under the declaring class; subclasses inherit the
  # registrations (Rails class_attribute semantics) via `inherited`.
  macro inherited
    __inherit_discards({{ @type.stringify }}, {{ @type.superclass.stringify }})
  end

  def self.__inherit_discards(child : String, parent : String) : Nil
    inherited_list = DISCARD_REGISTRY[parent]?
    return unless inherited_list
    (DISCARD_REGISTRY[child] ||= [] of Exception.class).concat(inherited_list)
  end

  def self.discards?(exception : Exception.class) : Bool
    DISCARD_REGISTRY[name]?.try(&.includes?(exception)) || false
  end

  # Campfire::JobQueue kind (express routes.js names — stable: pending jobs in
  # existing queue DBs carry them).
  def self.queue_kind : String
    raise NotImplementedError.new("#{self}.queue_kind")
  end

  # `serialized room: Room, message: Message` — wires perform_later / deferred
  # __queue_pair / dispatch __run for a subclass's typed instance #perform.
  # The __queue_pair form serves callers that build jobs inside a transaction
  # and enqueue strictly after commit (see MessageCreator#create!).
  macro serialized(**args)
    {% names = [] of Nil %}
    {% types = [] of Nil %}
    {% for k, v in args %}
      {% names << k %}
      {% types << v %}
    {% end %}
    {% sig = names.map_with_index { |n, i| "#{n.id} : #{types[i]}".id } %}

    def self.__queue_pair({{ sig.splat }}) : Tuple(String, String)
      payload = Array(JSON::Any).new
      {% for n in names %}payload << __ser({{ n.id }});{% end %}
      {queue_kind, payload.to_json}
    end

    def self.perform_later({{ sig.splat }}) : Nil
      Campfire::JobQueue.enqueue_batch([__queue_pair({{ names.map(&.id).splat }})])
    end

    def self.__run(data : JSON::Any) : Nil
      args = data.as_a? || raise ActiveJob::DeserializationError.new("bad payload")
      new.perform(
        {% for i in 0...names.size %}__deser(args[{{ i }}], {{ types[i] }}){% if i < names.size - 1 %}, {% end %}{% end %}
      )
    end
  end

  # --- serialize ------------------------------------------------------

  def self.__ser(v : ActiveRecord::Base) : JSON::Any
    JSON::Any.new({"_aj_globalid" => JSON::Any.new(v.to_gid_param)})
  end

  def self.__ser(v : Int64) : JSON::Any
    JSON::Any.new(v)
  end

  def self.__ser(v : Int32) : JSON::Any
    JSON::Any.new(v.to_i64)
  end

  def self.__ser(v : String) : JSON::Any
    JSON::Any.new(v)
  end

  def self.__ser(v : Bool) : JSON::Any
    JSON::Any.new(v)
  end

  def self.__ser(v : Array(Int64)) : JSON::Any
    JSON::Any.new(v.map { |e| JSON::Any.new(e) })
  end

  # --- deserialize ------------------------------------------------------

  def self.__deser(value : JSON::Any, t : Int64.class) : Int64
    value.as_i64? || raise ActiveJob::DeserializationError.new("expected Int64")
  end

  def self.__deser(value : JSON::Any, t : String.class) : String
    value.as_s? || raise ActiveJob::DeserializationError.new("expected String")
  end

  def self.__deser(value : JSON::Any, t : Bool.class) : Bool
    value.as_bool? || raise ActiveJob::DeserializationError.new("expected Bool")
  end

  def self.__deser(value : JSON::Any, t : Array(Int64).class) : Array(Int64)
    value.as_a?.try(&.map(&.as_i64)) ||
      raise ActiveJob::DeserializationError.new("expected Array(Int64)")
  end

  def self.__deser(value : JSON::Any, t : T.class) : T forall T
    gid = value.as_h?.try { |h| h["_aj_globalid"]?.try(&.as_s?) }
    raise ActiveJob::DeserializationError.new("missing _aj_globalid") unless gid
    GlobalID::Locator.locate(gid, only: T) ||
      raise ActiveJob::DeserializationError.new("record not found: #{gid}")
  end

  # Virtual-dispatch base for the serialized __run dispatchers.
  def self.__run(data : JSON::Any) : Nil
    raise NotImplementedError.new("#{self}.__run")
  end

  def self.perform(data : JSON::Any) : Nil
    raise NotImplementedError.new("#{self}.perform")
  end
end
