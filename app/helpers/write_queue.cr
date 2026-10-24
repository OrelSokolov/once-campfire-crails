# Two-level write queue for fork workers.
#
# Level 1 — in-process: write blocks run on a single writer fiber. Waiting for
# the write lock inside the SQLite busy handler sleeps in C code and blocks the
# whole worker's event loop; if the lock is held by a fiber of this same
# process, its COMMIT cannot run while the waiter sleeps in C — a livelock.
# One fiber writes through the queue, the rest wait in the Crystal scheduler.
#
# Level 2 — between processes (WEB_CONCURRENCY fork workers): the per-process
# writer fibers serialize on a robust process-shared mutex in an anonymous
# shared page (ActiveSupport::ProcessSharedMutex, the nginx model). The page
# and the initialized mutex are created in the master BEFORE fork
# (prepare_fork!) and inherited by children — no filesystem involved, the lock
# does not depend on where the database lives, and no flock/fcntl inode
# queues arise. The robust flag auto-releases the lock when the holder dies,
# like flock. Writers reach SQLite strictly one at a time: the busy handler is
# never invoked, no BUSY/"statements in progress" errors.
#
# One lock per whole write group (production transaction + jobs enqueue) — one
# hop per message, deadlock impossible.
module Campfire
  module WriteQueue
    # Block + channel to wake the calling fiber.
    class Invocation
      attr_reader wake : Channel(Exception?)
      attr_reader run : Proc(Nil)

      def initialize(@wake, &@run : ->)
      end
    end

    @@queue = Channel(Invocation).new(256)
    @@runner_started = false
    @@page : ActiveSupport::SharedPage?
    @@mutex : ActiveSupport::ProcessSharedMutex?

    # Shared page + mutex init in the master BEFORE fork (src/app.cr, before
    # ServerX::Cluster.run). Children inherit both the mapping and the ready
    # mutex — re-initializing after fork would break cross-process compatibility.
    def self.prepare_fork! : Nil
      return if @@mutex
      page = ActiveSupport::SharedPage.new
      @@page = page
      @@mutex = ActiveSupport::ProcessSharedMutex.init_at(page.pointer)
    end

    # Run the write block in the writer fiber; the result and errors are
    # propagated back to the calling fiber.
    def self.perform(&block : -> T) : T forall T
      ensure_runner
      wake = Channel(Exception?).new
      result = uninitialized T
      invocation = Invocation.new(wake) { result = block.call }
      @@queue.send(invocation)
      if error = wake.receive
        raise error
      end
      result
    end

    # After fork (serverX Cluster) the inherited writer fiber is dead: the queue
    # is recreated and starts lazily on the worker's first write. The page and
    # mutex are inherited as is — left untouched.
    def self.reset! : Nil
      @@queue = Channel(Invocation).new(256)
      @@runner_started = false
    end

    # Without prepare_fork! (single-process run, stdlib transport) a private
    # page is created lazily: no cross-process sharing needed, the mutex is
    # correct within the process.
    private def self.mutex : ActiveSupport::ProcessSharedMutex
      if (m = @@mutex)
        m
      else
        page = @@page ||= ActiveSupport::SharedPage.new
        m = ActiveSupport::ProcessSharedMutex.init_at(page.pointer)
        @@mutex = m
        m
      end
    end

    private def self.ensure_runner : Nil
      return if @@runner_started
      @@runner_started = true
      spawn do
        lock = mutex
        loop do
          invocation = @@queue.receive
          begin
            lock.lock
            begin
              invocation.run.call
            ensure
              lock.unlock
            end
            invocation.wake.send(nil)
          rescue error
            invocation.wake.send(error)
          end
        end
      end
      Fiber.yield
    end
  end
end
