# Двухуровневая очередь записи для fork-воркеров.
#
# Уровень 1 — в процессе: write-блоки исполняет единственная
# writer-фибера. Ожидание write-lock'а в busy-хендлере SQLite — сон в
# C-коде, блокирующий event-loop всего воркера; если лок держит фибера
# этого же процесса, её COMMIT не может выполниться, пока ждущий спит
# в C, — лайвлок. Через очередь пишет ровно одна фибера, остальные
# ждут в Crystal-шедулере.
#
# Уровень 2 — между процессами (WEB_CONCURRENCY fork-воркеров):
# writer-фиберы процессов сериализуются через robust process-shared
# мьютекс в анонимной разделяемой странице (ActiveSupport::
# ProcessSharedMutex, модель nginx). Страница и инициализированный
# мьютекс создаются в master ДО fork (prepare_fork!) и наследуются
# детьми — файловой системы нет вообще, лок не зависит от того, где
# лежит база (tmpfs/ext4/тома), inode-очередей flock/fcntl не возникает.
# Robust-флаг = авто-освобождение при смерти держателя, как у flock.
# К SQLite писатели приходят строго по одному: busy-хендлер не
# вызывается, BUSY/«statements in progress» не возникают.
#
# Одна блокировка на всю write-группу (production-транзакция + jobs
# enqueue) — один хоп на сообщение, дедлок невозможен.
module Campfire
  module WriteQueue
    # Блок + канал пробуждения вызывающей фиберы.
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

    # Разделяемая страница + инициализация мьютекса в master ДО fork
    # (src/app.cr перед ServerX::Cluster.run). Дети наследуют и
    # маппинг, и готовый мьютекс — ре-инициализация после fork сломала
    # бы совместимость процессов.
    def self.prepare_fork! : Nil
      return if @@mutex
      page = ActiveSupport::SharedPage.new
      @@page = page
      @@mutex = ActiveSupport::ProcessSharedMutex.init_at(page.pointer)
    end

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
    # очередь пересоздаётся и стартует лениво при первой записи в
    # воркере. Страница и мьютекс наследуются как есть — не трогаем.
    def self.reset! : Nil
      @@queue = Channel(Invocation).new(256)
      @@runner_started = false
    end

    # Без prepare_fork! (одно-процессный запуск, stdlib-транспорт) —
    # лениво своя страница: межпроцессного разделения не требуется,
    # мьютекс в рамках процесса корректен.
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
