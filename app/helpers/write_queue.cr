# Однопроцессная очередь записи: write-блоки исполняет единственная
# writer-фибера, и в процессе за SQLite write-lock не конкурируют
# несколько соединений.
#
# Зачем: ожидание write-lock'а в busy-хендлере SQLite — сон в C-коде,
# блокирующий event-loop всего воркера. Если лок в этот момент держит
# фибера этого же процесса, её COMMIT выполниться не может, пока ждущий
# спит в C, — лайвлок до истечения busy_timeout (эскалация сна хендлера
# 1+2+5+10+15…ms в точности объясняла p50=8ms/p90=34ms/p99=340ms
# post_message). Через очередь пишет ровно одна фибера: ожидание
# остальных — в Crystal-шедулере, event-loop свободен. Межпроцессная
# конкуренция (fork-воркеры) остаётся за SQLite: BEGIN IMMEDIATE +
# busy_timeout драйвера, лок в другом процессе наш цикл не заморозит.
module Campfire
  module WriteQueue
    # Блок + канал пробуждения вызывающей фиберы.
    class Invocation
      getter wake : Channel(Exception?)
      getter run : Proc(Nil)

      def initialize(@wake, &@run : ->)
      end
    end

    @@queue = Channel(Invocation).new(256)
    @@runner_started = false

    # Выполнить write-блок в writer-фибере; результат и ошибки
    # пробрасываются вызывающей фибере.
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

    # После fork (serverX Cluster) унаследованная writer-фибера мертва:
    # очередь пересоздаётся и стартует лениво при первой записи в воркере.
    def self.reset! : Nil
      @@queue = Channel(Invocation).new(256)
      @@runner_started = false
    end

    private def self.ensure_runner : Nil
      return if @@runner_started
      @@runner_started = true
      spawn do
        loop do
          invocation = @@queue.receive
          begin
            invocation.run.call
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
